import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/ssh_key_service.dart';
import '../database/database.dart';
import 'entry_fields.dart';
import 'entry_type.dart';
import 'vault_item.dart';

/// 没有会话密钥却要读写密文字段时抛出（保险库已锁定）。
class VaultLockedException implements Exception {
  const VaultLockedException();

  @override
  String toString() => 'Vault is locked: no session key available';
}

/// 密文解不开（密钥不对或数据损坏）时抛出（仅严格模式）。
class VaultDecryptException implements Exception {
  final String field;

  const VaultDecryptException(this.field);

  @override
  String toString() => 'Failed to decrypt field: $field';
}

/// [VaultItem]（内存明文模型） ↔ `password_entries` 行 的唯一映射点。
///
/// 规则（2.3.0 冻结，`docs/entry-types.md` 有完整说明）：
/// - **登录字段走列**：url / username / password_encrypted /
///   totp_secret_encrypted —— 旧数据零迁移，自动填充与 LIKE 搜索不变；
/// - **其余类型字段 + 所有类型的自定义字段**序列化成 JSON，
///   整体加密进 `data_encrypted`；
/// - 空值一律存空串（不加密空字符串），避免密文里出现"加密过的空串"；
/// - **绝不**在加密失败时退化成写明文（旧 `_encryptField` 的隐患，勿重演）。
class VaultItemMapper {
  const VaultItemMapper(this._cryptoService);

  final CryptoService _cryptoService;

  // ─── 行 → 模型 ──────────────────────────────────────────

  /// 把 DB 行装配成 [VaultItem]。
  ///
  /// [key] 必须是会话密钥；[lenient] 为 true 时解密失败按空串处理
  /// （单条坏数据不会炸掉整个列表流），为 false 时抛
  /// [VaultDecryptException]（测试与导入校验用）。
  VaultItem fromRow(PasswordEntry row, Uint8List key, {bool lenient = true}) {
    final type = EntryType.fromWire(row.type);

    String open(String? cipher, String field) {
      if (cipher == null || cipher.isEmpty) return '';
      try {
        return _cryptoService.decryptData(cipher, key);
      } catch (e) {
        if (lenient) return '';
        throw VaultDecryptException(field);
      }
    }

    final payload = decodePayload(row.dataEncrypted, key, lenient: lenient);

    return VaultItem(
      id: row.id,
      folderId: row.folderId,
      type: type,
      name: row.name,
      notes: open(row.notesEncrypted, 'notes'),
      isFavorite: row.isFavorite,
      login: type == EntryType.login
          ? LoginData(
              url: row.url,
              username: row.username,
              password: open(row.passwordEncrypted, 'password'),
              totpSecret: open(row.totpSecretEncrypted, 'totp'),
            )
          : null,
      identity: type == EntryType.identity
          ? (payload.identity ?? IdentityData.empty)
          : null,
      sshKey: type == EntryType.sshKey
          ? (payload.sshKey ?? SshKeyData.empty)
          : null,
      customFields: payload.customFields,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  // ─── 模型 → 行 ──────────────────────────────────────────

  /// 新建条目用的 companion（`id` 与 NOT NULL 列都显式给出）。
  PasswordEntriesCompanion toInsert(VaultItem item, Uint8List key) {
    final row = _write(item, key);
    return PasswordEntriesCompanion.insert(
      id: row.id,
      name: row.name,
      passwordEncrypted: row.passwordEncrypted,
      folderId: Value(row.folderId),
      type: Value(row.type),
      url: Value(row.url),
      username: Value(row.username),
      notesEncrypted: Value(row.notesEncrypted),
      totpSecretEncrypted: Value(row.totpSecretEncrypted),
      dataEncrypted: Value(row.dataEncrypted),
      isFavorite: Value(row.isFavorite),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// 更新条目用的 companion（整行覆写，避免残留旧类型字段）。
  PasswordEntriesCompanion toUpdate(VaultItem item, Uint8List key) {
    final row = _write(item, key);
    return PasswordEntriesCompanion(
      folderId: Value(row.folderId),
      type: Value(row.type),
      name: Value(row.name),
      url: Value(row.url),
      username: Value(row.username),
      passwordEncrypted: Value(row.passwordEncrypted),
      notesEncrypted: Value(row.notesEncrypted),
      totpSecretEncrypted: Value(row.totpSecretEncrypted),
      dataEncrypted: Value(row.dataEncrypted),
      isFavorite: Value(row.isFavorite),
      createdAt: Value(row.createdAt),
      updatedAt: Value(row.updatedAt),
    );
  }

  /// 归一化 + 加密，得到行的"明文投影"（供 insert / update 复用）。
  _RowProjection _write(VaultItem item, Uint8List key) {
    final normalized = VaultItemMapper.normalize(item);

    final login = normalized.login;
    final blob = encodePayload(VaultItemMapper.payloadOf(normalized), key);

    return _RowProjection(
      id: normalized.id,
      folderId: normalized.folderId,
      type: normalized.type.wireName,
      name: normalized.name,
      url: normalized.type == EntryType.login ? (login?.url ?? '') : '',
      username:
          normalized.type == EntryType.login ? (login?.username ?? '') : '',
      passwordEncrypted: normalized.type == EntryType.login
          ? _seal(login?.password ?? '', key)
          : '',
      notesEncrypted: _seal(normalized.notes, key),
      totpSecretEncrypted: normalized.type == EntryType.login
          ? _seal(login?.totpSecret ?? '', key)
          : '',
      dataEncrypted: blob,
      isFavorite: normalized.isFavorite,
      createdAt: normalized.createdAt,
      updatedAt: normalized.updatedAt,
    );
  }

  /// 加密单个字段；空串保持空串（不产生"加密后的空串"这种垃圾密文）。
  String _seal(String plaintext, Uint8List key) {
    if (plaintext.isEmpty) return '';
    return _cryptoService.encryptData(plaintext, key);
  }

  // ─── data_encrypted 载荷 ────────────────────────────────

  /// 把载荷（身份 / SSH / 自定义字段）加密成 `data_encrypted` 的值。
  String encodePayload(EntryPayload payload, Uint8List key) {
    if (payload.isEmpty) return '';
    return _cryptoService.encryptData(jsonEncode(payload.toJson()), key);
  }

  /// 解开 `data_encrypted`；空串或解不开时返回 [EntryPayload.empty]（宽容）
  /// 或抛 [VaultDecryptException]（严格）。
  EntryPayload decodePayload(
    String? blob,
    Uint8List key, {
    bool lenient = true,
  }) {
    if (blob == null || blob.isEmpty) return EntryPayload.empty;
    try {
      final decoded = jsonDecode(_cryptoService.decryptData(blob, key));
      if (decoded is! Map) return EntryPayload.empty;
      return EntryPayload.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      if (lenient) return EntryPayload.empty;
      throw const VaultDecryptException('data_encrypted');
    }
  }

  /// 取出一个条目里"需要进 data_encrypted 的部分"。
  static EntryPayload payloadOf(VaultItem item) {
    return EntryPayload(
      customFields: item.effectiveCustomFields,
      identity: item.type == EntryType.identity ? item.identity : null,
      sshKey: item.type == EntryType.sshKey ? item.sshKey : null,
    );
  }

  // ─── 归一化 ─────────────────────────────────────────────

  /// 归一化条目：丢弃与类型不符的字段块、去掉空的类型块、
  /// 由公钥自动补全 SSH 的指纹 / 类型 / 位长 / 注释。
  ///
  /// 保存前与读取后都可调用；保证"一个登录条目里不会夹带身份块"这类脏数据。
  static VaultItem normalize(VaultItem item) {
    final fields = item.effectiveCustomFields;

    switch (item.type) {
      case EntryType.login:
        return VaultItem(
          id: item.id,
          folderId: item.folderId,
          type: item.type,
          name: item.name,
          notes: item.notes,
          isFavorite: item.isFavorite,
          login: item.login ?? LoginData.empty,
          customFields: fields,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        );

      case EntryType.secureNote:
        return VaultItem(
          id: item.id,
          folderId: item.folderId,
          type: item.type,
          name: item.name,
          notes: item.notes,
          isFavorite: item.isFavorite,
          customFields: fields,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        );

      case EntryType.identity:
        return VaultItem(
          id: item.id,
          folderId: item.folderId,
          type: item.type,
          name: item.name,
          notes: item.notes,
          isFavorite: item.isFavorite,
          identity: item.identityOrEmpty,
          customFields: fields,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        );

      case EntryType.sshKey:
        return VaultItem(
          id: item.id,
          folderId: item.folderId,
          type: item.type,
          name: item.name,
          notes: item.notes,
          isFavorite: item.isFavorite,
          sshKey: _withDerivedSshFields(item.sshKeyOrEmpty),
          customFields: fields,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
        );
    }
  }

  /// 公钥能解析时，把空缺的指纹 / 类型 / 位长 / 注释补上（用户填过的值不动）。
  static SshKeyData _withDerivedSshFields(SshKeyData data) {
    final info = SshKeyService.parsePublicKey(data.publicKey);
    if (info == null) return data;
    return data.copyWith(
      fingerprint: data.fingerprint.trim().isEmpty
          ? info.fingerprintSha256
          : data.fingerprint,
      keyType: data.keyType.trim().isEmpty ? info.keyType : data.keyType,
      bits: data.bits ?? info.bits,
      comment:
          data.comment.trim().isEmpty && info.comment.isNotEmpty
              ? info.comment
              : data.comment,
    );
  }
}

/// 明文形式的行投影（只在 mapper 内部使用）。
class _RowProjection {
  final String id;
  final String? folderId;
  final String type;
  final String name;
  final String url;
  final String username;
  final String passwordEncrypted;
  final String notesEncrypted;
  final String totpSecretEncrypted;
  final String dataEncrypted;
  final bool isFavorite;
  final int createdAt;
  final int updatedAt;

  const _RowProjection({
    required this.id,
    required this.folderId,
    required this.type,
    required this.name,
    required this.url,
    required this.username,
    required this.passwordEncrypted,
    required this.notesEncrypted,
    required this.totpSecretEncrypted,
    required this.dataEncrypted,
    required this.isFavorite,
    required this.createdAt,
    required this.updatedAt,
  });
}
