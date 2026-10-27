import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easypass/core/platform/dpapi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Windows DPAPI 封装的最小验证。
///
/// 只验证"能不能正确加/解密、错的 entropy / 篡改的 blob 会不会被拒"。
/// **不验证**"别的用户解不开"（那需要对另一个 Windows 账户做真机测试，
/// 单测环境做不到），这一点写在 SECURITY.md 里，不在这里冒充已验证。
void main() {
  final onWindows = Platform.isWindows;
  final skipReason = onWindows ? null : 'DPAPI 仅 Windows 可用';

  Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

  final entropy = bytes('easypass-agent-key-v1');

  group('往返', () {
    test('protect → unprotect 能还原原文', () {
      final data = bytes('agent-key-material-0123456789abcdef');
      final blob = Dpapi.protect(data, entropy: entropy);

      expect(blob, isNotEmpty);
      expect(blob, isNot(equals(data)), reason: '密文不能等于明文');
      // 明文不该以任何形式出现在 blob 里。
      expect(blob.length, greaterThan(data.length * 2));

      expect(Dpapi.unprotect(blob, entropy: entropy), data);
    });

    test('同一个明文两次加密结果不同（DPAPI 内部随机）', () {
      final data = bytes('same-plaintext');
      final a = Dpapi.protect(data, entropy: entropy);
      final b = Dpapi.protect(data, entropy: entropy);
      expect(_bytesEqual(a, b), isFalse);
    });
  });

  group('失败即关（fail closed）', () {
    test('entropy 不同 ⇒ 解不开', () {
      final blob = Dpapi.protect(bytes('payload'), entropy: entropy);
      expect(
        () => Dpapi.unprotect(blob, entropy: bytes('another-entropy')),
        throwsA(isA<DpapiException>()),
      );
    });

    test('blob 被篡改 ⇒ 拒绝', () {
      final blob = Dpapi.protect(bytes('payload'), entropy: entropy);
      final tampered = Uint8List.fromList(blob);
      tampered[tampered.length ~/ 2] = tampered[tampered.length ~/ 2] ^ 0xff;
      expect(
        () => Dpapi.unprotect(tampered, entropy: entropy),
        throwsA(isA<DpapiException>()),
      );
    });

    test('垃圾数据 / 空输入 ⇒ 抛异常而不是返回半截结果', () {
      expect(
        () => Dpapi.unprotect(bytes('not-a-dpapi-blob'), entropy: entropy),
        throwsA(isA<DpapiException>()),
      );
      expect(
        () => Dpapi.unprotect(Uint8List(0), entropy: entropy),
        throwsA(isA<DpapiException>()),
      );
      expect(
        () => Dpapi.protect(Uint8List(0), entropy: entropy),
        throwsA(isA<DpapiException>()),
      );
    });
  });

  test('isSupported 在 Windows 上为 true', () {
    expect(Dpapi.isSupported, isTrue);
  }, skip: skipReason);
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
