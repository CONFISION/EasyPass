/// 核心 ↔ 客户端的安全通道（协议 5）。
///
/// 为什么要有它：协议 4 的握手把**令牌明文**放在第一帧里，之后的条目 JSON
/// 也是明文过线。协议 5 改成：
///
/// 1. **令牌永不上线**：双方各出一个随机 nonce，用 `HMAC(token, 标签‖nonces)`
///    互相证明「我知道令牌」，令牌本身一个字节都不发。
/// 2. **双向认证**：客户端先验 `serverProof`（假核心无法冒充），服务端再验
///    `clientProof`（无令牌者连不上）。
/// 3. **之后全程加密 + 认证**：每条帧用 AES-256-CBC + HMAC-SHA256
///    （encrypt-then-MAC），方向密钥由 nonces + token 派生，互不复用。
///
/// 诚实的能力边界（不要过度承诺）：这只保证**链路上没有明文**，且能挡住
/// 「没有令牌的进程」和「被动的抓包者」。它**挡不住同用户的恶意进程** ——
/// 那个进程能读 `daemon.json`（也就拿到了令牌），而且 UI 本来就要显示明文
/// 密码。真正的边界是「同一用户账户」，不是密码学。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// 握手/加密失败。调用方应**直接断开**，不要降级成明文。
class SecureChannelException implements Exception {
  SecureChannelException(this.message);

  final String message;

  @override
  String toString() => 'SecureChannelException: $message';
}

/// 通道两端共用的密码学原语。
class SecureChannelCrypto {
  SecureChannelCrypto._();

  static const String _serverProofLabel = 'easypass-server-proof';
  static const String _clientProofLabel = 'easypass-client-proof';
  static const String _keyLabel = 'easypass-channel-v5';

  static const int _nonceBytes = 32;
  static const int _ivBytes = 16;
  static const int _tagBytes = 32;

  /// 随机 nonce（十六进制）。
  static String randomNonce() {
    final random = Random.secure();
    return List<int>.generate(_nonceBytes, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Uint8List _tokenBytes(String token) {
    // 令牌就是 32 字节随机数的十六进制表示；解析失败时退回其 UTF-8 字节，
    // 这样自定义令牌（测试）也能用，而不会静默变成空密钥。
    try {
      return Uint8List.fromList(_hexDecode(token));
    } catch (_) {
      return Uint8List.fromList(utf8.encode(token));
    }
  }

  static List<int> _hexDecode(String hex) {
    if (hex.length.isOdd) throw const FormatException('odd-length hex');
    final out = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      out.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return out;
  }

  static Uint8List _hmac(List<int> key, List<int> data) {
    return Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);
  }

  /// 常数时间比较（避免按字节短路泄漏）。
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 两个十六进制证明串的常数时间比较。
  static bool proofsMatch(String a, String b) =>
      constantTimeEquals(utf8.encode(a), utf8.encode(b));

  /// 服务端证明：`HMAC(token, "server" ‖ clientNonce ‖ serverNonce)`。
  static String serverProof({
    required String token,
    required String clientNonce,
    required String serverNonce,
  }) {
    final mac = _hmac(
      _tokenBytes(token),
      utf8.encode('$_serverProofLabel|$clientNonce|$serverNonce'),
    );
    return _hexEncode(mac);
  }

  /// 客户端证明：标签不同 ⇒ 两条证明不可互相顶替。
  static String clientProof({
    required String token,
    required String clientNonce,
    required String serverNonce,
  }) {
    final mac = _hmac(
      _tokenBytes(token),
      utf8.encode('$_clientProofLabel|$clientNonce|$serverNonce'),
    );
    return _hexEncode(mac);
  }

  static String _hexEncode(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// 由令牌 + 两个 nonce 派生方向密钥（HKDF-Extract + Expand）。
  ///
  /// 一次派生 128 字节：`c2sEnc | c2sMac | s2cEnc | s2cMac`，四把密钥互不复用
  /// —— 单方向密钥复用是 CBC 模式最常见的自伤方式。
  static ChannelKeys deriveKeys({
    required String token,
    required String clientNonce,
    required String serverNonce,
  }) {
    final prk = _hmac(
      _tokenBytes(token),
      utf8.encode('$clientNonce|$serverNonce'),
    );
    final okm = <int>[];
    var previous = <int>[];
    var counter = 1;
    while (okm.length < 128) {
      previous = _hmac(
        prk,
        [...previous, ...utf8.encode(_keyLabel), counter],
      );
      okm.addAll(previous);
      counter++;
    }
    Uint8List slice(int offset) =>
        Uint8List.fromList(okm.sublist(offset, offset + 32));
    return ChannelKeys(
      clientToServerEnc: slice(0),
      clientToServerMac: slice(32),
      serverToClientEnc: slice(64),
      serverToClientMac: slice(96),
    );
  }
}

/// 四个方向密钥。
class ChannelKeys {
  const ChannelKeys({
    required this.clientToServerEnc,
    required this.clientToServerMac,
    required this.serverToClientEnc,
    required this.serverToClientMac,
  });

  final Uint8List clientToServerEnc;
  final Uint8List clientToServerMac;
  final Uint8List serverToClientEnc;
  final Uint8List serverToClientMac;

  Uint8List encKey(bool fromClient) =>
      fromClient ? clientToServerEnc : serverToClientEnc;

  Uint8List macKey(bool fromClient) =>
      fromClient ? clientToServerMac : serverToClientMac;
}

/// 单向信道加解密器（客户端持两个方向，服务端持两个方向）。
///
/// 帧负载格式：`IV(16) ‖ ciphertext ‖ HMAC-SHA256(IV‖ciphertext)(32)`。
/// 先验 MAC 再解密（encrypt-then-MAC），被篡改的帧一律丢弃。
class SecureChannel {
  SecureChannel._(this._keys);

  final ChannelKeys _keys;

  factory SecureChannel(ChannelKeys keys) => SecureChannel._(keys);

  /// 加密（seal）一条 JSON 消息。命名避开 `encrypt`：那是 import 的前缀。
  Uint8List seal(Map<String, dynamic> message, {required bool fromClient}) {
    final plaintext = utf8.encode(jsonEncode(message));
    final ivBytes = List<int>.generate(
      SecureChannelCrypto._ivBytes,
      (_) => Random.secure().nextInt(256),
    );
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(_keys.encKey(fromClient)),
          mode: encrypt.AESMode.cbc),
    );
    final cipher = encrypter
        .encryptBytes(plaintext, iv: encrypt.IV(Uint8List.fromList(ivBytes)))
        .bytes;
    final tag = Hmac(sha256, _keys.macKey(fromClient))
        .convert([...ivBytes, ...cipher])
        .bytes;
    return Uint8List.fromList([...ivBytes, ...cipher, ...tag]);
  }

  /// 解密（open）一条帧负载。MAC 不对、或密文损坏 → 抛 [SecureChannelException]
  /// （调用方必须断开连接，绝不把解不开的帧当作空消息）。
  Map<String, dynamic> open(Uint8List payload, {required bool fromClient}) {
    const ivLen = SecureChannelCrypto._ivBytes;
    const tagLen = SecureChannelCrypto._tagBytes;
    if (payload.length <= ivLen + tagLen) {
      throw SecureChannelException('帧长度异常（${payload.length} 字节）');
    }
    final iv = payload.sublist(0, ivLen);
    final cipher = payload.sublist(ivLen, payload.length - tagLen);
    final tag = payload.sublist(payload.length - tagLen);
    final expected = Hmac(sha256, _keys.macKey(fromClient))
        .convert([...iv, ...cipher])
        .bytes;
    if (!SecureChannelCrypto.constantTimeEquals(tag, expected)) {
      throw SecureChannelException('帧认证失败（MAC 不匹配）');
    }
    try {
      final encrypter = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(_keys.encKey(fromClient)),
            mode: encrypt.AESMode.cbc),
      );
      final plain = encrypter.decryptBytes(
        encrypt.Encrypted(Uint8List.fromList(cipher)),
        iv: encrypt.IV(Uint8List.fromList(iv)),
      );
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map) {
        throw SecureChannelException('帧内容不是 JSON 对象');
      }
      return Map<String, dynamic>.from(decoded);
    } on SecureChannelException {
      rethrow;
    } catch (error) {
      throw SecureChannelException('解密失败：$error');
    }
  }
}
