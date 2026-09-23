/// 条目各类型的字段容器（纯 Dart、可单测，不依赖 Flutter / drift / 加密库）。
///
/// 设计约定（2.3.0 冻结）：
/// - **登录字段仍由 `password_entries` 的列承载**（url / username /
///   password_encrypted / totp_secret_encrypted），保证旧数据零迁移、
///   自动填充与 LIKE 搜索行为不变；[LoginData] 只是它在内存里的投影。
/// - **其余类型 + 所有类型的自定义字段**统一装进 [EntryPayload]，
///   序列化成 JSON 后整体加密存进 `password_entries.data_encrypted`。
/// - 所有字段都是可空的字符串（除 `bits`），空串表示"未填写"，
///   不用 null 表达，避免导入/导出时出现两种"空"。
library;

/// 自定义字段类型（对标 Bitwarden 的 text / hidden / boolean）。
enum CustomFieldType {
  text('text'),
  hidden('hidden'),
  boolean('boolean');

  const CustomFieldType(this.wireName);

  final String wireName;

  static CustomFieldType fromWire(Object? value) {
    if (value is CustomFieldType) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'hidden':
        case 'password':
          return CustomFieldType.hidden;
        case 'boolean':
        case 'bool':
        case 'checkbox':
          return CustomFieldType.boolean;
      }
    }
    return CustomFieldType.text;
  }
}

/// 自定义字段：用户自己加的键值对（值同样加密存储）。
class CustomField {
  final String label;
  final String value;
  final CustomFieldType type;

  const CustomField({
    required this.label,
    this.value = '',
    this.type = CustomFieldType.text,
  });

  bool get isBoolean => type == CustomFieldType.boolean;

  /// 布尔字段把值存成 `'true'` / `'false'` 字符串，避免 JSON 里混类型。
  bool get booleanValue => value.trim().toLowerCase() == 'true';

  CustomField copyWith({String? label, String? value, CustomFieldType? type}) {
    return CustomField(
      label: label ?? this.label,
      value: value ?? this.value,
      type: type ?? this.type,
    );
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'value': value,
        'type': type.wireName,
      };

  factory CustomField.fromJson(Map<String, dynamic> json) {
    return CustomField(
      label: decodeString(json['label']),
      value: decodeString(json['value']),
      type: CustomFieldType.fromWire(json['type']),
    );
  }

  /// 空标签且空值视为"未填写的一行"，保存时丢弃。
  bool get isEmpty => label.trim().isEmpty && value.trim().isEmpty;

  @override
  String toString() => 'CustomField($label, ${type.wireName})';
}

/// 登录条目的专属字段（投影自 DB 列；密码与 TOTP 密钥在库里是密文）。
class LoginData {
  final String url;
  final String username;
  final String password;
  final String totpSecret;

  const LoginData({
    this.url = '',
    this.username = '',
    this.password = '',
    this.totpSecret = '',
  });

  static const LoginData empty = LoginData();

  bool get hasTotp => totpSecret.trim().isNotEmpty;

  LoginData copyWith({
    String? url,
    String? username,
    String? password,
    String? totpSecret,
  }) {
    return LoginData(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
      totpSecret: totpSecret ?? this.totpSecret,
    );
  }

  /// 注意：这里输出的是**明文**，只允许用于导出、桥接 JSON 与内存态。
  Map<String, dynamic> toJson() => {
        'url': url,
        'username': username,
        'password': password,
        'totp_secret': totpSecret,
      };

  factory LoginData.fromJson(Map<String, dynamic> json) {
    return LoginData(
      url: decodeString(json['url']),
      username: decodeString(json['username']),
      password: decodeString(json['password']),
      totpSecret: decodeString(json['totp_secret'] ?? json['totp']),
    );
  }
}

/// 身份信息字段（姓名 / 证件 / 联系方式 / 地址）。
///
/// 字段集合对标 Bitwarden identity，去掉地址第 3 行这类极少用的项。
class IdentityData {
  final String title; // 称谓：先生 / 女士 / Dr.
  final String firstName;
  final String middleName;
  final String lastName;
  final String username;
  final String company;
  final String email;
  final String phone;
  final String idNumber; // 身份证 / 社保号等国民证件号
  final String passportNumber;
  final String licenseNumber;
  final String address1;
  final String address2;
  final String city;
  final String state; // 省 / 州
  final String postalCode;
  final String country;
  final String birthday; // YYYY-MM-DD（自由文本，不做强校验）
  final String sex;

  const IdentityData({
    this.title = '',
    this.firstName = '',
    this.middleName = '',
    this.lastName = '',
    this.username = '',
    this.company = '',
    this.email = '',
    this.phone = '',
    this.idNumber = '',
    this.passportNumber = '',
    this.licenseNumber = '',
    this.address1 = '',
    this.address2 = '',
    this.city = '',
    this.state = '',
    this.postalCode = '',
    this.country = '',
    this.birthday = '',
    this.sex = '',
  });

  static const IdentityData empty = IdentityData();

  /// 全名（无空格拼接，UI 用于列表副标题与搜索）。
  String get fullName =>
      [firstName, middleName, lastName].where((s) => s.trim().isNotEmpty).join(' ');

  IdentityData copyWith({
    String? title,
    String? firstName,
    String? middleName,
    String? lastName,
    String? username,
    String? company,
    String? email,
    String? phone,
    String? idNumber,
    String? passportNumber,
    String? licenseNumber,
    String? address1,
    String? address2,
    String? city,
    String? state,
    String? postalCode,
    String? country,
    String? birthday,
    String? sex,
  }) {
    return IdentityData(
      title: title ?? this.title,
      firstName: firstName ?? this.firstName,
      middleName: middleName ?? this.middleName,
      lastName: lastName ?? this.lastName,
      username: username ?? this.username,
      company: company ?? this.company,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      idNumber: idNumber ?? this.idNumber,
      passportNumber: passportNumber ?? this.passportNumber,
      licenseNumber: licenseNumber ?? this.licenseNumber,
      address1: address1 ?? this.address1,
      address2: address2 ?? this.address2,
      city: city ?? this.city,
      state: state ?? this.state,
      postalCode: postalCode ?? this.postalCode,
      country: country ?? this.country,
      birthday: birthday ?? this.birthday,
      sex: sex ?? this.sex,
    );
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'first_name': firstName,
        'middle_name': middleName,
        'last_name': lastName,
        'username': username,
        'company': company,
        'email': email,
        'phone': phone,
        'id_number': idNumber,
        'passport_number': passportNumber,
        'license_number': licenseNumber,
        'address1': address1,
        'address2': address2,
        'city': city,
        'state': state,
        'postal_code': postalCode,
        'country': country,
        'birthday': birthday,
        'sex': sex,
      };

  factory IdentityData.fromJson(Map<String, dynamic> json) {
    return IdentityData(
      title: decodeString(json['title']),
      firstName: decodeString(json['first_name']),
      middleName: decodeString(json['middle_name']),
      lastName: decodeString(json['last_name']),
      username: decodeString(json['username']),
      company: decodeString(json['company']),
      email: decodeString(json['email']),
      phone: decodeString(json['phone']),
      idNumber: decodeString(json['id_number']),
      passportNumber: decodeString(json['passport_number']),
      licenseNumber: decodeString(json['license_number']),
      address1: decodeString(json['address1']),
      address2: decodeString(json['address2']),
      city: decodeString(json['city']),
      state: decodeString(json['state']),
      postalCode: decodeString(json['postal_code']),
      country: decodeString(json['country']),
      birthday: decodeString(json['birthday']),
      sex: decodeString(json['sex']),
    );
  }
}

/// SSH 密钥字段。
///
/// [fingerprint] / [keyType] / [bits] / [comment] 可以由
/// `SshKeyService.inspectPublicKey()` 从 [publicKey] 自动推导，
/// 但**允许用户手改**（有些密钥来自其他格式或需要固定展示值）。
class SshKeyData {
  final String publicKey; // OpenSSH 单行格式：ssh-ed25519 AAAA... comment
  final String privateKey; // OpenSSH/PEM 私钥全文（加密存储）
  final String passphrase; // 私钥口令（加密存储）
  final String fingerprint; // SHA256:xxxx（默认自动计算）
  final String keyType; // ssh-ed25519 / ssh-rsa / ecdsa-sha2-nistp256 ...
  final int? bits; // RSA 模长等；无法判定时为 null
  final String comment; // 公钥尾部的注释（通常是 user@host）

  const SshKeyData({
    this.publicKey = '',
    this.privateKey = '',
    this.passphrase = '',
    this.fingerprint = '',
    this.keyType = '',
    this.bits,
    this.comment = '',
  });

  static const SshKeyData empty = SshKeyData();

  bool get hasPrivateKey => privateKey.trim().isNotEmpty;

  SshKeyData copyWith({
    String? publicKey,
    String? privateKey,
    String? passphrase,
    String? fingerprint,
    String? keyType,
    int? bits,
    bool clearBits = false,
    String? comment,
  }) {
    return SshKeyData(
      publicKey: publicKey ?? this.publicKey,
      privateKey: privateKey ?? this.privateKey,
      passphrase: passphrase ?? this.passphrase,
      fingerprint: fingerprint ?? this.fingerprint,
      keyType: keyType ?? this.keyType,
      bits: clearBits ? null : (bits ?? this.bits),
      comment: comment ?? this.comment,
    );
  }

  /// 注意：这里输出的是**明文**（含私钥与口令），只允许用于导出与内存态。
  Map<String, dynamic> toJson() => {
        'public_key': publicKey,
        'private_key': privateKey,
        'passphrase': passphrase,
        'fingerprint': fingerprint,
        'key_type': keyType,
        'bits': bits,
        'comment': comment,
      };

  factory SshKeyData.fromJson(Map<String, dynamic> json) {
    return SshKeyData(
      publicKey: decodeString(json['public_key']),
      privateKey: decodeString(json['private_key']),
      passphrase: decodeString(json['passphrase']),
      fingerprint: decodeString(json['fingerprint']),
      keyType: decodeString(json['key_type']),
      bits: decodeInt(json['bits']),
      comment: decodeString(json['comment']),
    );
  }
}

/// 加密载荷：`password_entries.data_encrypted` 解密后的内容。
///
/// 只装"列里放不下"的东西：身份 / SSH 专属字段 + 所有类型的自定义字段。
/// 登录字段不进这里（避免同一份密文存两遍、两处真相打架）。
class EntryPayload {
  final List<CustomField> customFields;
  final IdentityData? identity;
  final SshKeyData? sshKey;

  /// 载荷格式版本，便于以后升级（当前 1）。
  static const int version = 1;

  const EntryPayload({
    this.customFields = const [],
    this.identity,
    this.sshKey,
  });

  static const EntryPayload empty = EntryPayload();

  /// 没有任何需要加密的内容 → 不写 `data_encrypted`（保持空串）。
  bool get isEmpty =>
      customFields.every((f) => f.isEmpty) && identity == null && sshKey == null;

  EntryPayload copyWith({
    List<CustomField>? customFields,
    IdentityData? identity,
    SshKeyData? sshKey,
    bool clearIdentity = false,
    bool clearSshKey = false,
  }) {
    return EntryPayload(
      customFields: customFields ?? this.customFields,
      identity: clearIdentity ? null : (identity ?? this.identity),
      sshKey: clearSshKey ? null : (sshKey ?? this.sshKey),
    );
  }

  /// 丢弃空行后的自定义字段（保存前调用）。
  List<CustomField> get effectiveCustomFields =>
      customFields.where((f) => !f.isEmpty).toList(growable: false);

  Map<String, dynamic> toJson() => {
        'v': version,
        if (effectiveCustomFields.isNotEmpty)
          'custom_fields':
              effectiveCustomFields.map((f) => f.toJson()).toList(growable: false),
        if (identity != null) 'identity': identity!.toJson(),
        if (sshKey != null) 'ssh_key': sshKey!.toJson(),
      };

  factory EntryPayload.fromJson(Map<String, dynamic>? json) {
    if (json == null) return EntryPayload.empty;

    final rawFields = json['custom_fields'];
    final fields = <CustomField>[];
    if (rawFields is List) {
      for (final item in rawFields) {
        if (item is Map) {
          fields.add(CustomField.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }

    final rawIdentity = json['identity'];
    final rawSsh = json['ssh_key'];

    return EntryPayload(
      customFields: fields,
      identity: rawIdentity is Map
          ? IdentityData.fromJson(Map<String, dynamic>.from(rawIdentity))
          : null,
      sshKey: rawSsh is Map
          ? SshKeyData.fromJson(Map<String, dynamic>.from(rawSsh))
          : null,
    );
  }
}

/// 宽容的字符串解码：null / 数字 / 布尔都能变成字符串，绝不抛异常。
String decodeString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return value.toString();
}

/// 宽容的整数解码：字符串（含 `2048` 这种）与 num 都接受，其余返回 null。
int? decodeInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
