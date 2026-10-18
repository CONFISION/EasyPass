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
    var client = info == null ? null : await _tryConnect(info);
    if (client != null) {
      _adopt(client);
      return client;
    }

    // 发现文件缺失/陈旧：清掉残留后按需拉起核心。
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
      switch (event['event']) {
        case Events.changed:
          final topic = event['topic'];
          if (topic is String) _changes.add(topic);
        case Events.sessionLocked:
          _sessionEvents.add('locked');
        case Events.sessionUnlocked:
          _sessionEvents.add('unlocked');
        case Events.coreShuttingDown:
          _sessionEvents.add('shuttingDown');
      }
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
  Future<void> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    await _call(Actions.changeMasterPassword, {
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'confirmPassword': confirmPassword,
    });
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
