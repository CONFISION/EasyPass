import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/protocol/secure_channel.dart';

import 'agent_access_policy.dart';

/// 一个智能体配对（= 一个被用户授权过的智能体实例）。
///
/// 安全纪律：
/// - **密钥永不明文落库**：只存 `keyHash`（SHA-256）；明文只在创建时于 UI 显示一次。
/// - **密钥不派生自主密码**：它由核心随机生成，与数据库密钥（PBKDF2(主密码)）无关。
///   泄露一把配对密钥只丢这一份配对权限，不能解密数据库、不能反推主密码。
/// - `nickname` 是**给日志看的名字**：审计只写昵称，不写密钥、不写真实客户端标识。
class AgentPairing {
  const AgentPairing({
    required this.id,
    required this.nickname,
    required this.mode,
    required this.keyHash,
    required this.createdAt,
    this.trusted = false,
    this.expiresAt,
    this.revokedAt,
    this.lastUsedAt,
    this.calls = 0,
    this.scopeFolders = const <String>[],
    this.scopeTypes = const <String>[],
  });

  final String id;
  final String nickname;
  final AgentMode mode;

  /// `SHA-256(密钥)` 的十六进制。
  final String keyHash;

  final int createdAt;

  /// 仅方式 2 使用：用户经二次校验主密码后置 true。
  final bool trusted;

  final int? expiresAt;
  final int? revokedAt;
  final int? lastUsedAt;
  final int calls;

  /// 可选范围收窄（空 = 不额外收窄）；与条目开关取 AND。
  final List<String> scopeFolders;
  final List<String> scopeTypes;

  bool get isRevoked => revokedAt != null;

  bool isExpiredAt(int now) => expiresAt != null && now > expiresAt!;

  AgentPairing copyWith({
    String? nickname,
    AgentMode? mode,
    bool? trusted,
    int? expiresAt,
    bool clearExpiresAt = false,
    int? revokedAt,
    int? lastUsedAt,
    int? calls,
    List<String>? scopeFolders,
    List<String>? scopeTypes,
  }) {
    return AgentPairing(
      id: id,
      nickname: nickname ?? this.nickname,
      mode: mode ?? this.mode,
      keyHash: keyHash,
      createdAt: createdAt,
      trusted: trusted ?? this.trusted,
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      revokedAt: revokedAt ?? this.revokedAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      calls: calls ?? this.calls,
      scopeFolders: scopeFolders ?? this.scopeFolders,
      scopeTypes: scopeTypes ?? this.scopeTypes,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'nickname': nickname,
        'mode': mode.name,
        'trusted': trusted,
        'keyHash': keyHash,
        'createdAt': createdAt,
        if (expiresAt != null) 'expiresAt': expiresAt,
        if (revokedAt != null) 'revokedAt': revokedAt,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
        'calls': calls,
        if (scopeFolders.isNotEmpty) 'scopeFolders': scopeFolders,
        if (scopeTypes.isNotEmpty) 'scopeTypes': scopeTypes,
      };

  /// 宽容解析：`id` / `keyHash` 缺失或解析不了时返回 null（当作坏记录跳过）。
  static AgentPairing? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final id = map['id'];
      final keyHash = map['keyHash'];
      if (id is! String || id.isEmpty || keyHash is! String || keyHash.isEmpty) {
        return null;
      }
      return AgentPairing(
        id: id,
        nickname: (map['nickname'] as String?) ?? '',
        mode: (map['mode'] as String?) == 'trusted'
            ? AgentMode.trusted
            : AgentMode.approval,
        keyHash: keyHash,
        createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
        trusted: map['trusted'] == true,
        expiresAt: (map['expiresAt'] as num?)?.toInt(),
        revokedAt: (map['revokedAt'] as num?)?.toInt(),
        lastUsedAt: (map['lastUsedAt'] as num?)?.toInt(),
        calls: (map['calls'] as num?)?.toInt() ?? 0,
        scopeFolders: _stringList(map['scopeFolders']),
        scopeTypes: _stringList(map['scopeTypes']),
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _stringList(Object? value) {
    if (value is! List) return const <String>[];
    return value.whereType<String>().toList(growable: false);
  }

  @override
  String toString() =>
      'AgentPairing($id, $nickname, ${mode.name}, trusted=$trusted, revoked=$isRevoked)';
}

/// 配对记录的存取（复用 `vault_meta` 的 `agent.pairing.` 前缀，**不新增表**）。
class AgentPairingStore {
  AgentPairingStore(this._db);

  final AppDatabase _db;

  static const String keyPrefix = 'agent.pairing.';

  static String _metaKey(String id) => '$keyPrefix$id';

  /// 生成一把 256-bit 随机密钥（32 字节 → 64 位十六进制）。
  ///
  /// 与核心自己的 `token` 同款做法：`Random.secure()`，**不派生自主密码**。
  static String generateKey() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// `SHA-256(密钥)` 十六进制。库里只存这个值。
  static String hashKey(String key) =>
      sha256.convert(utf8.encode(key)).toString();

  /// 常量时间比较（与协议 5 的证明校验同一套工具，不另写一份）。
  static bool keyMatchesHash(String key, String keyHash) {
    if (key.isEmpty || keyHash.isEmpty) return false;
    return SecureChannelCrypto.constantTimeEquals(
      utf8.encode(hashKey(key)),
      utf8.encode(keyHash),
    );
  }

  /// 列出全部配对（坏记录跳过，不让一条烂数据拖垮整张列表）。
  Future<List<AgentPairing>> list() async {
    final rows = await _db.getMetaByPrefix(keyPrefix);
    final out = <AgentPairing>[];
    for (final row in rows) {
      final pairing = AgentPairing.tryParse(row.metaValue);
      if (pairing != null) out.add(pairing);
    }
    return out;
  }

  Future<AgentPairing?> findById(String id) async {
    final raw = await _db.getMeta(_metaKey(id));
    return raw == null ? null : AgentPairing.tryParse(raw);
  }

  /// 按明文密钥找配对（先哈希再比，比对走常量时间）。
  Future<AgentPairing?> findByKey(String key) async {
    if (key.isEmpty) return null;
    final wanted = hashKey(key);
    for (final pairing in await list()) {
      if (SecureChannelCrypto.constantTimeEquals(
        utf8.encode(pairing.keyHash),
        utf8.encode(wanted),
      )) {
        return pairing;
      }
    }
    return null;
  }

  Future<void> save(AgentPairing pairing) =>
      _db.setMeta(_metaKey(pairing.id), jsonEncode(pairing.toJson()));

  /// 撤销：写 `revokedAt`，记录**不删除**（审计与昵称还要能对上）。
  Future<void> revoke(String id, {int? now}) async {
    final pairing = await findById(id);
    if (pairing == null) return;
    await save(pairing.copyWith(
      revokedAt: now ?? DateTime.now().millisecondsSinceEpoch,
    ));
  }

  /// 物理删除（仅在"重新配对换钥"这类场景使用）。
  Future<void> delete(String id) => _db.deleteMeta(_metaKey(id));

  /// 记一次使用：`lastUsedAt` + `calls`。
  Future<void> touch(String id, {int? now}) async {
    final pairing = await findById(id);
    if (pairing == null) return;
    await save(pairing.copyWith(
      lastUsedAt: now ?? DateTime.now().millisecondsSinceEpoch,
      calls: pairing.calls + 1,
    ));
  }
}
