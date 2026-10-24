import 'dart:async';
import 'dart:io';

import 'package:easypass/core_service/bridge_forwarder.dart';
import 'package:easypass/core_service/core_client.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/protocol.dart';

import 'vault_api.dart';

/// 核心连接管理器：**唯一的**连接入口。
///
/// 职责：确保核心在跑（不在就拉起）→ 连接 + 握手 → 断线后自动重连 →
/// 把核心推送的 `changed` 主题转发给 UI。
class CoreSession {
  CoreSession({this.launchIfMissing = true});

  /// 连接不上时是否尝试拉起同目录的核心可执行文件。
  final bool launchIfMissing;

  CoreClient? _client;
  Future<CoreClient>? _connecting;
  final StreamController<String> _changes = StreamController<String>.broadcast();
  final StreamController<String> _sessionEvents =
      StreamController<String>.broadcast();
  bool _disposed = false;

  /// 数据变更主题流（`items` / `item` / `folders` / `search`）。
  Stream<String> get changes => _changes.stream;

  /// 会话事件流（`locked` / `unlocked` / `shuttingDown`）。
  Stream<String> get sessionEvents => _sessionEvents.stream;

  bool get isConnected => _client?.isClosed == false;

  /// 拿到一条可用连接（必要时连接或拉起核心）。
  Future<CoreClient> _ensureClient() {
    final existing = _client;
    if (existing != null && !existing.isClosed) return Future.value(existing);
    final inFlight = _connecting;
    if (inFlight != null) return inFlight;
    final future = _connect().whenComplete(() => _connecting = null);
    _connecting = future;
    return future;
  }

  Future<CoreClient> _connect() async {
    var info = await CoreDiscovery.read();

    // ── 陈旧核心退休（3.0.0）─────────────────────────────────
    //
    // 升级前可能是 2.4.x 的 `easypass.exe --service` daemon（协议 ≤ 4，不认识
    // 协议 5 的加密握手）。判定依据是 `daemon.json` 的 `protocolVersion`：
    // 低于当前协议就应该退休它，而不是让握手一路失败到超时。
    //
    // **只删发现文件、不主动结束那个进程**，这是有意的安全取舍：
    // - 旧 daemon 的 `daemon.json` 没有 `exe` 字段（协议 3/4 的格式），我们
    //   无法把 pid 与"确实是我们自己的镜像"对上 —— 盲杀 pid 有误杀风险。
    // - 它会自己 10 分钟空闲自退；且它的 `_removeInfoIfOurs` 会校验 port+pid，
    //   不会删掉我们随后写入的新核心注册信息（这条保护是刻意写的）。
    // - 安装包升级时，Inno 的 CloseApplications 会先请它关闭（它锁着
    //   easypass.exe 映像）。
    // 代价：最多 10 分钟内新旧两个进程并发访问同一个 SQLite —— SQLite 本身
    // 能扛（WAL + 锁），且旧进程只读不写（它的会话另一份），不会损坏数据。
    if (info != null && info.isStale) {
      stderr.writeln(
        'easypass: retiring stale core before connect '
        '(pid=${info.pid}, protocol=${info.protocolVersion} < $coreProtocolVersion)',
      );
      await CoreDiscovery.removeAny();
      info = null;
    }

    var client = info == null ? null : await _tryConnect(info);
    if (client != null) {
      _adopt(client);
      return client;
    }

    // 发现文件缺失/连不上（含协议够但握手失败）：清掉残留后按需拉起核心。
    await CoreDiscovery.removeAny();
    if (!launchIfMissing || !await launchCoreIfPresent()) {
      throw VaultApiException(
        ErrorCodes.unsupported,
        '核心服务未运行，且找不到核心可执行文件（easypass_core）',
      );
    }
    info = await waitForCore();
    if (info == null) {
      throw VaultApiException(ErrorCodes.unsupported, '核心服务启动超时');
    }
    client = await _tryConnect(info);
    if (client == null) {
      throw VaultApiException(ErrorCodes.unsupported, '核心服务无法连接');
    }
    _adopt(client);
    return client;
  }

  Future<CoreClient?> _tryConnect(CoreInfo info) async {
    try {
      return await CoreClient.connect(info, role: 'ui');
    } catch (_) {
      return null;
    }
  }

  void _adopt(CoreClient client) {
    _client = client;
    client.events.listen((event) {
      if (_disposed) return;
      final changed = event['topic'];
      if (event['event'] == Events.changed) {
        if (changed is String) _changes.add(changed);
        return;
      }
      final sessionEvent = uiSessionEvent(event);
      if (sessionEvent != null) _sessionEvents.add(sessionEvent);
    });
  }

  /// 发一个请求；连接失效时重连一次再试。
  Future<Map<String, dynamic>> request(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    final client = await _ensureClient();
    try {
      return await client.request(action, params);
    } on CoreHandshakeException {
      _client = null;
      final retry = await _ensureClient();
      return retry.request(action, params);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _client?.close();
    await _changes.close();
    await _sessionEvents.close();
  }
}

/// [VaultApi] 的 IPC 实现：把每个方法映射成一个协议动作。
class CoreVaultApi implements VaultApi {
  CoreVaultApi(this._session);

  final CoreSession _session;

  @override
  Stream<String> get changes => _session.changes;

  @override
  Stream<String> get sessionEvents => _session.sessionEvents;

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> params = const {},
  ]) async {
    try {
      return await _session.request(action, params);
    } on CoreRequestException catch (error) {
      throw VaultApiException(error.code, error.message);
    }
  }

  // ─── 会话 / 认证 ────────────────────────────────────────

  @override
  Future<AuthSnapshot> authSnapshot() async {
    final data = await _call(Actions.getAuthState);
    return AuthSnapshot(
      status: data['status'] as String? ?? 'locked',
      autoLockMinutes: (data['autoLockMinutes'] as num?)?.toInt() ?? 5,
      hasAuthMaterial: data['hasAuthMaterial'] == true,
      remainingSeconds: (data['remainingSeconds'] as num?)?.toInt(),
    );
  }

  @override
  Future<void> unlock(String password) async {
    await _call(Actions.unlock, {'password': password});
  }

  @override
  Future<void> lock() async {
    await _call(Actions.lock);
  }

  @override
  Future<void> setMasterPassword(String password, String confirmPassword) async {
    await _call(Actions.setMasterPassword, {
      'password': password,
      'confirmPassword': confirmPassword,
    });
  }

  @override
  Future<ChangePasswordResult> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    final data = await _call(Actions.changeMasterPassword, {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'confirmPassword': confirmPassword,
    });
    return ChangePasswordResult(
      keyMaterialPersisted: data['keyMaterialPersisted'] != false,
      reencrypted: (data['reencrypted'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<bool> verifyMasterPassword(String password) async {
    final data = await _call(Actions.verifyMasterPassword, {
      'password': password,
    });
    return data['ok'] == true;
  }

  @override
  Future<void> adoptLegacyKeyMaterial({
    required String salt,
    required String passwordHash,
  }) async {
    await _call(Actions.adoptLegacyKeyMaterial, {
      'salt': salt,
      'passwordHash': passwordHash,
    });
  }

  @override
  Future<void> setAutoLockMinutes(int minutes) async {
    await _call(Actions.setAutoLockMinutes, {'minutes': minutes});
  }

  @override
  Future<void> touchActivity() async {
    // 核心没起来/已锁定时是空操作 —— 不要因为"续期失败"打断用户操作。
    try {
      await _call(Actions.touchActivity);
    } on VaultApiException {
      // 忽略：下一次真实动作会重连。
    }
  }

  // ─── 读 ────────────────────────────────────────────────

  @override
  Future<List<VaultItem>> listItems({
    String? folderId,
    EntryType? type,
    bool favoritesOnly = false,
  }) async {
    final data = await _call(Actions.listItems, {
      'folderId': ?folderId,
      'type': ?type?.wireName,
      if (favoritesOnly) 'favoritesOnly': true,
    });
    return _items(data);
  }

  @override
  Future<VaultItem?> getItem(String id) async {
    try {
      final data = await _call(Actions.getItem, {'id': id});
      final raw = data['item'];
      if (raw is! Map) return null;
      return VaultItem.fromJson(Map<String, dynamic>.from(raw));
    } on VaultApiException catch (error) {
      if (error.code == ErrorCodes.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<List<WireFolder>> listFolders() async {
    final data = await _call(Actions.listFolders);
    final raw = data['folders'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) WireFolder.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  @override
  Future<List<VaultItem>> searchItems(String query) async {
    final data = await _call(Actions.searchItems, {'query': query});
    return _items(data);
  }

  @override
  Future<int> countItemsInFolder(String folderId) async {
    final data = await _call(Actions.countItemsInFolder, {'folderId': folderId});
    return (data['count'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<Map<String, dynamic>> healthReport() =>
      _call(Actions.getHealthReport);

  @override
  Future<Map<String, dynamic>> getTotp(String entryId) =>
      _call(Actions.getTotp, {'entryId': entryId});

  // ─── 写 ────────────────────────────────────────────────

  @override
  Future<String> saveItem(VaultItem item) async {
    final data = await _call(Actions.saveItem, {'item': item.toJson()});
    return data['id'] as String? ?? item.id;
  }

  @override
  Future<void> deleteItem(String id) async {
    await _call(Actions.deleteItem, {'id': id});
  }

  @override
  Future<String> addFolder(String name, {String icon = 'folder'}) async {
    final data = await _call(Actions.addFolder, {'name': name, 'icon': icon});
    return data['id'] as String? ?? '';
  }

  @override
  Future<void> updateFolder(String id, {String? name, String? icon}) async {
    await _call(Actions.updateFolder, {
      'id': id,
      'name': ?name,
      'icon': ?icon,
    });
  }

  @override
  Future<void> removeFolder(String id) async {
    await _call(Actions.removeFolder, {'id': id});
  }

  @override
  Future<void> deleteAllData() async {
    await _call(Actions.deleteAllData, {'confirm': true});
  }

  // ─── 导出 / 导入 ───────────────────────────────────────

  @override
  Future<void> exportVault(String format, String path) async {
    await _call(Actions.exportVault, {'format': format, 'path': path});
  }

  @override
  Future<Map<String, dynamic>> importVault(String format, String path) =>
      _call(Actions.importVault, {'format': format, 'path': path});

  List<VaultItem> _items(Map<String, dynamic> data) {
    final raw = data['items'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) VaultItem.fromJson(Map<String, dynamic>.from(item)),
    ];
  }
}

/// 便捷构造：起一个会话并包成 [VaultApi]。
Future<({CoreSession session, VaultApi api})> createCoreVaultApi({
  bool launchIfMissing = true,
}) async {
  final session = CoreSession(launchIfMissing: launchIfMissing);
  return (session: session, api: CoreVaultApi(session));
}

/// 同目录核心可执行文件是否存在（UI 用它决定显示"核心缺失"提示还是尝试拉起）。
bool coreExecutableExists() => coreExecutablePath() != null;

/// 平台判断的薄封装（UI 侧不需要 import dart:io 的地方用它）。
bool get isWindowsHost => Platform.isWindows;

/// 把核心的会话事件翻译成 **UI 关心** 的事件；不关心时返回 null。
///
/// 关键：**只认 `ui` 域**。核心的两个会话域各自广播带 `domain` 的
/// `sessionLocked/sessionUnlocked`，而 UI 的状态只应该由 `ui` 域驱动 ——
/// 否则"浏览器扩展解锁"会让桌面端也显示成解锁态（D4：解锁必须是显式动作，
/// 桌面端与扩展不能互相代解锁）。`lockAll()` 会同时广播两个域，ui 那条会
/// 正常触发；bridge 那条被忽略。
///
/// `coreShuttingDown` 没有 domain，一律转发（核心要退出了，UI 得回锁屏）。
String? uiSessionEvent(Map<String, dynamic> event) {
  final domain = event['domain'];
  final isUi = domain == null || domain == 'ui';
  switch (event['event']) {
    case Events.sessionLocked:
      return isUi ? 'locked' : null;
    case Events.sessionUnlocked:
      return isUi ? 'unlocked' : null;
    case Events.coreShuttingDown:
      return 'shuttingDown';
    default:
      return null;
  }
}
