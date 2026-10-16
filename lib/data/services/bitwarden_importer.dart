import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../database/database.dart';
import '../models/entry_fields.dart';
import '../models/entry_type.dart';
import '../models/vault_item.dart';
import '../repositories/vault_repository.dart';

/// 导入结果：允许部分失败，但**必须把失败如实报出来**。
///
/// 迁移场景里"静默少导入 30 条"比"导到一半报错"更糟 —— 用户会以为搬完了，
/// 然后把源数据删掉。所以这里既给成功计数，也给逐条原因。
class ImportReport {
  const ImportReport({
    this.entries = 0,
    this.folders = 0,
    this.skipped = const [],
    this.extraUris = 0,
    this.cardsAsNotes = 0,
  });

  /// 写入成功的条目数。
  final int entries;

  /// 新建的文件夹数（复用同名已有文件夹的不计）。
  final int folders;

  /// 跳过的条目，元素形如 `#3 "GitHub": 未知类型 9`。
  final List<String> skipped;

  /// 有多余 URI 被折叠成自定义字段的登录条目数。
  final int extraUris;

  /// 被降级成"安全笔记"的银行卡条目数（EasyPass 没有卡片类型）。
  final int cardsAsNotes;

  bool get hasSkipped => skipped.isNotEmpty;
}

/// 导入来源格式。
enum ImportFormat { easypass, bitwardenJson, bitwardenCsv }

/// Bitwarden / Vaultwarden 只读导入（v2.4）。
///
/// ## 支持范围
///
/// **JSON**：Bitwarden 网页版「工具 → 导出 → .json（未加密）」。
/// 顶层 `{encrypted, folders[], items[]}`；条目按 `type` 分派
/// （1=登录 2=安全笔记 3=银行卡 4=身份）。
///
/// **CSV**：同一界面的 .csv 导出。列名
/// `folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp`。
///
/// ## 刻意保留的取舍（导入不丢信息的优先级高于"完美映射"）
///
/// - **银行卡**（type 3）：EasyPass 没有卡片类型，降级为安全笔记，卡号/有效期/
///   安全码等放进自定义字段 —— 宁可放错类型，也不能让用户以为卡没了。
/// - **多条 URI**：EasyPass 的登录只有单个 `url`，取第一条，其余折叠成自定义
///   字段 `URL 2`、`URL 3`……
/// - **Bitwarden 独有字段**（linked 自定义字段、密码历史、身份里 EasyPass 没有的
///   项）：能塞进自定义字段的就塞，塞不了的追加到备注里，并注明来源。
/// - **字段类型**：`hidden` / `boolean` 原样保留（EasyPass 支持），
///   `linked` 降级为 `text`。
///
/// ## 幂等性
///
/// 每次导入都给条目**生成新的 UUID**（不沿用 Bitwarden 的 id），所以重复导入
/// 同一份文件会产生重复条目 —— 这是有意为之：不发明日志的"去重"更容易吃掉
/// 用户数据。文件夹按**名字**复用，不会重复创建。
class BitwardenImporter {
  // ignore_for_file: prefer_initializing_formals
  BitwardenImporter({
    required AppDatabase db,
    required VaultRepository repository,
  })  : _db = db,
        _repository = repository;

  final AppDatabase _db;
  final VaultRepository _repository;

  static const Uuid _uuid = Uuid();

  /// Bitwarden 条目类型编号。
  static const int _typeLogin = 1;
  static const int _typeSecureNote = 2;
  static const int _typeCard = 3;
  static const int _typeIdentity = 4;

  /// 判断一段文本是不是 Bitwarden 导出，返回它是 JSON 还是 CSV。
  ///
  /// 判定刻意保守：只认 Bitwarden 鲜明的标志（`encrypted`+`items` / `folders`
  /// 数组 / CSV 表头），拿不准就返回 null，交给调用方按"不是 Bitwarden 文件"处理。
  static ImportFormat? detectFormat(String content) {
    final trimmed = content.trimLeft();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('{')) {
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;
      // EasyPass 自己的导出带 app/format 字段，先让位给它。
      if (decoded['app'] == 'EasyPass' || decoded.containsKey('format')) {
        return null;
      }
      // Bitwarden 的 JSON 导出必然同时有 encrypted 与 items。
      final hasItems = decoded['items'] is List;
      if (hasItems && decoded.containsKey('encrypted')) {
        return ImportFormat.bitwardenJson;
      }
      if (hasItems && decoded['folders'] is List) {
        return ImportFormat.bitwardenJson;
      }
      return null;
    }

    // CSV：认表头里 Bitwarden 的特征列。
    final firstLine = trimmed.split(RegExp(r'\r?\n')).first.toLowerCase();
    if (firstLine.contains('login_uri') &&
        firstLine.contains('login_username') &&
        firstLine.contains('login_password')) {
      return ImportFormat.bitwardenCsv;
    }
    return null;
  }

  /// 导入 Bitwarden 的 JSON 导出。
  Future<ImportReport> importJson(String content) async {
    final dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (e) {
      throw ImportException('文件不是合法 JSON（${e.message}）');
    }
    if (decoded is! Map) {
      throw const ImportException('文件不是 Bitwarden 导出（顶层不是对象）');
    }
    final root = Map<String, dynamic>.from(decoded);

    if (root['encrypted'] == true) {
      throw const ImportException(
        '这是 Bitwarden 的**加密**导出，EasyPass 无法解开。'
        '请在 Bitwarden 里重新导出并选择「.json」（未加密）。',
      );
    }

    final rawItems = root['items'];
    if (rawItems is! List) {
      throw const ImportException('文件里没有 items 数组，不像是 Bitwarden 导出');
    }

    // ── 阶段 1：全部解析，不碰数据库 ──────────────────────
    final folderNames = _parseFolderNames(root['folders']);
    final drafts = <_Draft>[];
    final skipped = <String>[];

    for (var i = 0; i < rawItems.length; i++) {
      final element = rawItems[i];
      if (element is! Map) {
        skipped.add('#${i + 1}: 不是对象');
        continue;
      }
      final map = Map<String, dynamic>.from(element);
      final label = _asString(map['name']);
      try {
        final draft = _parseItem(map, folderNames);
        if (draft == null) {
          final type = map['type'];
          skipped.add('#${i + 1} "$label": 未知类型 ${type ?? '(缺失)'}');
          continue;
        }
        drafts.add(draft);
      } catch (e) {
        skipped.add('#${i + 1} "$label": $e');
      }
    }

    // ── 阶段 2：写库（整体一个事务）──────────────────────
    return _writeDrafts(drafts, skipped);
  }

  /// 导入 Bitwarden 的 CSV 导出。
  Future<ImportReport> importCsv(String content) async {
    final rows = parseCsv(content);
    if (rows.isEmpty) throw const ImportException('CSV 是空的');

    final header = rows.first
        .map((h) => h.trim().toLowerCase())
        .toList(growable: false);
    int? col(String name) {
      final index = header.indexOf(name);
      return index < 0 ? null : index;
    }

    final folderCol = col('folder');
    final favoriteCol = col('favorite');
    final typeCol = col('type');
    final nameCol = col('name');
    final notesCol = col('notes');
    final fieldsCol = col('fields');
    final uriCol = col('login_uri');
    final usernameCol = col('login_username');
    final passwordCol = col('login_password');
    final totpCol = col('login_totp');

    if (typeCol == null || nameCol == null) {
      throw const ImportException(
        'CSV 缺少 type / name 列 —— 请确认导出时选的不是其他密码管理器的格式',
      );
    }

    String cell(List<String> row, int? index) {
      if (index == null || index >= row.length) return '';
      return row[index];
    }

    final drafts = <_Draft>[];
    final skipped = <String>[];

    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      // 跳过"没有内容"的行：Excel / 表格工具常在尾部留 `,,,` 这种空行，
      // 或者只留一个空格。判据是**关键列是否全空**，而不是"每个单元格都空"
      // —— 后者会把 `,,, ,,,` 这种只填了空格的尾巴当成一条条目。
      if (row.every((c) => c.trim().isEmpty)) continue;

      final rawName = cell(row, nameCol).trim();
      final rawType = cell(row, typeCol).trim();

      // 类型与名字都空 → 视为空行，不报"未知类型"噪音。
      if (rawType.isEmpty && rawName.isEmpty) continue;

      final label = rawName.isEmpty ? '(未命名)' : rawName;
      final folder = cell(row, folderCol).trim();

      try {
        final customFields = _parseCsvFields(cell(row, fieldsCol));
        final notes = cell(row, notesCol);
        final favorite = _csvBool(cell(row, favoriteCol));
        final typeKey = rawType.toLowerCase();

        switch (typeKey) {
          case 'login':
            drafts.add(_Draft(
              item: VaultItem(
                id: _uuid.v4(),
                type: EntryType.login,
                name: label,
                notes: notes,
                isFavorite: favorite,
                login: LoginData(
                  url: cell(row, uriCol),
                  username: cell(row, usernameCol),
                  password: cell(row, passwordCol),
                  totpSecret: cell(row, totpCol),
                ),
                customFields: customFields,
                createdAt: _now,
                updatedAt: _now,
              ),
              extraUris: 0,
              cardAsNote: false,
              folderName: folder,
            ));
          case 'note':
          case 'securenote':
          case 'secure_note':
            drafts.add(_Draft(
              item: VaultItem(
                id: _uuid.v4(),
                type: EntryType.secureNote,
                name: label,
                notes: notes,
                isFavorite: favorite,
                customFields: customFields,
                createdAt: _now,
                updatedAt: _now,
              ),
              extraUris: 0,
              cardAsNote: false,
              folderName: folder,
            ));
          case 'card':
            // EasyPass 没有卡片类型 —— 降级为安全笔记并在备注里写明来源，
            // 绝不让用户的银行卡信息"导入后被静默丢掉"。
            drafts.add(_Draft(
              item: VaultItem(
                id: _uuid.v4(),
                type: EntryType.secureNote,
                name: label,
                notes: _cardNote(notes),
                isFavorite: favorite,
                customFields: customFields,
                createdAt: _now,
                updatedAt: _now,
              ),
              extraUris: 0,
              cardAsNote: true,
              folderName: folder,
            ));
          case 'identity':
            drafts.add(_Draft(
              item: VaultItem(
                id: _uuid.v4(),
                type: EntryType.identity,
                name: label,
                notes: notes,
                isFavorite: favorite,
                identity: IdentityData.empty,
                customFields: customFields,
                createdAt: _now,
                updatedAt: _now,
              ),
              extraUris: 0,
              cardAsNote: false,
              folderName: folder,
            ));
          default:
            skipped.add('#${i + 1} "$label": 未知类型 "$rawType"');
            continue;
        }
      } catch (e) {
        skipped.add('#${i + 1} "$label": $e');
      }
    }

    return _writeDrafts(drafts, skipped);
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  // ─── JSON 解析 ──────────────────────────────────────────

  /// `folders[]` → `{id: name}`。
  Map<String, String> _parseFolderNames(Object? raw) {
    final result = <String, String>{};
    if (raw is! List) return result;
    for (final element in raw) {
      if (element is! Map) continue;
      final map = Map<String, dynamic>.from(element);
      final id = _asString(map['id']);
      final name = _asString(map['name']);
      if (id.isEmpty || name.isEmpty) continue;
      result[id] = name;
    }
    return result;
  }

  /// 单个 Bitwarden 条目 → [_Draft]；类型不认识时返回 null。
  _Draft? _parseItem(Map<String, dynamic> raw, Map<String, String> folderNames) {
    final type = _asInt(raw['type']);
    final name = _asString(raw['name']);
    final label = name.trim().isEmpty ? '(未命名)' : name;
    final notes = _asString(raw['notes']);
    final favorite = raw['favorite'] == true;
    final folderName = folderNames[_asString(raw['folderId'])] ?? '';

    final customFields = <CustomField>[];

    switch (type) {
      case _typeLogin:
        final rawLogin = raw['login'];
        final login = rawLogin is Map
            ? Map<String, dynamic>.from(rawLogin)
            : const <String, dynamic>{};

        // 多条 URI：第一条进 url，其余折叠成自定义字段，不丢。
        final uris = <String>[];
        final rawUris = login['uris'];
        if (rawUris is List) {
          for (final u in rawUris) {
            if (u is Map) {
              final uri = _asString(u['uri']);
              if (uri.isNotEmpty) uris.add(uri);
            }
          }
        }
        // 兼容老导出：`uri` 直接挂在 login 上。
        final legacyUri = _asString(login['uri']);
        if (uris.isEmpty && legacyUri.isNotEmpty) uris.add(legacyUri);

        var extraUris = 0;
        for (var i = 1; i < uris.length; i++) {
          customFields.add(CustomField(label: 'URL ${i + 1}', value: uris[i]));
          extraUris++;
        }

        customFields.addAll(_parseCustomFields(raw['fields']));
        final historyNote = _passwordHistoryNote(login['passwordHistory']);

        return _Draft(
          item: VaultItem(
            id: _uuid.v4(),
            type: EntryType.login,
            name: label,
            notes: _joinNotes(notes, historyNote),
            isFavorite: favorite,
            login: LoginData(
              url: uris.isEmpty ? '' : uris.first,
              username: _asString(login['username']),
              password: _asString(login['password']),
              totpSecret: _asString(login['totp']),
            ),
            customFields: customFields,
            createdAt: _now,
            updatedAt: _now,
          ),
          extraUris: extraUris,
          cardAsNote: false,
          folderName: folderName,
        );

      case _typeSecureNote:
        customFields.addAll(_parseCustomFields(raw['fields']));
        return _Draft(
          item: VaultItem(
            id: _uuid.v4(),
            type: EntryType.secureNote,
            name: label,
            notes: notes,
            isFavorite: favorite,
            customFields: customFields,
            createdAt: _now,
            updatedAt: _now,
          ),
          extraUris: 0,
          cardAsNote: false,
          folderName: folderName,
        );

      case _typeCard:
        // 没有卡片类型：降级成安全笔记，卡面信息进自定义字段。
        final rawCard = raw['card'];
        final card = rawCard is Map
            ? Map<String, dynamic>.from(rawCard)
            : const <String, dynamic>{};

        const cardLabels = <String, String>{
          'cardholderName': '持卡人',
          'brand': '卡组织',
          'number': '卡号',
          'expMonth': '有效期（月）',
          'expYear': '有效期（年）',
          'code': '安全码',
        };
        cardLabels.forEach((key, cardLabel) {
          final value = _asString(card[key]);
          if (value.isNotEmpty) {
            customFields.add(CustomField(
              label: cardLabel,
              value: value,
              // 卡号与安全码按隐藏字段存，列表里不直接显示。
              type: (key == 'number' || key == 'code')
                  ? CustomFieldType.hidden
                  : CustomFieldType.text,
            ));
          }
        });
        customFields.addAll(_parseCustomFields(raw['fields']));

        return _Draft(
          item: VaultItem(
            id: _uuid.v4(),
            type: EntryType.secureNote,
            name: label,
            notes: _cardNote(notes),
            isFavorite: favorite,
            customFields: customFields,
            createdAt: _now,
            updatedAt: _now,
          ),
          extraUris: 0,
          cardAsNote: true,
          folderName: folderName,
        );

      case _typeIdentity:
        final rawIdentity = raw['identity'];
        final identity = rawIdentity is Map
            ? Map<String, dynamic>.from(rawIdentity)
            : const <String, dynamic>{};

        // EasyPass 的身份字段是 Bitwarden 的子集：没有的多余项进自定义字段。
        const mapped = <String>{
          'title',
          'firstName',
          'middleName',
          'lastName',
          'username',
          'company',
          'email',
          'phone',
          'ssn',
          'passportNumber',
          'licenseNumber',
          'address1',
          'address2',
          'city',
          'state',
          'postalCode',
          'country',
          'birthDate',
          'sex',
        };
        identity.forEach((key, value) {
          final text = _asString(value);
          if (text.isEmpty || mapped.contains(key)) return;
          customFields.add(CustomField(label: '身份.$key', value: text));
        });
        customFields.addAll(_parseCustomFields(raw['fields']));

        return _Draft(
          item: VaultItem(
            id: _uuid.v4(),
            type: EntryType.identity,
            name: label,
            notes: notes,
            isFavorite: favorite,
            identity: IdentityData(
              title: _asString(identity['title']),
              firstName: _asString(identity['firstName']),
              middleName: _asString(identity['middleName']),
              lastName: _asString(identity['lastName']),
              username: _asString(identity['username']),
              company: _asString(identity['company']),
              email: _asString(identity['email']),
              phone: _asString(identity['phone']),
              idNumber: _asString(identity['ssn']),
              passportNumber: _asString(identity['passportNumber']),
              licenseNumber: _asString(identity['licenseNumber']),
              address1: _asString(identity['address1']),
              address2: _asString(identity['address2']),
              city: _asString(identity['city']),
              state: _asString(identity['state']),
              postalCode: _asString(identity['postalCode']),
              country: _asString(identity['country']),
              birthday: _asString(identity['birthDate']),
              sex: _asString(identity['sex']),
            ),
            customFields: customFields,
            createdAt: _now,
            updatedAt: _now,
          ),
          extraUris: 0,
          cardAsNote: false,
          folderName: folderName,
        );

      default:
        return null;
    }
  }

  /// Bitwarden `fields[]` → [CustomField]。
  ///
  /// `type`: 0=text 1=hidden 2=boolean 3=linked（EasyPass 没有 linked，降级 text）。
  List<CustomField> _parseCustomFields(Object? raw) {
    if (raw is! List) return const [];
    final result = <CustomField>[];
    for (final element in raw) {
      if (element is! Map) continue;
      final map = Map<String, dynamic>.from(element);
      final label = _asString(map['name']);
      if (label.trim().isEmpty) continue;
      final type = _asInt(map['type']);
      final value = _asString(map['value']);
      result.add(CustomField(
        label: label,
        value: value,
        type: switch (type) {
          1 => CustomFieldType.hidden,
          2 => CustomFieldType.boolean,
          _ => CustomFieldType.text,
        },
      ));
    }
    return result;
  }

  /// 密码历史 → 追加到备注的文本块（EasyPass 没有密码历史功能）。
  String _passwordHistoryNote(Object? raw) {
    if (raw is! List || raw.isEmpty) return '';
    final lines = <String>[];
    for (final element in raw) {
      if (element is! Map) continue;
      final map = Map<String, dynamic>.from(element);
      final password = _asString(map['password']);
      if (password.isEmpty) continue;
      final stamp = _asString(map['lastUsedDate']);
      lines.add(stamp.isEmpty ? '• $password' : '• $stamp  $password');
    }
    if (lines.isEmpty) return '';
    return '【导入自 Bitwarden 的密码历史】\n${lines.join('\n')}';
  }

  String _cardNote(String notes) => _joinNotes(
        notes,
        '【此条目由 Bitwarden 的「银行卡」导入】\n'
        'EasyPass 目前没有银行卡类型，卡面信息已保存为自定义字段。',
      );

  String _joinNotes(String a, String b) {
    if (a.trim().isEmpty) return b;
    if (b.trim().isEmpty) return a;
    return '$a\n\n$b';
  }

  // ─── CSV 解析 ───────────────────────────────────────────

  /// Bitwarden CSV 的 `fields` 列 → [CustomField]。
  ///
  /// 约定：一行一个字段，形如 `标签: 值`；布尔字段导出成
  /// `标签: true` / `标签: false`；多行值用 `\n` 转义。
  List<CustomField> _parseCsvFields(String cell) {
    if (cell.trim().isEmpty) return const [];
    final result = <CustomField>[];
    for (final rawLine in cell.split(RegExp(r'\\n|\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        result.add(CustomField(label: line, value: ''));
        continue;
      }
      final label = line.substring(0, colon).trim();
      final value = line.substring(colon + 1).trim();
      if (label.isEmpty) continue;
      final lower = value.toLowerCase();
      result.add(CustomField(
        label: label,
        value: value,
        type: (lower == 'true' || lower == 'false')
            ? CustomFieldType.boolean
            : CustomFieldType.text,
      ));
    }
    return result;
  }

  bool _csvBool(String value) {
    final v = value.trim().toLowerCase();
    return v == 'true' || v == '1' || v == 'y' || v == 'yes';
  }

  /// RFC 4180 风格 CSV 解析：支持引号包裹、引号内换行与 `""` 转义。
  ///
  /// 刻意不用第三方包：导入是安全敏感路径，解析行为要能被单测完全覆盖。
  static List<List<String>> parseCsv(String content) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var started = false;

    // 去掉 UTF-8 BOM（Excel / PowerShell 导出常带）。
    var text = content;
    if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }

    void endField() {
      row.add(field.toString());
      field.clear();
      started = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final ch = text[i];

      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
        continue;
      }

      switch (ch) {
        case '"':
          inQuotes = true;
          started = true;
        case ',':
          endField();
        case '\r':
          // 吞掉 \r\n 里的 \r；单独的 \r 也算换行。
          if (i + 1 < text.length && text[i + 1] == '\n') {
            continue;
          }
          endRow();
        case '\n':
          endRow();
        default:
          field.write(ch);
          started = true;
      }
    }

    // 结尾没有换行时补最后一行。
    if (started || field.isNotEmpty || row.isNotEmpty) {
      endRow();
    }
    return rows;
  }

  // ─── 写库 ───────────────────────────────────────────────

  Future<ImportReport> _writeDrafts(
    List<_Draft> drafts,
    List<String> skipped,
  ) async {
    final existingFolders = await _db.getAllFolders();
    final byName = <String, String>{
      for (final f in existingFolders) f.name: f.id,
    };

    var folderCount = 0;
    var entryCount = 0;
    var extraUris = 0;
    var cardsAsNotes = 0;

    await _db.transaction(() async {
      final now = DateTime.now().millisecondsSinceEpoch;

      for (final draft in drafts) {
        var item = draft.item;

        final wanted = draft.folderName.trim();
        if (wanted.isNotEmpty) {
          var folderId = byName[wanted];
          if (folderId == null) {
            folderId = _uuid.v4();
            await _repository.addFolder(FoldersCompanion.insert(
              id: folderId,
              name: wanted,
              createdAt: now,
              updatedAt: now,
            ));
            byName[wanted] = folderId;
            folderCount++;
          }
          item = item.copyWith(folderId: folderId);
        }

        await _repository.saveItem(item);
        entryCount++;
        extraUris += draft.extraUris;
        if (draft.cardAsNote) cardsAsNotes++;
      }
    });

    return ImportReport(
      entries: entryCount,
      folders: folderCount,
      skipped: skipped,
      extraUris: extraUris,
      cardsAsNotes: cardsAsNotes,
    );
  }

  // ─── 工具 ───────────────────────────────────────────────

  static String _asString(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    return value.toString();
  }

  static int? _asInt(Object? value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

/// 导入过程中的可读错误（UI 直接把 message 展示给用户）。
class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析结果中间态：条目 + 需要统计的附带信息。
class _Draft {
  _Draft({
    required this.item,
    required this.extraUris,
    required this.cardAsNote,
    this.folderName = '',
  });

  final VaultItem item;
  final int extraUris;
  final bool cardAsNote;
  String folderName;
}
