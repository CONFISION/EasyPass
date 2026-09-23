import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// SSH 公钥解析结果（纯数据）。
class SshPublicKeyInfo {
  /// 例如 `ssh-ed25519` / `ssh-rsa` / `ecdsa-sha2-nistp256`。
  final String keyType;

  /// 解码后的二进制 blob（指纹就是它的 SHA-256）。
  final Uint8List blob;

  /// 公钥行尾部的注释（通常是 `user@host`），可能为空。
  final String comment;

  /// RSA 模长 / ECDSA 曲线位数 / Ed25519 固定 256；无法判定时为 null。
  final int? bits;

  const SshPublicKeyInfo({
    required this.keyType,
    required this.blob,
    required this.comment,
    required this.bits,
  });

  /// `SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU`（无 `=` 填充）。
  String get fingerprintSha256 => SshKeyService.sha256Fingerprint(blob);

  /// 老式 `MD5:aa:bb:...`（部分旧系统仍在显示）。
  String get fingerprintMd5 => SshKeyService.md5Fingerprint(blob);
}

/// SSH 密钥的纯逻辑工具：解析公钥、算指纹、判断私钥格式。
///
/// 不依赖 Flutter / drift / 网络，全部是静态纯函数，便于单测。
/// 只做**格式解析与展示**，不做密码学运算（不算密钥强度、不生成密钥对）。
class SshKeyService {
  const SshKeyService._();

  /// 认得的公钥类型前缀（authorized_keys 里可能出现 `sk-` 系列安全密钥）。
  static const List<String> knownKeyTypes = [
    'ssh-ed25519',
    'ssh-rsa',
    'ssh-dss',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'sk-ssh-ed25519@openssh.com',
    'sk-ecdsa-sha2-nistp256@openssh.com',
  ];

  /// 解析一行 OpenSSH 公钥：`<type> <base64> [comment]`。
  ///
  /// 容错点（都来自真实粘贴场景）：
  /// - 允许 `authorized_keys` 的行首选项（`no-pty,command="..." ssh-rsa AAAA...`）；
  /// - 允许整行前后空白、多行（取第一行有效内容）；
  /// - base64 缺失或被截断 → 返回 null。
  ///
  /// 私钥内容（`-----BEGIN ... PRIVATE KEY-----`）**不是**公钥，返回 null，
  /// 避免用户把私钥粘进公钥框后拿到一个"看起来正常"的指纹。
  static SshPublicKeyInfo? parsePublicKey(String? input) {
    if (input == null) return null;
    final text = input.trim();
    if (text.isEmpty) return null;
    if (looksLikePrivateKey(text)) return null;

    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      // 逐 token 找"类型 + base64"这一对，跳过前面的 authorized_keys 选项。
      final tokens = line.split(RegExp(r'\s+'));
      for (var i = 0; i + 1 < tokens.length; i++) {
        final type = tokens[i];
        if (!knownKeyTypes.contains(type)) continue;

        final Uint8List blob;
        try {
          blob = base64.decode(base64.normalize(tokens[i + 1]));
        } on FormatException {
          continue; // base64 坏了：继续找下一对，别整行放弃
        }
        if (blob.isEmpty) continue;

        final comment = tokens.length > i + 2
            ? tokens.sublist(i + 2).join(' ').trim()
            : '';

        return SshPublicKeyInfo(
          keyType: type,
          blob: blob,
          comment: comment,
          bits: bitsOf(type, blob),
        );
      }
    }
    return null;
  }

  /// 公钥指纹（OpenSSH 现代格式）：`SHA256:` + 无填充 base64。
  static String sha256Fingerprint(Uint8List blob) {
    final digest = crypto.sha256.convert(blob).bytes;
    return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
  }

  /// 公钥指纹（老式 MD5 格式）：`MD5:` + 冒号分隔的十六进制。
  static String md5Fingerprint(Uint8List blob) {
    final digest = crypto.md5.convert(blob).bytes;
    final hex = digest
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':');
    return 'MD5:$hex';
  }

  /// 直接对"公钥文本"取指纹；解析失败返回空串。
  static String fingerprintOf(String? publicKey) {
    final info = parsePublicKey(publicKey);
    return info == null ? '' : info.fingerprintSha256;
  }

  /// 由类型 + blob 推导密钥位数。
  ///
  /// - Ed25519 / Ed25519-sk：固定 256；
  /// - ECDSA：按曲线（nistp256/384/521）；
  /// - RSA：解析 blob 里第三个字段（模数 n）的真实位长；
  /// - 其余（含 ssh-dss）：null，表示"未知"，UI 显示为空而不是瞎猜。
  static int? bitsOf(String keyType, Uint8List blob) {
    if (keyType == 'ssh-ed25519' ||
        keyType == 'sk-ssh-ed25519@openssh.com') {
      return 256;
    }
    if (keyType.startsWith('ecdsa-sha2-')) {
      if (keyType.endsWith('nistp256')) return 256;
      if (keyType.endsWith('nistp384')) return 384;
      if (keyType.endsWith('nistp521')) return 521;
      return null;
    }
    if (keyType == 'ssh-rsa') {
      final modulus = _rsaModulus(blob);
      if (modulus == null) return null;
      var bits = modulus.length * 8;
      // 去掉最高位的符号/前导零：位长按最高有效位计算。
      final leading = modulus[0];
      if (leading == 0) {
        bits -= 8;
      } else {
        var mask = 0x80;
        var drop = 0;
        while (drop < 8 && (leading & mask) == 0) {
          drop++;
          mask >>= 1;
        }
        bits -= drop;
      }
      return bits > 0 ? bits : null;
    }
    return null;
  }

  /// 解析 SSH blob 里的 mpint 模数（RSA 公钥的第三个字段）。
  static Uint8List? _rsaModulus(Uint8List blob) {
    // 结构：string "ssh-rsa" | mpint e | mpint n
    var offset = 0;
    for (var field = 0; field < 3; field++) {
      if (offset + 4 > blob.length) return null;
      final length = (blob[offset] << 24) |
          (blob[offset + 1] << 16) |
          (blob[offset + 2] << 8) |
          blob[offset + 3];
      offset += 4;
      if (length < 0 || offset + length > blob.length) return null;
      if (field == 2) {
        return Uint8List.sublistView(blob, offset, offset + length);
      }
      offset += length;
    }
    return null;
  }

  /// 文本是否像私钥（PEM / OpenSSH / PuTTY）。
  static bool looksLikePrivateKey(String? input) {
    if (input == null) return false;
    final text = input.trim();
    if (text.isEmpty) return false;
    return text.contains('-----BEGIN') &&
        (text.contains('PRIVATE KEY') ||
            text.contains('PuTTY-User-Key-File'));
  }

  /// 私钥格式的人类可读名（用于 UI 展示"识别到的格式"）；未知返回空串。
  static String privateKeyFormat(String? input) {
    if (input == null) return '';
    final text = input.trim();
    if (text.contains('PuTTY-User-Key-File')) return 'PuTTY PPK';
    if (text.contains('BEGIN OPENSSH PRIVATE KEY')) return 'OpenSSH';
    if (text.contains('BEGIN RSA PRIVATE KEY')) return 'PEM RSA';
    if (text.contains('BEGIN EC PRIVATE KEY')) return 'PEM EC';
    if (text.contains('BEGIN DSA PRIVATE KEY')) return 'PEM DSA';
    if (text.contains('BEGIN PRIVATE KEY')) return 'PKCS#8';
    if (text.contains('BEGIN ENCRYPTED PRIVATE KEY')) return 'PKCS#8 (encrypted)';
    return '';
  }
}
