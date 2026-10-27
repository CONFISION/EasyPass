import 'dart:async';

import 'package:easypass/client/vault_api.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/health/health_service.dart';
import 'package:easypass/protocol/protocol.dart';

/// 内存版 [VaultApi] —— 测试里的"假核心"。
///
/// 为什么需要它：M4 之后 UI 只跟 [VaultApi] 说话，所以 UI 层的回归测试
/// （认证状态机、错误码映射、设置页的导出 / 导入 / 清库）应该注入这个假实现，
/// 而不是去起一个真核心（`CoreSession` 会找 `daemon.json` / 拉起
/// `easypass_core`，测试环境里必然失败）。
///
/// 它**不**复制核心的加密 / 轮换语义 —— 那些由核心自己的一致性测试盯着
/// （见 `test/core_actions_harness.dart`）。这里只负责：
/// * 记录调用顺序（`calls`），让"UI 到底把请求发给谁"可断言；
/// * 模拟核心的会话状态机（firstRun / locked / unlocked + 自动锁定分钟数）；
/// * 注入失败（`*Failure` 字段），让错误码映射可断言。
class FakeVaultApi implements VaultApi {
  FakeVaultApi({
    bool hasAuthMaterial = true,
    String? masterPassword,
    String initialStatus = 'locked',
    int autoLockMinutes = 5,
  })  :
        // 具名参数不能以下划线开头，所以 `this._hasAuthMaterial` 这种
        // initializing formal 写法在这里是非法的（lint 的建议不可用）。
        // ignore: prefer_initializing_formals
        _hasAuthMaterial = hasAuthMaterial,
        // ignore: prefer_initializing_formals
        _masterPassword = masterPassword,
        _status = initialStatus,
        // ignore: prefer_initializing_formals
        _autoLockMinutes = autoLockMinutes;

  // ─── 可断言状态 ────────────────────────────────────────

  /// 按调用顺序记录的动作名（`unlock` / `setMasterPassword` / …）。
  final List<String> calls = <String>[];

  /// 导出请求过的格式，按顺序。
  final List<String> exportedFormats = <String>[];

  /// 导出请求过的绝对路径，按顺序。
  final List<String> exportedPaths = <String>[];

  /// 导入请求过的 `(format, path)`，按顺序。
  final List<(String, String)> importedRequests = <(String, String)>[];

  /// 迁移时交给核心的旧钥匙串材料。
  String? adoptedSalt;
  String? adoptedPasswordHash;

  /// 内存条目 / 文件夹（读接口用）。写接口会像真核心一样推变更主题。
  final Map<String, VaultItem> items = <String, VaultItem>{};
  final Map<String, WireFolder> folders = <String, WireFolder>{};

  /// [listItems] 收到过的过滤条件，按顺序（断言"UI 把三个维度原样交给了核心"）。
  final List<({String? folderId, EntryType? type, bool favoritesOnly})>
      listItemRequests =
      <({String? folderId, EntryType? type, bool favoritesOnly})>[];

  /// [getItem] 请求过的条目 id，按顺序。
  final List<String> getItemRequests = <String>[];

  /// [searchItems] 请求过的查询词，按顺序（**原样**记录，UI 不该自己解析前缀）。
  final List<String> searchQueries = <String>[];

  /// 打开后，读接口在未解锁时抛 `VaultApiException(code: locked)` ——
  /// 真核心的 `_requireUnlocked()` 语义。
  ///
  /// **默认关闭**：既有的 UI 测试大多只想塞数据、不想先解锁，所以这里不强制。
  /// 需要验证"未解锁 → 空列表 + 解锁后自动恢复"的用例请显式打开。
  bool lockEnforcedReads = false;

  /// "磁盘"：导出写入这里，导入从这里读。键是绝对路径。
  final Map<String, String> files = <String, String>{};

  /// 下一次 [importVault] 的回包（键与核心一致）。
  Map<String, dynamic> nextImportResponse = <String, dynamic>{
    'ok': true,
    'imported': 0,
    'folders': 0,
    'skipped': 0,
  };

  // ─── 故障注入 ──────────────────────────────────────────

  /// 非 null 时对应方法直接抛出它（可以是 [VaultApiException]，也可以是别的
  /// 异常，用来模拟"核心连不上"）。
  Object? authSnapshotFailure;

  /// 从第 n 次 [authSnapshot] 调用（1 基）起开始失败 —— 用来模拟"解锁成功之后
  /// 连接抖了一下"，验证 UI 不会把已经成功的动作报成失败。
  int? authSnapshotFailFromCall;

  Object? unlockFailure;
  Object? lockFailure;
  Object? setMasterPasswordFailure;
  Object? changeMasterPasswordFailure;
  Object? adoptLegacyKeyMaterialFailure;
  Object? setAutoLockMinutesFailure;
  Object? exportFailure;
  Object? importFailure;
  Object? deleteAllDataFailure;

  /// 非 null 时读接口（listItems / getItem / listFolders / searchItems /
  /// countItemsInFolder）抛它 —— 用来模拟"核心连不上 / 挂了"，验证 UI 的
  /// 错误态 + 重试路径。
  Object? readFailure;

  /// 改主密码后是否把会话置为锁定态（真核心会 `lockAll()`）。
  /// 置 false 可以验证"即使核心忘了锁，UI 也自己回到锁定态"。
  bool lockOnChangeMasterPassword = true;

  final StreamController<String> _changes =
      StreamController<String>.broadcast();
  final StreamController<String> _sessionEvents =
      StreamController<String>.broadcast();

  String _status;
  bool _hasAuthMaterial;
  String? _masterPassword;
  int _autoLockMinutes;
  int? _remainingSeconds;
  int _authSnapshotCalls = 0;

  // ─── 断言辅助 ──────────────────────────────────────────

  String get status => _status;

  bool get isUnlocked => _status == 'unlocked';

  bool get hasAuthMaterial => _hasAuthMaterial;

  String? get masterPassword => _masterPassword;

  int get autoLockMinutes => _autoLockMinutes;

  int? get remainingSeconds => _remainingSeconds;

  /// 核心收到过某个动作吗（顺序无关）。
  bool called(String action) => calls.contains(action);

  /// 冒出某个动作的次序编号（第一次出现的下标）。
  int callIndex(String action) => calls.indexOf(action);

  /// 让锁定 / 解锁在测试里可控（模拟核心的空闲超时把它自己锁了）。
  void forceStatus(String status, {int? remainingSeconds}) {
    _status = status;
    _remainingSeconds = remainingSeconds;
  }

  void emitChange(String topic) {
    if (!_changes.isClosed) _changes.add(topic);
  }

  /// 模拟核心的会话事件（`locked` / `unlocked` / `shuttingDown`）。
  ///
  /// 真核心在空闲超时后广播 `sessionLocked` —— 用它验证 UI 会跟着回到锁定态
  /// （这是"M4 之后最容易漏的一致性缺口"）。
  void emitSessionEvent(String event) {
    if (!_sessionEvents.isClosed) _sessionEvents.add(event);
  }

  /// 真核心写完库会推的主题（见 `CoreActions` 各写动作的 `onDataChanged`）。
  void _emitAll() {
    for (final topic in Topics.all) {
      emitChange(topic);
    }
  }

  /// 未解锁时读接口的统一拒绝（只有 [lockEnforcedReads] 打开时生效）。
  void _requireUnlocked() {
    if (readFailure case final failure?) _throw(failure);
    if (!lockEnforcedReads) return;
    if (_status != 'unlocked') {
      throw VaultApiException(ErrorCodes.locked, ErrorMessages.locked);
    }
  }

  void dispose() {
    _changes.close();
    _sessionEvents.close();
  }

  Never _throw(Object failure) {
    if (failure is Exception || failure is Error) {
      throw failure;
    }
    throw StateError('$failure');
  }

  // ─── 会话 / 认证 ───────────────────────────────────────

  @override
  Future<AuthSnapshot> authSnapshot() async {
    calls.add('authSnapshot');
    _authSnapshotCalls++;
    final failure = authSnapshotFailure;
    if (failure != null) _throw(failure);
    final failFrom = authSnapshotFailFromCall;
    if (failFrom != null && _authSnapshotCalls >= failFrom) {
      throw StateError('FakeVaultApi: 连接在快照 #$_authSnapshotCalls 时断了');
    }
    return AuthSnapshot(
      status: _status,
      autoLockMinutes: _autoLockMinutes,
      hasAuthMaterial: _hasAuthMaterial,
      remainingSeconds: _remainingSeconds,
    );
  }

  @override
  Future<void> unlock(String password) async {
    calls.add('unlock');
    final failure = unlockFailure;
    if (failure != null) _throw(failure);
    if (!_hasAuthMaterial) {
      throw VaultApiException(
        ErrorCodes.needsKeyMigration,
        ErrorMessages.needsKeyMigration,
      );
    }
    if (password != _masterPassword) {
      throw VaultApiException(ErrorCodes.unauthorized, '主密码不正确');
    }
    _status = 'unlocked';
    _remainingSeconds = _autoLockMinutes * 60;
  }

  @override
  Future<void> lock() async {
    calls.add('lock');
    final failure = lockFailure;
    if (failure != null) _throw(failure);
    _status = 'locked';
    _remainingSeconds = null;
  }

  @override
  Future<void> setMasterPassword(String password, String confirmPassword) async {
    calls.add('setMasterPassword');
    final failure = setMasterPasswordFailure;
    if (failure != null) _throw(failure);
    if (password != confirmPassword) {
      throw VaultApiException(ErrorCodes.invalidRequest, '两次输入的密码不一致');
    }
    if (password.length < 8) {
      throw VaultApiException(ErrorCodes.invalidRequest, '主密码至少 8 位');
    }
    _masterPassword = password;
    _hasAuthMaterial = true;
    // 核心设置成功时顺手解锁本次会话（见 CoreActions._setMasterPassword）。
    _status = 'unlocked';
    _remainingSeconds = _autoLockMinutes * 60;
  }

  /// 模拟"轮换成功但新校验材料没落盘"（钥匙串/存储写失败的真实场景）。
  bool keyMaterialPersistedOnChange = true;

  @override
  Future<ChangePasswordResult> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  }) async {
    calls.add('changeMasterPassword');
    final failure = changeMasterPasswordFailure;
    if (failure != null) _throw(failure);
    if (newPassword != confirmPassword) {
      throw VaultApiException(ErrorCodes.invalidRequest, '两次输入的密码不一致');
    }
    if (newPassword.length < 8) {
      throw VaultApiException(ErrorCodes.invalidRequest, '主密码至少 8 位');
    }
    if (currentPassword != _masterPassword) {
      throw VaultApiException(ErrorCodes.unauthorized, '当前主密码不正确');
    }
    _masterPassword = newPassword;
    _hasAuthMaterial = true;
    if (lockOnChangeMasterPassword) {
      _status = 'locked';
      _remainingSeconds = null;
    }
    return ChangePasswordResult(
      keyMaterialPersisted: keyMaterialPersistedOnChange,
      reencrypted: items.length,
    );
  }

  @override
  Future<bool> verifyMasterPassword(String password) async {
    calls.add('verifyMasterPassword');
    return password == _masterPassword;
  }

  @override
  Future<void> adoptLegacyKeyMaterial({
    required String salt,
    required String passwordHash,
  }) async {
    calls.add('adoptLegacyKeyMaterial');
    final failure = adoptLegacyKeyMaterialFailure;
    if (failure != null) _throw(failure);
    if (_hasAuthMaterial) {
      throw VaultApiException(ErrorCodes.invalidRequest, '校验材料已存在，拒绝覆盖');
    }
    adoptedSalt = salt;
    adoptedPasswordHash = passwordHash;
    _hasAuthMaterial = true;
    _status = 'locked';
  }

  @override
  Future<void> setAutoLockMinutes(int minutes) async {
    calls.add('setAutoLockMinutes');
    final failure = setAutoLockMinutesFailure;
    if (failure != null) _throw(failure);
    _autoLockMinutes = minutes.clamp(1, 60).toInt();
  }

  // ─── 读 ────────────────────────────────────────────────

  @override
  Future<List<VaultItem>> listItems({
    String? folderId,
    EntryType? type,
    bool favoritesOnly = false,
  }) async {
    calls.add('listItems');
    listItemRequests.add((
      folderId: folderId,
      type: type,
      favoritesOnly: favoritesOnly,
    ));
    _requireUnlocked();
    return items.values.where((item) {
      if (folderId != null && item.folderId != folderId) return false;
      if (type != null && item.type != type) return false;
      if (favoritesOnly && !item.isFavorite) return false;
      return true;
    }).toList();
  }

  @override
  Future<VaultItem?> getItem(String id) async {
    calls.add('getItem');
    getItemRequests.add(id);
    _requireUnlocked();
    return items[id];
  }

  @override
  Future<List<WireFolder>> listFolders() async {
    calls.add('listFolders');
    _requireUnlocked();
    return folders.values.toList();
  }

  /// 简化版匹配：走 [VaultItem.searchableText]（名字 / 备注 / 类型专属字段 /
  /// 非隐藏自定义字段），**不**解释 `type:` / `folder:` / `url:` 前缀 —— 那是
  /// 核心自己的语义，由核心的测试盯着；UI 侧的断言应该是"查询词原样交给核心"
  /// （见 [searchQueries]）。
  @override
  Future<List<VaultItem>> searchItems(String query) async {
    calls.add('searchItems');
    searchQueries.add(query);
    _requireUnlocked();
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const <VaultItem>[];
    return items.values
        .where((item) => item.searchableText.contains(needle))
        .toList();
  }

  @override
  Future<int> countItemsInFolder(String folderId) async {
    calls.add('countItemsInFolder');
    _requireUnlocked();
    return items.values.where((item) => item.folderId == folderId).length;
  }

  @override
  Future<Map<String, dynamic>> healthReport() async {
    calls.add('healthReport');
    final failure = readFailure;
    if (failure != null) _throw(failure);
    _requireUnlocked();
    // 与真核心同构：同一套 analyze 算出统计数字，**不**包含明文密码。
    final report = HealthService.analyze([
      for (final item in items.values) HealthEntry.fromItem(item),
    ]);
    return <String, dynamic>{
      'totalEntries': report.totalEntries,
      'score': report.score,
      'level': report.level.name,
      'reusedGroupCount': report.reusedGroupCount,
      'weakPasswords': [
        for (final issue in report.weakPasswords)
          {
            'entryId': issue.entryId,
            'entryName': issue.entryName,
            'reason': issue.reason.name,
          },
      ],
      'reusedPasswords': [
        for (final issue in report.reusedPasswords)
          {
            'entryId': issue.entryId,
            'entryName': issue.entryName,
            'sharedCount': issue.sharedCount,
          },
      ],
      'noTotpEntries': [
        for (final issue in report.noTotpEntries)
          {'entryId': issue.entryId, 'entryName': issue.entryName},
      ],
      'noUrlEntries': [
        for (final issue in report.noUrlEntries)
          {'entryId': issue.entryId, 'entryName': issue.entryName},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getTotp(String entryId) async {
    calls.add('getTotp');
    return <String, dynamic>{'code': '000000', 'period': 30};
  }

  // ─── 写 ────────────────────────────────────────────────

  @override
  Future<String> saveItem(VaultItem item) async {
    calls.add('saveItem');
    items[item.id] = item;
    // 真核心 saveItem 后推 items / item / folders / search（见 CoreActions）。
    _emitAll();
    return item.id;
  }

  @override
  Future<void> deleteItem(String id) async {
    calls.add('deleteItem');
    items.remove(id);
    _emitAll();
  }

  @override
  Future<String> addFolder(String name, {String icon = 'folder'}) async {
    calls.add('addFolder');
    final id = 'folder-${folders.length + 1}';
    folders[id] = WireFolder(
      id: id,
      name: name,
      icon: icon,
      createdAt: 0,
      updatedAt: 0,
    );
    _emitAll();
    return id;
  }

  @override
  Future<void> updateFolder(String id, {String? name, String? icon}) async {
    calls.add('updateFolder');
    final current = folders[id];
    if (current == null) return;
    folders[id] = WireFolder(
      id: id,
      name: name ?? current.name,
      icon: icon ?? current.icon,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
    );
    _emitAll();
  }

  @override
  Future<void> removeFolder(String id) async {
    calls.add('removeFolder');
    folders.remove(id);
    // 真核心 removeFolder 会先把条目解除归属（drift 不开外键，ON DELETE SET
    // NULL 不生效），否则界面上会留下指向不存在文件夹的幽灵条目。
    for (final entry in items.entries.toList()) {
      if (entry.value.folderId == id) {
        items[entry.key] = entry.value.copyWith(folderId: null);
      }
    }
    _emitAll();
  }

  @override
  Future<void> deleteAllData() async {
    calls.add('deleteAllData');
    final failure = deleteAllDataFailure;
    if (failure != null) _throw(failure);
    items.clear();
    folders.clear();
    _emitAll();
  }

  // ─── 导出 / 导入 ───────────────────────────────────────

  @override
  Future<void> exportVault(String format, String path) async {
    calls.add('exportVault');
    final failure = exportFailure;
    if (failure != null) _throw(failure);
    exportedFormats.add(format);
    exportedPaths.add(path);
    // 只写一个可辨识的占位内容：内容本身是核心的职责，UI 不该碰。
    files[path] = 'export:$format:${items.length}';
  }

  @override
  Future<Map<String, dynamic>> importVault(String format, String path) async {
    calls.add('importVault');
    final failure = importFailure;
    if (failure != null) _throw(failure);
    importedRequests.add((format, path));
    if (!files.containsKey(path)) {
      throw VaultApiException(ErrorCodes.notFound, '找不到该文件');
    }
    return nextImportResponse;
  }

  @override
  Stream<String> get changes => _changes.stream;

  @override
  Stream<String> get sessionEvents => _sessionEvents.stream;

  @override
  Future<void> touchActivity() async {
    calls.add('touchActivity');
    // 真核心只续期 ui 域（bridge 域独立），这里只记录调用。
  }

  // ─── 智能体访问（内存版：只记录调用，够 UI 测试用）────────

  /// 假实现里的配对列表（`createAgentPairing` 会往里加）。
  final List<Map<String, dynamic>> agentPairings = <Map<String, dynamic>>[];

  bool agentUnlocked = false;
  bool agentEnabled = false;

  @override
  Future<bool> agentDomainUnlocked() async {
    calls.add('agentDomainUnlocked');
    return agentUnlocked;
  }

  @override
  Future<Map<String, dynamic>> agentAccessState() async {
    calls.add('agentAccessState');
    return {'enabled': agentEnabled, 'agentUnlocked': agentUnlocked};
  }

  @override
  Future<void> enableAgentAccess() async {
    calls.add('enableAgentAccess');
    agentEnabled = true;
    agentUnlocked = true;
  }

  @override
  Future<void> disableAgentAccess() async {
    calls.add('disableAgentAccess');
    agentEnabled = false;
    agentUnlocked = false;
  }

  @override
  Future<void> resetAgentKey() async {
    calls.add('resetAgentKey');
  }

  @override
  Future<List<Map<String, dynamic>>> listAgentPairings() async {
    calls.add('listAgentPairings');
    return List<Map<String, dynamic>>.from(agentPairings);
  }

  @override
  Future<Map<String, dynamic>> createAgentPairing({
    required String nickname,
    required String mode,
  }) async {
    calls.add('createAgentPairing');
    final id = 'p_${agentPairings.length + 1}';
    final key = 'key-$id';
    agentPairings.add({
      'id': id,
      'nickname': nickname,
      'mode': mode,
      'trusted': mode == 'trusted',
      'revoked': false,
      'createdAt': 0,
      'lastUsedAt': null,
      'calls': 0,
    });
    return {'id': id, 'key': key, 'nickname': nickname, 'mode': mode};
  }

  @override
  Future<void> revokeAgentPairing(String id) async {
    calls.add('revokeAgentPairing');
    for (final pairing in agentPairings) {
      if (pairing['id'] == id) pairing['revoked'] = true;
    }
    agentUnlocked = false;
  }

  @override
  Future<void> setAgentAccessMode({
    required String id,
    required String mode,
    String? password,
  }) async {
    calls.add('setAgentAccessMode');
    for (final pairing in agentPairings) {
      if (pairing['id'] != id) continue;
      pairing['mode'] = mode;
      pairing['trusted'] = mode == 'trusted' && (password ?? '').isNotEmpty;
    }
    agentUnlocked = mode == 'trusted' && (password ?? '').isNotEmpty;
  }

  @override
  Future<void> unlockAgentDomain(String password) async {
    calls.add('unlockAgentDomain');
    if (password.isEmpty) {
      throw VaultApiException(ErrorCodes.unauthorized, '主密码不正确');
    }
    agentUnlocked = true;
  }

  @override
  Future<void> lockAgentDomain() async {
    calls.add('lockAgentDomain');
    agentUnlocked = false;
  }
}


