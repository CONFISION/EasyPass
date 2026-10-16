import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:uuid/uuid.dart';

import '../../core/crypto/crypto_service.dart';
import '../database/database.dart';
import '../models/entry_fields.dart';
import '../models/entry_type.dart';
import '../models/vault_item.dart';
import '../repositories/vault_repository.dart';
import 'bitwarden_importer.dart';

/// 导入文件无法解析 / 解不开时抛出。
///
/// 消息面向用户（设置页直接把 `toString()` 塞进 `importFailed` 文案），
/// 所以写成一句可读的英文短句，不要带 "Import failed:" 前缀（外面已有）。
class ExportImportException implements Exception {
  final String message;

  const ExportImportException(this.message);

  @override
  String toString() => message;
}

/// 导出 / 导入服务（导出格式 **2.0.0**）。
///
/// 两种导出格式：
/// - **明文**：`format: 'plain'`，条目形状就是 `VaultItem.toJson()` ——
///   `id / folder_id / type / name / notes / is_favorite / created_at /
///   updated_at`，加**当前类型自己的**字段块（`login` / `identity` /
///   `ssh_key`）与非空 `custom_fields`。给用户自己看，别拿去分享。
/// - **加密备份**：`format: 'encrypted'`，整份明文 JSON 用会话密钥
///   AES-256-CBC 加密（`IV(16) || ciphertext` 的 base64）。文件里**不得**
///   出现明文密码 / TOTP 密钥 / SSH 私钥 / 口令 / 证件号。
///
/// 导入：
/// - 认 2.0.0，也认 1.x（没有 `type` → 登录；`url/username/password/
///   totp_secret` 平铺在条目顶层 —— `VaultItem.fromJson` 负责这部分）；
/// - 未知 `type` 一律回退登录，绝不因为类型字段乱七八糟就崩；
/// - 持久化统一走 [VaultRepository.saveItem]（登录字段由 `VaultItemMapper`
///   用会话密钥重新加密），本服务**不再**自己拼 `PasswordEntriesCompanion`；
/// - **先全部解析校验、再写库**（写库还包在一个事务里）：解析失败就抛
///   [ExportImportException]，不会"导一半"留下半个库。
class ExportImportService {
  /// 导出格式版本（1.0.0 → 2.0.0）。
  static const String formatVersion = '2.0.0';

  static const String appName = 'EasyPass';

  /// `folders` 里缺 id 时的兜底名。
  static const String _unnamedFolder = 'Unnamed Folder';

  /// `entries` 里缺 name 时的兜底名。
  static const String _unnamedEntry = 'Unnamed Entry';

  /// 极老导出把密文直接写在这些键上（1.0.0 之前的中间形态）。
  /// 有明文键就用明文键；只有密文键时才用会话密钥解。
  static const Map<String, String> _legacyCipherKeys = {
    'password': 'password_encrypted',
    'notes': 'notes_encrypted',
    'totp_secret': 'totp_secret_encrypted',
  };

  final AppDatabase _db;
  final Uint8List Function() _getEncryptionKey;
  final VaultRepository? _repositoryOverride;
  final CryptoService _cryptoService;

  /// 兼容旧构造：`ExportImportService(db, () => sessionKey)` 仍然可用，
  /// 内部会用同一份 db + 密钥自建仓储。
  ExportImportService(
    this._db,
    this._getEncryptionKey, {
    VaultRepository? repository,
    CryptoService? cryptoService,
  })  : _repositoryOverride = repository,
        _cryptoService = cryptoService ?? CryptoService();

  /// 条目读写一律经由仓储（加密 / 解密只在 `VaultItemMapper` 里发生）。
  late final VaultRepository _repository = _repositoryOverride ??
      VaultRepository(
        db: _db,
        cryptoService: _cryptoService,
        keyReader: () {
          try {
            return _getEncryptionKey();
          } catch (_) {
            return null; // 未解锁：读返回空，写抛 VaultLockedException
          }
        },
      );

  /// 导出全部条目为明文 JSON（含密码 / TOTP 密钥，仅供用户自己查看）。
  Future<String> exportPlainJson() async {
    // 未解锁时直接抛错（设置页会展示错误文案），不要导出一个空文件。
    _getEncryptionKey();

    final items = await _repository.getItems();
    final folders = await _repository.getFolders();

    final data = <String, dynamic>{
      'version': formatVersion,
      'app': appName,
      'format': 'plain',
      'exported_at': DateTime.now().toIso8601String(),
      'folders': [
        for (final folder in folders)
          {
            'id': folder.id,
            'name': folder.name,
            'icon': folder.icon,
            'created_at': folder.createdAt,
            'updated_at': folder.updatedAt,
          },
      ],
      // 条目形状由 VaultItem.toJson() 决定：只写当前类型的字段块，
      // 空的自定义字段不写。
      'entries': [for (final item in items) item.toJson()],
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 导出为加密备份（推荐用于备份）。
  Future<String> exportEncrypted() async {
    final jsonData = await exportPlainJson();

    final key = _getEncryptionKey();
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );

    final encrypted = encrypter.encrypt(jsonData, iv: iv);
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);

    // 外壳固定 version / app / format / data —— 除密文外不放任何条目信息。
    final data = {
      'version': formatVersion,
      'app': appName,
      'format': 'encrypted',
      'data': base64Encode(combined),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// 导出为 **Bitwarden 兼容的 JSON**（未加密），让用户可以随时切回去。
  ///
  /// 这是对用户的承诺：迁移成本不该是单向的。形状对齐 Bitwarden 的
  /// `{encrypted:false, folders:[], items:[]}`，`type` 用官方编号
  /// （1=登录 2=安全笔记 3=银行卡 4=身份）。
  ///
  /// **有损映射**（EasyPass 有、Bitwarden 没有对应的）：
  /// - SSH 密钥 → 降级为安全笔记，公钥/私钥/指纹/口令进自定义字段；
  /// - 身份里 Bitwarden 没有的字段 → 自定义字段；
  /// - 自定义字段的 `boolean` → `type: 2`（Bitwarden 的 boolean）；
  /// - 一个登录只有一条 URI → Bitwarden 的 `uris[0]`。
  ///
  /// 往返保真的部分：标题、备注、收藏、文件夹、登录四要素（URL/用户名/密码/
  /// TOTP）、自定义字段的标签与值。**密码与私钥是明文** —— 与
  /// [exportPlainJson] 同级，只写用户自己选定的文件。
  Future<String> exportBitwardenJson() async {
    // 未解锁时直接抛错，别导出一个空壳。
    _getEncryptionKey();

    final items = await _repository.getItems();
    final folders = await _repository.getFolders();

    final payload = <String, dynamic>{
      'encrypted': false,
      'folders': [
        for (final folder in folders) {'id': folder.id, 'name': folder.name},
      ],
      'items': [
        for (final item in items) _toBitwardenItem(item),
      ],
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 单个 [VaultItem] → Bitwarden 条目。
  ///
  /// 自定义字段统一放在 `fields` 上（Bitwarden 的登录/笔记/身份都支持它）。
  Map<String, dynamic> _toBitwardenItem(VaultItem item) {
    final fields = <Map<String, dynamic>>[
      for (final field in item.effectiveCustomFields)
        {
          'name': field.label,
          'value': field.value,
          // 0=text 1=hidden 2=boolean
          'type': switch (field.type) {
            CustomFieldType.hidden => 1,
            CustomFieldType.boolean => 2,
            CustomFieldType.text => 0,
          },
        },
    ];

    final common = <String, dynamic>{
      'id': item.id,
      'organizationId': null,
      'folderId': item.folderId,
      'type': _bitwardenType(item.type),
      'name': item.name,
      'notes': item.notes,
      'favorite': item.isFavorite,
      'reprompt': 0,
      'fields': fields.isEmpty ? null : fields,
    };

    switch (item.type) {
      case EntryType.login:
        final login = item.loginOrEmpty;
        common['login'] = {
          'uris': login.url.trim().isEmpty
              ? null
              : [
                  {'match': null, 'uri': login.url},
                ],
          'username': login.username,
          'password': login.password,
          'totp': login.totpSecret.isEmpty ? null : login.totpSecret,
        };
      case EntryType.secureNote:
        common['secureNote'] = {'type': 0};
      case EntryType.identity:
        final id = item.identityOrEmpty;
        common['identity'] = {
          'title': _nullIfEmpty(id.title),
          'firstName': _nullIfEmpty(id.firstName),
          'middleName': _nullIfEmpty(id.middleName),
          'lastName': _nullIfEmpty(id.lastName),
          'username': _nullIfEmpty(id.username),
          'company': _nullIfEmpty(id.company),
          'email': _nullIfEmpty(id.email),
          'phone': _nullIfEmpty(id.phone),
          'ssn': _nullIfEmpty(id.idNumber),
          'passportNumber': _nullIfEmpty(id.passportNumber),
          'licenseNumber': _nullIfEmpty(id.licenseNumber),
          'address1': _nullIfEmpty(id.address1),
          'address2': _nullIfEmpty(id.address2),
          'city': _nullIfEmpty(id.city),
          'state': _nullIfEmpty(id.state),
          'postalCode': _nullIfEmpty(id.postalCode),
          'country': _nullIfEmpty(id.country),
          'birthDate': _nullIfEmpty(id.birthday),
          'sex': _nullIfEmpty(id.sex),
        };
      case EntryType.sshKey:
        // Bitwarden 没有 SSH 类型：降级为安全笔记，密钥材料进自定义字段，
        // 并在备注里写明来源，避免用户以为数据丢了。
        final ssh = item.sshKeyOrEmpty;
        common['type'] = 2; // secureNote
        common['secureNote'] = {'type': 0};
        common['notes'] = _appendNotice(
          item.notes,
          '【此条目由 EasyPass 的 SSH 密钥导出】\n'
          'Bitwarden 没有 SSH 密钥类型，密钥材料已放入自定义字段。',
        );
        final sshFields = <Map<String, dynamic>>[
          if (ssh.publicKey.trim().isNotEmpty)
            {'name': 'SSH 公钥', 'value': ssh.publicKey, 'type': 0},
          if (ssh.privateKey.trim().isNotEmpty)
            {'name': 'SSH 私钥', 'value': ssh.privateKey, 'type': 1},
          if (ssh.passphrase.trim().isNotEmpty)
            {'name': 'SSH 私钥口令', 'value': ssh.passphrase, 'type': 1},
          if (ssh.fingerprint.trim().isNotEmpty)
            {'name': 'SSH 指纹', 'value': ssh.fingerprint, 'type': 0},
          if (ssh.keyType.trim().isNotEmpty)
            {'name': 'SSH 类型', 'value': ssh.keyType, 'type': 0},
          if (ssh.comment.trim().isNotEmpty)
            {'name': 'SSH 注释', 'value': ssh.comment, 'type': 0},
        ];
        common['fields'] = [...sshFields, ...fields].isEmpty
            ? null
            : [...sshFields, ...fields];
    }

    return common;
  }

  /// EasyPass 类型 → Bitwarden 的 type 编号。
  ///
  /// SSH 在调用处被特判成 2（安全笔记），这里保持一份显式映射以便阅读。
  int _bitwardenType(EntryType type) {
    switch (type) {
      case EntryType.login:
        return 1;
      case EntryType.secureNote:
        return 2;
      case EntryType.sshKey:
        return 2;
      case EntryType.identity:
        return 4;
    }
  }

  static String? _nullIfEmpty(String value) =>
      value.trim().isEmpty ? null : value;

  static String _appendNotice(String notes, String notice) =>
      notes.trim().isEmpty ? notice : '$notes\n\n$notice';

  /// 导入明文导出或加密备份，返回 `{'folders': n, 'entries': m}`。
  ///
  /// 输入不合法（不是 JSON / 不是对象 / entries 不是数组 / 备份解不开）
  /// 一律抛 [ExportImportException]，且**在写库之前**抛出。
  ///
  /// Bitwarden 的导出走 [importBitwardenJson] / [importBitwardenCsv]；这里刻意
  /// 不自动嗅探 Bitwarden JSON —— 两条路径的**冲突处理语义不同**（EasyPass 导入
  /// 沿用原 id = 覆盖，Bitwarden 导入一律新建 id = 追加），悄悄选错会吃掉数据。
  Future<Map<String, int>> importFromJson(String jsonContent) async {
    final data = _decodeDocument(jsonContent);

    if (data['format'] == 'encrypted') {
      return _importPlainJson(_decryptBackup(data));
    }

    return _importPlainJson(data);
  }

  /// 导入 Bitwarden / Vaultwarden 的**未加密** JSON 导出。
  ///
  /// 返回条数映射（键与 [importFromJson] 一致，便于设置页复用同一段提示），
  /// 跳过的条目通过 [BitwardenImporter] 的 [ImportReport] 另行取用。
  Future<ImportReport> importBitwardenJson(String content) {
    return BitwardenImporter(db: _db, repository: _repository)
        .importJson(content);
  }

  /// 导入 Bitwarden / Vaultwarden 的 CSV 导出。
  Future<ImportReport> importBitwardenCsv(String content) {
    return BitwardenImporter(db: _db, repository: _repository)
        .importCsv(content);
  }

  // ─── 导入：解析 ─────────────────────────────────────────

  Future<Map<String, int>> _importPlainJson(Map<String, dynamic> data) async {
    if (!data.containsKey('entries') && !data.containsKey('folders')) {
      throw const ExportImportException(
        'the file has no "entries" or "folders" — not an EasyPass export',
      );
    }

    // 阶段 1：全部解析 + 校验（含老格式密文的解密），不合法就在这里抛错。
    final folders = _parseFolders(data['folders']);
    final items = _parseEntries(data['entries']);

    // 阶段 2：写库。整体一个事务 + saveItem（用会话密钥重新加密）。
    var folderCount = 0;
    var entryCount = 0;
    await _db.transaction(() async {
      for (final folder in folders) {
        await _repository.addFolder(folder);
        folderCount++;
      }
      for (final item in items) {
        await _repository.saveItem(item);
        entryCount++;
      }
    });

    return {'folders': folderCount, 'entries': entryCount};
  }

  /// 解析 JSON 文本，失败时抛出可读错误。
  Map<String, dynamic> _decodeDocument(String content) {
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (e) {
      throw ExportImportException('the file is not valid JSON (${e.message})');
    }
    if (decoded is! Map) {
      throw const ExportImportException(
        'the file is not an EasyPass export (expected a JSON object)',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 解开 `format: 'encrypted'` 外壳，返回内层明文 JSON。
  Map<String, dynamic> _decryptBackup(Map<String, dynamic> shell) {
    final payload = shell['data'];
    if (payload is! String || payload.isEmpty) {
      throw const ExportImportException(
        'the encrypted backup has no "data" payload',
      );
    }

    final Uint8List raw;
    try {
      raw = base64Decode(payload);
    } on FormatException {
      throw const ExportImportException(
        'the encrypted backup is corrupted (invalid base64)',
      );
    }
    if (raw.length <= 16) {
      throw const ExportImportException(
        'the encrypted backup is corrupted (payload too short)',
      );
    }

    final key = _getEncryptionKey();
    final String decrypted;
    try {
      final encrypter = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
      );
      decrypted = encrypter.decrypt(
        encrypt.Encrypted(raw.sublist(16)),
        iv: encrypt.IV(raw.sublist(0, 16)),
      );
    } catch (_) {
      throw const ExportImportException(
        'cannot decrypt the backup — wrong master password or corrupted file',
      );
    }

    return _decodeDocument(decrypted);
  }

  List<FoldersCompanion> _parseFolders(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const ExportImportException('"folders" must be a list');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final result = <FoldersCompanion>[];
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      if (element is! Map) {
        throw ExportImportException('folders[$i] is not an object');
      }
      final map = Map<String, dynamic>.from(element);
      final name = _asString(map['name']);
      result.add(FoldersCompanion.insert(
        id: _asString(map['id']) ?? const Uuid().v4(),
        name: (name == null || name.isEmpty) ? _unnamedFolder : name,
        icon: map['icon'] == null
            ? const Value.absent()
            : Value(_asString(map['icon']) ?? ''),
        createdAt: decodeInt(map['created_at']) ?? now,
        updatedAt: decodeInt(map['updated_at']) ?? now,
      ));
    }
    return result;
  }

  List<VaultItem> _parseEntries(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List) {
      throw const ExportImportException('"entries" must be a list');
    }

    final result = <VaultItem>[];
    for (var i = 0; i < raw.length; i++) {
      final element = raw[i];
      if (element is! Map) {
        throw ExportImportException('entries[$i] is not an object');
      }
      result.add(_parseEntry(Map<String, dynamic>.from(element), i));
    }
    return result;
  }

  /// 单个条目 → [VaultItem]。
  ///
  /// 类型解析、字段块兼容、平铺的 1.x 登录字段全部交给
  /// [VaultItem.fromJson]（未知 type 回退登录），这里只补三件事：
  /// 老格式密文键的解密、缺 id、缺 name。
  VaultItem _parseEntry(Map<String, dynamic> raw, int index) {
    final map = <String, dynamic>{...raw};

    for (final pair in _legacyCipherKeys.entries) {
      final plainKey = pair.key;
      final legacyKey = pair.value;
      if (map.containsKey(plainKey) || !map.containsKey(legacyKey)) continue;

      final cipher = _asString(map[legacyKey]);
      if (cipher == null || cipher.isEmpty) {
        map[plainKey] = '';
        continue;
      }
      try {
        map[plainKey] = _cryptoService.decryptData(cipher, _getEncryptionKey());
      } catch (_) {
        final name = _asString(map['name']) ?? '';
        throw ExportImportException(
          'entries[$index] ("$name") carries an old encrypted field '
          '($legacyKey) that this vault key cannot decrypt',
        );
      }
    }

    var item = VaultItem.fromJson(map);
    if (item.id.isEmpty) item = item.copyWith(id: const Uuid().v4());
    if (item.name.trim().isEmpty) {
      item = item.copyWith(name: _unnamedEntry);
    }
    return item;
  }

  static String? _asString(Object? value) {
    if (value == null) return null;
    return value is String ? value : value.toString();
  }

  // ─── 文件读写 ───────────────────────────────────────────

  /// Write export to a file
  Future<File> writeToFile(String content, String filePath) async {
    final file = File(filePath);
    await file.writeAsString(content);
    return file;
  }

  /// Read import from a file
  Future<String> readFromFile(String filePath) async {
    final file = File(filePath);
    return await file.readAsString();
  }
}
