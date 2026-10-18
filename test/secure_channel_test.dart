import 'dart:convert';
import 'dart:typed_data';

import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// 协议 5 安全通道的回归网。
///
/// 这些性质每一条都对应一个真实威胁，改通道代码时**先**看这里：
/// 1. 正确令牌的双方能互通（加密不是单向的）；
/// 2. 篡改任意一个字节 → 解密失败（不是"解出垃圾"）；
/// 3. 令牌不同 ⇒ 派生密钥不同 ⇒ 跨令牌解不开；
/// 4. 证明标签互不通用（serverProof ≠ clientProof）；
/// 5. nonce 不同 ⇒ 密钥不同（没有静态密钥复用）。
void main() {
  const token =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  ChannelKeys keysFor({
    String secret = token,
    String clientNonce = 'c0ffee',
    String serverNonce = 'badc0de',
  }) {
    return SecureChannelCrypto.deriveKeys(
      token: secret,
      clientNonce: clientNonce,
      serverNonce: serverNonce,
    );
  }

  group('SecureChannel 加解密', () {
    test('同一密钥的往返：客户端加密 → 服务端解密', () {
      final keys = keysFor();
      final clientSide = SecureChannel(keys);
      final serverSide = SecureChannel(keys);
      final message = <String, dynamic>{
        'requestId': 'r1',
        'action': 'unlock',
        'password': 'p@ssw0rd',
      };

      final sealed = clientSide.seal(message, fromClient: true);
      final opened = serverSide.open(sealed, fromClient: true);

      expect(opened['action'], 'unlock');
      expect(opened['password'], 'p@ssw0rd');
    });

    test('方向隔离：用服务端密钥解客户端的帧必须失败', () {
      final keys = keysFor();
      final clientSide = SecureChannel(keys);
      final sealed = clientSide.seal({'a': 1}, fromClient: true);

      // 把客户端帧当服务端帧解 —— 方向密钥不同，MAC 必须不匹配。
      expect(
        () => clientSide.open(sealed, fromClient: false),
        throwsA(isA<SecureChannelException>()),
      );
    });

    test('篡改任意一个字节都会被拒绝（认证，而不是静默解出垃圾）', () {
      final keys = keysFor();
      final channel = SecureChannel(keys);
      final sealed = channel.seal({'secret': 'x'}, fromClient: true);

      // 逐字节翻转（取前 40 字节即可覆盖 IV / 密文 / MAC 三段）。
      for (var i = 0; i < sealed.length && i < 40; i++) {
        final tampered = Uint8List.fromList(sealed);
        tampered[i] ^= 0x01;
        expect(
          () => channel.open(tampered, fromClient: true),
          throwsA(isA<SecureChannelException>()),
          reason: '第 $i 字节被改动后仍被接受',
        );
      }
    });

    test('截断的帧被拒绝', () {
      final channel = SecureChannel(keysFor());
      final sealed = channel.seal({'a': 1}, fromClient: true);
      expect(
        () => channel.open(
          Uint8List.fromList(sealed.sublist(0, sealed.length - 1)),
          fromClient: true,
        ),
        throwsA(isA<SecureChannelException>()),
      );
    });

    test('令牌不同 ⇒ 解不开对方的帧', () {
      final a = SecureChannel(keysFor());
      final b = SecureChannel(keysFor(
        secret:
            'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
      ));
      final sealed = a.seal({'a': 1}, fromClient: true);
      expect(
        () => b.open(sealed, fromClient: true),
        throwsA(isA<SecureChannelException>()),
      );
    });

    test('nonce 不同 ⇒ 派生密钥不同（无静态密钥复用）', () {
      final k1 = keysFor(clientNonce: 'a', serverNonce: 'b');
      final k2 = keysFor(clientNonce: 'a', serverNonce: 'c');
      expect(k1.clientToServerEnc, isNot(equals(k2.clientToServerEnc)));
      expect(k1.serverToClientMac, isNot(equals(k2.serverToClientMac)));
    });

    test('四把方向密钥互不相同', () {
      final keys = keysFor();
      final all = [
        keys.clientToServerEnc,
        keys.clientToServerMac,
        keys.serverToClientEnc,
        keys.serverToClientMac,
      ];
      for (var i = 0; i < all.length; i++) {
        for (var j = i + 1; j < all.length; j++) {
          expect(all[i], isNot(equals(all[j])),
              reason: '第 $i 与第 $j 把密钥相同');
        }
      }
    });
  });

  group('互相证明', () {
    test('同一输入下 serverProof / clientProof 不同（标签不可顶替）', () {
      final server = SecureChannelCrypto.serverProof(
        token: token,
        clientNonce: 'cn',
        serverNonce: 'sn',
      );
      final client = SecureChannelCrypto.clientProof(
        token: token,
        clientNonce: 'cn',
        serverNonce: 'sn',
      );
      expect(server, isNot(equals(client)));
    });

    test('nonce 变了证明就变（防重放）', () {
      final a = SecureChannelCrypto.serverProof(
        token: token,
        clientNonce: 'cn',
        serverNonce: 'sn1',
      );
      final b = SecureChannelCrypto.serverProof(
        token: token,
        clientNonce: 'cn',
        serverNonce: 'sn2',
      );
      expect(a, isNot(equals(b)));
    });

    test('令牌错了证明就不对（客户端能识破冒充的核心）', () {
      final real = SecureChannelCrypto.serverProof(
        token: token,
        clientNonce: 'cn',
        serverNonce: 'sn',
      );
      final fake = SecureChannelCrypto.serverProof(
        token: 'deadbeef' * 8,
        clientNonce: 'cn',
        serverNonce: 'sn',
      );
      expect(SecureChannelCrypto.proofsMatch(real, fake), isFalse);
      expect(SecureChannelCrypto.proofsMatch(real, real), isTrue);
    });

    test('randomNonce 每次都不同且长度稳定', () {
      final a = SecureChannelCrypto.randomNonce();
      final b = SecureChannelCrypto.randomNonce();
      expect(a, isNot(equals(b)));
      expect(a.length, 64); // 32 字节的十六进制
      // 64 个十六进制字符超出 int64，所以用正则而不是 int.tryParse。
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a), isTrue, reason: a);
    });
  });

  group('帧分帧', () {
    test('encodePayload / readBytes 往返（密文负载也能正确分帧）', () {
      final payload = Uint8List.fromList(List<int>.generate(300, (i) => i % 256));
      final frame = encodePayload(payload);
      expect(frame.length, payload.length + 4);
      expect(frame.sublist(0, 4), [300 & 0xff, (300 >> 8) & 0xff, 0, 0]);
      expect(frame.sublist(4), payload);
    });

    test('明文 JSON 帧仍然可读（握手阶段用）', () {
      final frame = encodeMessage({'hello': 'easypass'});
      final text = utf8.decode(frame.sublist(4));
      expect(text, contains('easypass'));
    });
  });
}
