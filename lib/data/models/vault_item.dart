import 'entry_fields.dart';
import 'entry_type.dart';

/// 保险库条目（内存态明文领域模型）。
///
/// 2.3.0 起一个"条目"可以是登录 / 安全笔记 / 身份 / SSH 密钥四种类型之一。
/// [VaultItem] 是 UI、健康报告、导入导出与桥接协议共用的**唯一**模型；
/// 与 DB 行的互转集中在 `vault_item_mapper.dart`，不要在别处手写映射。
///
/// 安全纪律：
/// - 本对象持有**明文**（密码、TOTP 密钥、SSH 私钥、证件号），只允许存在于内存；
///   持久化必须走 mapper 的加密路径，禁止直接 jsonEncode 进数据库。
/// - `toJson()` 同样输出明文，只用于导出文件、剪贴板与桥接响应。
class VaultItem {
  final String id;

  /// 所属文件夹；null = 未归类。
  final String? folderId;

  final EntryType type;

  /// 条目标题（明文存列，用于列表与搜索）。
  final String name;

  /// 备注 / 安全笔记正文（加密存列）。
  final String notes;

  final bool isFavorite;

  /// 登录专属字段；仅当 [type] 为 [EntryType.login] 时非空。
  final LoginData? login;

  /// 身份专属字段；仅当 [type] 为 [EntryType.identity] 时非空。
  final IdentityData? identity;

  /// SSH 专属字段；仅当 [type] 为 [EntryType.sshKey] 时非空。
  final SshKeyData? sshKey;

  /// 自定义字段（所有类型都可加）。
  final List<CustomField> customFields;

  final int createdAt;
  final int updatedAt;

  const VaultItem({
    required this.id,
    this.folderId,
    required this.type,
    required this.name,
    this.notes = '',
    this.isFavorite = false,
    this.login,
    this.identity,
    this.sshKey,
    this.customFields = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isLogin => type == EntryType.login;

  /// 该条目是否参与浏览器表单自动填充（只有登录条目参与）。
  bool get isAutofillable => type.isAutofillable;

  /// 登录字段的安全访问器（非登录条目返回空值，UI 无需到处判空）。
  LoginData get loginOrEmpty => login ?? LoginData.empty;

  IdentityData get identityOrEmpty => identity ?? IdentityData.empty;

  SshKeyData get sshKeyOrEmpty => sshKey ?? SshKeyData.empty;

  /// 列表副标题用的"主要标识"：登录→用户名，身份→全名/证件号，SSH→指纹，笔记→正文摘要。
  String get subtitle {
    switch (type) {
      case EntryType.login:
        final data = loginOrEmpty;
        if (data.username.trim().isNotEmpty) return data.username;
        return data.url;
      case EntryType.identity:
        final data = identityOrEmpty;
        if (data.fullName.trim().isNotEmpty) return data.fullName;
        if (data.idNumber.trim().isNotEmpty) return data.idNumber;
        return data.email.isNotEmpty ? data.email : data.phone;
      case EntryType.sshKey:
        final data = sshKeyOrEmpty;
        if (data.fingerprint.trim().isNotEmpty) return data.fingerprint;
        return data.keyType;
      case EntryType.secureNote:
        final flat = notes.replaceAll(RegExp(r'\s+'), ' ').trim();
        return flat.length <= 60 ? flat : '${flat.substring(0, 60)}…';
    }
  }

  /// 搜索用的可匹配文本（大小写不敏感）。
  ///
  /// 刻意**不含**密码、TOTP 密钥、SSH 私钥与口令，也不含**隐藏型自定义字段的值**：
  /// 搜索框不该成为"输入片段就能确认密码"的旁路。但隐藏字段的**标签**会保留，
  /// 否则用户按自己起的字段名（如"恢复码"）根本搜不到这条。
  String get searchableText {
    final parts = <String>[
      name,
      notes,
      folderId ?? '',
      // 标签：全部字段都算
      customFields.map((f) => f.label).join(' '),
      // 值：隐藏型除外
      customFields
          .where((f) => f.type != CustomFieldType.hidden)
          .map((f) => f.value)
          .join(' '),
    ];

    switch (type) {
      case EntryType.login:
        final data = loginOrEmpty;
        parts.addAll([data.url, data.username]);
      case EntryType.identity:
        final data = identityOrEmpty;
        parts.addAll([
          data.title,
          data.fullName,
          data.username,
          data.company,
          data.email,
          data.phone,
          data.idNumber,
          data.passportNumber,
          data.licenseNumber,
          data.address1,
          data.address2,
          data.city,
          data.state,
          data.postalCode,
          data.country,
          data.birthday,
          data.sex,
        ]);
      case EntryType.sshKey:
        final data = sshKeyOrEmpty;
        parts.addAll([
          data.publicKey,
          data.fingerprint,
          data.keyType,
          data.comment,
        ]);
      case EntryType.secureNote:
        break;
    }

    return parts.where((p) => p.trim().isNotEmpty).join('\n').toLowerCase();
  }

  VaultItem copyWith({
    String? id,
    Object? folderId = _unset,
    EntryType? type,
    String? name,
    String? notes,
    bool? isFavorite,
    LoginData? login,
    IdentityData? identity,
    SshKeyData? sshKey,
    List<CustomField>? customFields,
    int? createdAt,
    int? updatedAt,
  }) {
    return VaultItem(
      id: id ?? this.id,
      folderId:
          identical(folderId, _unset) ? this.folderId : folderId as String?,
      type: type ?? this.type,
      name: name ?? this.name,
      notes: notes ?? this.notes,
      isFavorite: isFavorite ?? this.isFavorite,
      login: login ?? this.login,
      identity: identity ?? this.identity,
      sshKey: sshKey ?? this.sshKey,
      customFields: customFields ?? this.customFields,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 清空所有类型专属字段（切换类型或改类型时使用）。
  VaultItem withoutTypeData() {
    return VaultItem(
      id: id,
      folderId: folderId,
      type: type,
      name: name,
      notes: notes,
      isFavorite: isFavorite,
      customFields: customFields,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// 明文 JSON（导出格式 2.0.0 / 桥接响应复用部分字段）。
  ///
  /// 只有当前类型对应的字段块会被写出，避免导出文件里出现"身份条目里
  /// 还挂着空 login 块"这类噪音。
  Map<String, dynamic> toJson() => {
        'id': id,
        'folder_id': folderId,
        'type': type.wireName,
        'name': name,
        'notes': notes,
        'is_favorite': isFavorite,
        'created_at': createdAt,
        'updated_at': updatedAt,
        if (type == EntryType.login) 'login': loginOrEmpty.toJson(),
        if (type == EntryType.identity && identity != null)
          'identity': identity!.toJson(),
        if (type == EntryType.sshKey && sshKey != null)
          'ssh_key': sshKey!.toJson(),
        if (effectiveCustomFields.isNotEmpty)
          'custom_fields':
              effectiveCustomFields.map((f) => f.toJson()).toList(growable: false),
      };

  /// 丢弃空行后的自定义字段（保存与导出前使用）。
  List<CustomField> get effectiveCustomFields =>
      customFields.where((f) => !f.isEmpty).toList(growable: false);

  /// 从明文 JSON 解析（导入 / 测试用），字段缺失或类型不对都不抛异常。
  factory VaultItem.fromJson(Map<String, dynamic> json) {
    final type = EntryType.fromWire(json['type']);

    final rawFields = json['custom_fields'];
    final fields = <CustomField>[];
    if (rawFields is List) {
      for (final item in rawFields) {
        if (item is Map) {
          fields.add(CustomField.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final rawLogin = json['login'];
    final rawIdentity = json['identity'];
    final rawSsh = json['ssh_key'];

    return VaultItem(
      id: decodeString(json['id']),
      folderId: json['folder_id'] == null ? null : decodeString(json['folder_id']),
      type: type,
      name: decodeString(json['name']),
      notes: decodeString(json['notes']),
      isFavorite: json['is_favorite'] == true,
      login: type == EntryType.login
          ? (rawLogin is Map
              ? LoginData.fromJson(Map<String, dynamic>.from(rawLogin))
              : LoginData(
                  // 兼容 1.x 导出：登录字段平铺在条目顶层。
                  url: decodeString(json['url']),
                  username: decodeString(json['username']),
                  password: decodeString(json['password']),
                  totpSecret: decodeString(json['totp_secret']),
                ))
          : null,
      identity: rawIdentity is Map
          ? IdentityData.fromJson(Map<String, dynamic>.from(rawIdentity))
          : (type == EntryType.identity ? IdentityData.empty : null),
      sshKey: rawSsh is Map
          ? SshKeyData.fromJson(Map<String, dynamic>.from(rawSsh))
          : (type == EntryType.sshKey ? SshKeyData.empty : null),
      customFields: fields,
      createdAt: decodeInt(json['created_at']) ??
          DateTime.now().millisecondsSinceEpoch,
      updatedAt: decodeInt(json['updated_at']) ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  String toString() =>
      'VaultItem($id, ${type.wireName}, $name, folder=$folderId, favorite=$isFavorite)';
}

/// `copyWith` 用的哨兵：区分"没传"与"显式传 null"。
const Object _unset = Object();
