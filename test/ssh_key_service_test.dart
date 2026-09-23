import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/ssh_key_service.dart';

/// SSH 公钥解析 / 指纹计算 的契约测试。
///
/// 指纹的"定义"是：对 base64 解码后的密钥 blob 求 SHA-256，
/// 再以无填充 base64 输出、加 `SHA256:` 前缀（OpenSSH 现代格式）。
/// 这里既用独立的 [crypto] 计算做交叉验证，也断言输出格式。
void main() {
  /// 人造一个 OpenSSH 公钥 blob：string 字段序列。
  Uint8List blobOf(List<Uint8List> fields) {
    final out = BytesBuilder();
    for (final field in fields) {
      final length = ByteData(4)..setUint32(0, field.length);
      out.add(length.buffer.asUint8List());
      out.add(field);
    }
    return out.takeBytes();
  }

  Uint8List sshString(String value) => Uint8List.fromList(utf8.encode(value));

  /// mpint：最高位为 1 时补一个 0x00，避免被当成负数。
  Uint8List mpint(Uint8List raw) {
    if (raw.isNotEmpty && raw[0] & 0x80 != 0) {
      return Uint8List.fromList([0, ...raw]);
    }
    return raw;
  }

  Uint8List bytes(int length, {int seed = 7}) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = (seed * 31 + i * 17) & 0xff;
    }
    out[0] = 0x80; // 保证 mpint 走补零分支
    return out;
  }

  group('parsePublicKey', () {
    test('解析 ed25519 公钥：类型 / blob / 注释', () {
      final blob = blobOf([sshString('ssh-ed25519'), bytes(32)]);
      final line = 'ssh-ed25519 ${base64.encode(blob)} alice@laptop';

      final info = SshKeyService.parsePublicKey(line);
      expect(info, isNotNull);
      expect(info!.keyType, 'ssh-ed25519');
      expect(info.comment, 'alice@laptop');
      expect(info.blob, blob);
      expect(info.bits, 256);
    });

    test('没有注释也能解析（注释为空串）', () {
      final blob = blobOf([sshString('ssh-ed25519'), bytes(32)]);
      final info = SshKeyService.parsePublicKey('ssh-ed25519 ${base64.encode(blob)}');
      expect(info!.comment, '');
    });

    test('容忍 authorized_keys 行首选项与多行输入', () {
      final blob = blobOf([sshString('ssh-ed25519'), bytes(32)]);
      final line =
          'no-port-forwarding,command="/bin/true" ssh-ed25519 ${base64.encode(blob)} host';
      final info = SshKeyService.parsePublicKey('# 注释行\n$line\n');
      expect(info, isNotNull);
      expect(info!.keyType, 'ssh-ed25519');
      expect(info.comment, 'host');
    });

    test('RSA 公钥：从模数真实位长推 bits', () {
      final blob = blobOf([
        sshString('ssh-rsa'),
        mpint(Uint8List.fromList([0x01, 0x00, 0x01])), // e = 65537
        mpint(bytes(256)), // 2048-bit 模数
      ]);
      final info = SshKeyService.parsePublicKey('ssh-rsa ${base64.encode(blob)}');
      expect(info!.bits, 2048);
    });

    test('ECDSA 按曲线给位长', () {
      for (final entry in {
        'ecdsa-sha2-nistp256': 256,
        'ecdsa-sha2-nistp384': 384,
        'ecdsa-sha2-nistp521': 521,
      }.entries) {
        final blob = blobOf([sshString(entry.key), sshString('nistp256'), bytes(65)]);
        final info =
            SshKeyService.parsePublicKey('${entry.key} ${base64.encode(blob)}');
        expect(info!.bits, entry.value, reason: entry.key);
      }
    });

    test('拒绝私钥内容（不能把私钥当公钥解析）', () {
      const privateKey = '-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n'
          '-----END OPENSSH PRIVATE KEY-----';
      expect(SshKeyService.parsePublicKey(privateKey), isNull);
      expect(SshKeyService.looksLikePrivateKey(privateKey), isTrue);
    });

    test('坏输入返回 null：空串 / 垃圾 / 截断的 base64 / 未知类型', () {
      expect(SshKeyService.parsePublicKey(''), isNull);
      expect(SshKeyService.parsePublicKey('   '), isNull);
      expect(SshKeyService.parsePublicKey(null), isNull);
      expect(SshKeyService.parsePublicKey('not a key at all'), isNull);
      expect(SshKeyService.parsePublicKey('ssh-ed25519 !!!not-base64!!!'), isNull);
      expect(SshKeyService.parsePublicKey('ssh-ed25519'), isNull);
    });
  });

  group('指纹', () {
    test('SHA256 指纹 = blob 的 sha256 的无填充 base64', () {
      final blob = blobOf([
        sshString('ssh-ed25519'),
        Uint8List.fromList(List.generate(32, (i) => i)),
      ]);
      final expected = 'SHA256:${base64.encode(crypto.sha256.convert(blob).bytes).replaceAll('=', '')}';

      expect(SshKeyService.sha256Fingerprint(blob), expected);
      expect(SshKeyService.fingerprintOf('ssh-ed25519 ${base64.encode(blob)} x'),
          expected);
      // 43 个 base64 字符（32 字节摘要去掉填充）
      expect(expected.length, 'SHA256:'.length + 43);
      expect(expected.contains('='), isFalse);
    });

    test('MD5 指纹是冒号分隔的十六进制（老式格式）', () {
      final blob = Uint8List.fromList(List.generate(16, (i) => i * 3));
      final fingerprint = SshKeyService.md5Fingerprint(blob);
      expect(fingerprint.startsWith('MD5:'), isTrue);
      final hex = fingerprint.substring(4).split(':');
      expect(hex.length, 16);
      expect(hex.every((h) => h.length == 2), isTrue);

      final digest = crypto.md5.convert(blob).bytes;
      expect(
        fingerprint,
        'MD5:${digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':')}',
      );
    });

    test('解析不了公钥时指纹为空串（UI 显示为空，不瞎猜）', () {
      expect(SshKeyService.fingerprintOf('garbage'), '');
      expect(SshKeyService.fingerprintOf(null), '');
    });
  });

  group('私钥格式识别', () {
    test('识别常见格式名', () {
      expect(
        SshKeyService.privateKeyFormat('-----BEGIN OPENSSH PRIVATE KEY-----\nx'),
        'OpenSSH',
      );
      expect(
        SshKeyService.privateKeyFormat('-----BEGIN RSA PRIVATE KEY-----\nx'),
        'PEM RSA',
      );
      expect(
        SshKeyService.privateKeyFormat('PuTTY-User-Key-File-3: ssh-ed25519'),
        'PuTTY PPK',
      );
      expect(
        SshKeyService.privateKeyFormat('-----BEGIN ENCRYPTED PRIVATE KEY-----\nx'),
        'PKCS#8 (encrypted)',
      );
      expect(SshKeyService.privateKeyFormat('nothing'), '');
      expect(SshKeyService.privateKeyFormat(null), '');
    });
  });
}
