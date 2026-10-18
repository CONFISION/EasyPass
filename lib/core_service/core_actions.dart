// 命名参数用可读的公开名（db / cryptoService / …）映射到私有字段，
// 因此刻意不用 initializing formal（与 master_password_rotation.dart 同款）。
// ignore_for_file: prefer_initializing_formals

import 'dart:math';

import 'package:drift/drift.dart' show Value;
import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/features/health/health_service.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:uuid/uuid.dart';

import 'session_domains.dart';

/// 业务错误：核心把它映射成响应里的 `error`（字符串）+ `errorCode`。
class CoreActionException implements Exception {
  CoreActionException(this.code, [String? message]) : message = message ?? code;

  final String code;
  final String message;

  @override
  String toString() => message;
}

/// UI 域的动作实现。
///
/// 分工：**bridge 域的 9 个动作仍由 `NativeMessagingService` 处理**（形状冻结、
/// 有既有测试网），本类只实现 UI 客户端需要的动作。两者共用同一个仓储与会话
/// 密钥的加解密口径。
class CoreActions {
  CoreActions({
    required AppDatabase db,
    required CryptoService cryptoService,
    required VaultRepository repository,
    required MasterPasswordRotation rotation,
    required ExportImportService exporter,
    required TotpService totpService,
    required SessionDomains sessions,
    required this.onDataChanged,
  })  : _db = db,
        _cryptoService = cryptoService,
        _repository = repository,
        _rotation = rotation,
        _exporter = exporter,
        _totpService = totpService,
        _sessions = sessions;

  final AppDatabase _db;
  final CryptoService _cryptoService;
  final VaultRepository _repository;
  final MasterPasswordRotation _rotation;
  final ExportImportService _exporter;
  final TotpService _totpService;
  final SessionDomains _sessions;

  /// 数据变更回调：参数是受影响的主题集合（`items` / `item` / `folders` / `search`）。
  final void Function(Set<String> topics) onDataChanged;

  static const Uuid _uuid = Uuid();

  /// 二次校验的退避状态（防暴力试密码）。
  int _verifyFailures = 0;
  DateTime? _verifyBlockedUntil;

  // ─── 入口 ──────────────────────────────────────────────

  Future<Map<String, dynamic>> handle(
    String action,
    Map<String, dynamic> params,
  ) async {
    switch (action) {
      case Actions.getStatus:
        return _getStatus();
      case Actions.getAuthState:
        return _getAuthState();
      case Actions.unlock:
        return _unlock(params['password'] as String? ?? '');
      case Actions.lock:
        _sessions.lockAll();
        return {'success': true};
      case Actions.setMasterPassword:
        return _setMasterPassword(
          params['password'] as String? ?? '',
          params['confirmPassword'] as String? ?? '',
        );
      case Actions.changeMasterPassword:
        return _changeMasterPassword(
          params['currentPassword'] as String? ?? '',
          params['newPassword'] as String? ?? '',
          params['confirmPassword'] as String? ?? '',
        );
      case Actions.verifyMasterPassword:
        return _verifyMasterPassword(params['password'] as String? ?? '');
      case Actions.adoptLegacyKeyMaterial:
        return _adoptLegacyKeyMaterial(
          params['salt'] as String?,
          params['passwordHash'] as String?,
        );
      case Actions.setAutoLockMinutes:
        return _setAutoLockMinutes((params['minutes'] as num?)?.toInt() ?? 5);
      case Actions.touchActivity:
        // 只续期 ui 域：两域独立是刻意设计，UI 的活动不该延长浏览器会话。
        _sessions.ui.touch();
        return {'ok': true};
      case Actions.listItems:
        return _listItems(params);
      case Actions.getItem:
        return _getItem(params['id'] as String? ?? '');
      case Actions.listFolders:
        return _listFolders();
      case Actions.searchItems:
        return _searchItems(params['query'] as String? ?? '');
      case Actions.countItemsInFolder:
        return _countItemsInFolder(params['folderId'] as String? ?? '');
      case Actions.getHealthReport:
        return _getHealthReport();
      case Actions.getTotp:
        return _getTotp(params['entryId'] as String? ?? '');
      case Actions.generatePassword:
        return {'password': generatePassword(params)};
      case Actions.saveItem:
        return _saveItem(params['item']);
      case Actions.deleteItem:
        return _deleteItem(params['id'] as String? ?? '');
      case Actions.addFolder:
        return _addFolder(params);
      case Actions.updateFolder:
        return _updateFolder(params);
      case Actions.removeFolder:
        return _removeFolder(params['id'] as String? ?? '');
      case Actions.deleteAllData:
        return _deleteAllData(params['confirm'] == true);
      case Actions.exportVault:
        return _exportVault(
          params['format'] as String? ?? 'plain',
          params['path'] as String?,
        );
      case Actions.importVault:
        return _importVault(
          params['format'] as String? ?? 'easypass',
          params['path'] as String?,
        );
      default:
        throw CoreActionException(
          ErrorCodes.unsupported,
          'Unknown action: $action',
        );
    }
  }

  // ─── 会话 / 认证 ────────────────────────────────────────

  bool get _hasAuthMaterial => _authMaterialPresent;

  bool _authMaterialPresent = false;

  /// 启动时探测一次"核心里有没有校验材料"，之后由写路径维护。
  Future<void> refreshAuthMaterial() async {
    try {
      final salt = await _cryptoService.getStoredSalt();
      final hash = await _cryptoService.getStoredPasswordHash();
      _authMaterialPresent = salt != null && hash != null;
    } catch (_) {
      _authMaterialPresent = false;
    }
  }

  Future<Map<String, dynamic>> _getStatus() async {
    final count = await _repository.countItems();
    final remaining = _sessions.ui.remaining;
    return {
      'connected': true,
      'locked': remaining == null,
      'entryCount': count,
      'idleTimeoutSeconds': _sessions.ui.idleTimeout.inSeconds,
      'autoLockRemainingSeconds': remaining?.inSeconds,
      'protocolVersion': coreProtocolVersion,
      'coreVersion': AppConstants.coreVersion,
      'hasAuthMaterial': _hasAuthMaterial,
      'autoLockMinutes': _sessions.ui.idleTimeout.inMinutes,
    };
  }

  Future<Map<String, dynamic>> _getAuthState() async {
    final remaining = _sessions.ui.remaining;
    final status = remaining != null
        ? 'unlocked'
        : (_hasAuthMaterial ? 'locked' : 'firstRun');
    return {
      'status': status,
      'autoLockMinutes': _sessions.ui.idleTimeout.inMinutes,
      'remainingSeconds': remaining?.inSeconds,
      'hasAuthMaterial': _hasAuthMaterial,
    };
  }

  Future<Map<String, dynamic>> _unlock(String password) async {
    final check = await _rotation.verifyCredentials(password);
    if (check == null) {
      if (!await _rotation.verifier.hasStoredCredential()) {
        throw CoreActionException(
          ErrorCodes.needsKeyMigration,
          ErrorMessages.needsKeyMigration,
        );
      }
      throw CoreActionException(ErrorCodes.unauthorized, '主密码不正确');
    }
    final key = await _rotation.recoverPendingRotation(
      check: check,
      providedKey: check.key,
    );
    if (key == null) {
      throw CoreActionException(ErrorCodes.unauthorized, '请改用新的主密码');
    }
    _sessions.ui.unlock(key);
    return {'success': true};
  }

  Future<Map<String, dynamic>> _setMasterPassword(
    String password,
    String confirm,
  ) async {
    if (password != confirm) {
      throw CoreActionException(ErrorCodes.invalidRequest, '两次输入的密码不一致');
    }
    if (password.length < 8) {
      throw CoreActionException(ErrorCodes.invalidRequest, '主密码至少 8 位');
    }
    final salt = _cryptoService.generateSalt();
    final hash = _cryptoService.hashMasterPassword(password, salt);
    final key = _cryptoService.deriveKey(password, salt);
    await _cryptoService.storeKeyMaterial(salt, hash);
    _authMaterialPresent = true;
    _sessions.ui.unlock(key);
    return {'success': true};
  }

  /// 原子轮换主密码。
  ///
  /// 与 `AuthNotifier.changeMasterPassword` 是同一套步骤（**同一个轮换服务**，
  /// 判据仍是"日志存在 ⇒ 库在新钥匙上"）：M4 完成后 UI 侧那份会被删掉，
  /// 只保留这里的实现。
  Future<Map<String, dynamic>> _changeMasterPassword(
    String current,
    String next,
    String confirm,
  ) async {
    if (next != confirm) {
      throw CoreActionException(ErrorCodes.invalidRequest, '两次输入的密码不一致');
    }
    if (next.length < 8) {
      throw CoreActionException(ErrorCodes.invalidRequest, '主密码至少 8 位');
    }

    final check = await _rotation.verifyCredentials(current);
    if (check == null) {
      throw CoreActionException(ErrorCodes.unauthorized, '当前主密码不正确');
    }

    var oldKey = check.key;
    if (check.hasPendingRotation) {
      final resolved = await _rotation.recoverPendingRotation(
        check: check,
        providedKey: check.key,
      );
      if (resolved == null) {
        throw CoreActionException(ErrorCodes.unauthorized, '请改用新的主密码');
      }
      oldKey = resolved;
    }

    if (!await _repository.encryptionProbeWorks(oldKey)) {
      throw CoreActionException(ErrorCodes.unauthorized, '当前主密码不正确');
    }

    final newSalt = _cryptoService.generateSalt();
    final newKey = _cryptoService.deriveKey(next, newSalt);
    final newHash = _cryptoService.hashMasterPassword(next, newSalt);

    final reencrypted = await _rotation.startRotation(
      oldKey: oldKey,
      newSalt: newSalt,
      newPasswordHash: newHash,
      newKey: newKey,
    );
    final stored = await _rotation.completeRotation(
      PendingRotation(salt: newSalt, passwordHash: newHash),
    );

    // 改完回到锁定态：强制用户用新密码重新进来（与桌面端既有语义一致）。
    _sessions.lockAll();
    onDataChanged({Topics.items, Topics.item, Topics.folders, Topics.search});
    return {
      'success': true,
      'reencrypted': reencrypted,
      'keyMaterialPersisted': stored,
    };
  }

  Future<Map<String, dynamic>> _verifyMasterPassword(String password) async {
    final blockedUntil = _verifyBlockedUntil;
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) {
      throw CoreActionException(
        ErrorCodes.rateLimited,
        ErrorMessages.rateLimited,
      );
    }
    final ok = await _rotation.verifier.isCorrect(password);
    if (ok) {
      _verifyFailures = 0;
      _verifyBlockedUntil = null;
      return {'ok': true};
    }
    _verifyFailures++;
    if (_verifyFailures >= 5) {
      // 连续失败 5 次后冷却 30 秒（简单的进程内退避；核心重启即重置）。
      _verifyBlockedUntil = DateTime.now().add(const Duration(seconds: 30));
      _verifyFailures = 0;
    }
    return {'ok': false};
  }

  /// 迁移期专用：把旧版存在系统钥匙串里的校验材料交给核心（D1）。
  ///
  /// 只在核心还没有校验材料时接受一次；不校验密码本身（调用方是握有钥匙串的
  /// UI，且材料成对写入）。写入后立刻按"能否推导出一致的哈希"自检。
  Future<Map<String, dynamic>> _adoptLegacyKeyMaterial(
    String? salt,
    String? passwordHash,
  ) async {
    if (salt == null || passwordHash == null || salt.isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '校验材料不完整');
    }
    if (_hasAuthMaterial) {
      throw CoreActionException(ErrorCodes.invalidRequest, '校验材料已存在，拒绝覆盖');
    }
    await _cryptoService.storeKeyMaterial(salt, passwordHash);
    await refreshAuthMaterial();
    if (!_hasAuthMaterial) {
      throw CoreActionException(ErrorCodes.storageError, '校验材料写入失败');
    }
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _setAutoLockMinutes(int minutes) async {
    final clamped = minutes.clamp(1, 60);
    await _cryptoService.setAutoLockMinutes(clamped);
    _sessions.setIdleTimeout(Duration(minutes: clamped));
    return {'ok': true, 'autoLockMinutes': clamped};
  }

  // ─── 读 ────────────────────────────────────────────────

  void _requireUnlocked() {
    if (!_sessions.ui.isUnlocked) {
      throw CoreActionException(ErrorCodes.locked, ErrorMessages.locked);
    }
    _sessions.ui.touch();
  }

  Future<Map<String, dynamic>> _listItems(Map<String, dynamic> params) async {
    _requireUnlocked();
    final items = await _repository.getItems(
      folderId: params['folderId'] as String?,
      type: params['type'] == null
          ? null
          : EntryType.fromWire(params['type'] as String?),
      favoritesOnly: params['favoritesOnly'] == true,
    );
    return {'items': [for (final item in items) itemToJson(item)]};
  }

  Future<Map<String, dynamic>> _getItem(String id) async {
    _requireUnlocked();
    final item = await _repository.getItem(id);
    if (item == null) {
      throw CoreActionException(ErrorCodes.notFound, ErrorMessages.notFound);
    }
    return {'item': itemToJson(item)};
  }

  Future<Map<String, dynamic>> _listFolders() async {
    _requireUnlocked();
    final folders = await _repository.getFolders();
    return {
      'folders': [
        for (final folder in folders)
          WireFolder(
            id: folder.id,
            name: folder.name,
            icon: folder.icon ?? 'folder',
            createdAt: folder.createdAt,
            updatedAt: folder.updatedAt,
          ).toJson(),
      ],
    };
  }

  Future<Map<String, dynamic>> _searchItems(String query) async {
    _requireUnlocked();
    if (query.trim().isEmpty) return {'items': <Map<String, dynamic>>[]};
    final items = await _repository.searchItems(query);
    return {'items': [for (final item in items) itemToJson(item)]};
  }

  Future<Map<String, dynamic>> _countItemsInFolder(String folderId) async {
    _requireUnlocked();
    return {'count': await _repository.countItemsInFolder(folderId)};
  }

  Future<Map<String, dynamic>> _getHealthReport() async {
    _requireUnlocked();
    final items = await _repository.getItems(type: EntryType.login);
    final report = HealthService.analyze([
      for (final item in items) HealthEntry.fromItem(item),
    ]);
    return {
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

  Future<Map<String, dynamic>> _getTotp(String entryId) async {
    _requireUnlocked();
    final item = await _repository.getItem(entryId);
    if (item == null || !item.isLogin) {
      throw CoreActionException(ErrorCodes.notFound, ErrorMessages.notFound);
    }
    final secret = item.loginOrEmpty.totpSecret;
    if (secret.isEmpty) {
      throw CoreActionException(ErrorCodes.notFound, '该条目没有 TOTP');
    }
    const period = 30;
    return {
      'code': _totpService.generateTotp(secret, period: period),
      'period': period,
      'remainingSeconds': _totpService.getRemainingSeconds(period: period),
    };
  }

  // ─── 写 ────────────────────────────────────────────────

  Future<Map<String, dynamic>> _saveItem(Object? rawItem) async {
    _requireUnlocked();
    if (rawItem is! Map) {
      throw CoreActionException(ErrorCodes.invalidRequest, '缺少 item');
    }
    final item = itemFromJson(Map<String, dynamic>.from(rawItem));
    if (item.name.trim().isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '标题不能为空');
    }
    await _repository.saveItem(item);
    onDataChanged({Topics.items, Topics.item, Topics.folders, Topics.search});
    return {'id': item.id};
  }

  Future<Map<String, dynamic>> _deleteItem(String id) async {
    _requireUnlocked();
    await _repository.deleteItem(id);
    onDataChanged({Topics.items, Topics.item, Topics.folders, Topics.search});
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _addFolder(Map<String, dynamic> params) async {
    _requireUnlocked();
    final name = (params['name'] as String? ?? '').trim();
    if (name.isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '文件夹名不能为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _uuid.v4();
    await _repository.addFolder(
      FoldersCompanion.insert(
        id: id,
        name: name,
        icon: Value(params['icon'] as String? ?? 'folder'),
        createdAt: now,
        updatedAt: now,
      ),
    );
    onDataChanged({Topics.folders, Topics.items});
    return {'id': id};
  }

  Future<Map<String, dynamic>> _updateFolder(Map<String, dynamic> params) async {
    _requireUnlocked();
    final id = params['id'] as String? ?? '';
    if (id.isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '缺少 id');
    }
    final companion = FoldersCompanion(
      name: params['name'] == null
          ? const Value.absent()
          : Value((params['name'] as String).trim()),
      icon: params['icon'] == null
          ? const Value.absent()
          : Value(params['icon'] as String),
      updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
    );
    await _repository.updateFolder(id, companion);
    onDataChanged({Topics.folders, Topics.items});
    return {'ok': true};
  }

  Future<Map<String, dynamic>> _removeFolder(String id) async {
    _requireUnlocked();
    final unassigned = await _repository.countItemsInFolder(id);
    await _repository.removeFolder(id);
    onDataChanged({Topics.folders, Topics.items, Topics.item});
    return {'ok': true, 'unassigned': unassigned};
  }

  /// 清空整个保险库（设置页"删除所有数据"）。
  ///
  /// 走**一个事务**：半途失败不会留下"条目删了一半"的库。历史上这里是 UI
  /// 直连数据库的旁路，还绕过了文件夹解绑语义。
  Future<Map<String, dynamic>> _deleteAllData(bool confirmed) async {
    if (!confirmed) {
      throw CoreActionException(ErrorCodes.invalidRequest, '需要显式确认');
    }
    _requireUnlocked();
    var entries = 0;
    var folders = 0;
    await _db.transaction(() async {
      for (final row in await _db.getAllEntries()) {
        await _db.deleteEntry(row.id);
        entries++;
      }
      for (final folder in await _db.getAllFolders()) {
        await _db.deleteFolder(folder.id);
        folders++;
      }
    });
    onDataChanged({Topics.items, Topics.item, Topics.folders, Topics.search});
    return {'ok': true, 'entries': entries, 'folders': folders};
  }

  // ─── 导出 / 导入（核心直接读写文件）─────────────────────

  Future<Map<String, dynamic>> _exportVault(String format, String? path) async {
    _requireUnlocked();
    if (path == null || path.isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '缺少导出路径');
    }
    final String content;
    switch (format) {
      case 'encrypted':
        content = await _exporter.exportEncrypted();
      case 'bitwarden':
        content = await _exporter.exportBitwardenJson();
      case 'plain':
      default:
        content = await _exporter.exportPlainJson();
    }
    final file = await _exporter.writeToFile(content, path);
    return {'ok': true, 'path': file.path, 'bytes': content.length};
  }

  Future<Map<String, dynamic>> _importVault(String format, String? path) async {
    _requireUnlocked();
    if (path == null || path.isEmpty) {
      throw CoreActionException(ErrorCodes.invalidRequest, '缺少导入路径');
    }
    final content = await _exporter.readFromFile(path);
    switch (format) {
      case 'bitwardenJson':
        final report = await _exporter.importBitwardenJson(content);
        onDataChanged(
            {Topics.items, Topics.item, Topics.folders, Topics.search});
        return {
          'ok': true,
          'imported': report.entries,
          'folders': report.folders,
          'skipped': report.skipped.length,
          // 明细：设置页原有"有损映射提示 / 跳过原因"两条文案要靠它们。
          'skippedDetails': report.skipped,
          'extraUris': report.extraUris,
          'cardsAsNotes': report.cardsAsNotes,
        };
      case 'bitwardenCsv':
        final report = await _exporter.importBitwardenCsv(content);
        onDataChanged(
            {Topics.items, Topics.item, Topics.folders, Topics.search});
        return {
          'ok': true,
          'imported': report.entries,
          'folders': report.folders,
          'skipped': report.skipped.length,
          'skippedDetails': report.skipped,
          'extraUris': report.extraUris,
          'cardsAsNotes': report.cardsAsNotes,
        };
      case 'easypass':
      default:
        // `ExportImportService.importFromJson` 回的是 {'folders': n, 'entries': m}
        // —— 这里必须读 `entries`，早期版本误读 `imported` 会永远显示"导入 0 条"。
        final result = await _exporter.importFromJson(content);
        onDataChanged(
            {Topics.items, Topics.item, Topics.folders, Topics.search});
        return {
          'ok': true,
          'imported': result['entries'] ?? result['imported'] ?? 0,
          'folders': result['folders'] ?? 0,
          'skipped': result['skipped'] ?? 0,
        };
    }
  }
}

/// 密码生成器（纯函数，与桥接侧同名参数）。
///
/// 与 `NativeMessagingService._generatePassword` 是同款算法；桥接那份保持不动
/// 是**刻意**的（协议形状冻结、有既有测试）。UI 侧的生成器留在 UI 本地，
/// 这里只是给"客户端要求核心生成"的场景兜底。
String generatePassword(Map<String, dynamic> options) {
  final length = (options['length'] as num?)?.toInt() ?? 16;
  final useUpper = options['useUpper'] as bool? ?? true;
  final useLower = options['useLower'] as bool? ?? true;
  final useNumbers = options['useNumbers'] as bool? ?? true;
  final useSymbols = options['useSymbols'] as bool? ?? true;

  final random = Random.secure();
  final charSets = <String>[];
  if (useUpper) charSets.add('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
  if (useLower) charSets.add('abcdefghijklmnopqrstuvwxyz');
  if (useNumbers) charSets.add('0123456789');
  if (useSymbols) charSets.add(r'!@#$%^&*()-_=+[]{}|;:,.<>?');
  if (charSets.isEmpty) return '';

  final allChars = charSets.join();
  final buffer = StringBuffer();
  for (final set in charSets) {
    buffer.write(set[random.nextInt(set.length)]);
  }
  while (buffer.length < length) {
    buffer.write(allChars[random.nextInt(allChars.length)]);
  }
  final chars = buffer.toString().split('')..shuffle(random);
  return chars.join();
}
