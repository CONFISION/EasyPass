import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

import '../../protocol/secure_channel.dart' show SecureChannelCrypto;

/// 包裹失败（密钥不对 / 密文被篡改 / 格式损坏）。
///
/// 一旦抛出，调用方必须**保持智能体域锁定**（fail closed），不得回退到任何
/// 弱存储或"先试试旧格式"。
class AgentKeyMaterialException implements Exception {
  AgentKeyMaterialException(this.message);

  final String message;

  @override
  String toString() => 'AgentKeyMaterialException: $message';
}

/// 用"智能体专属密钥"包裹一份保险库密钥（vaultKey）。
///
/// 为什么需要包裹而不是直接存 vaultKey：
/// - 主密码可以换（`vaultKey` 会整库重加密），但**智能体的长期凭据不该跟着变**；
///   包裹之后换主密码只需重新包裹一次，库密文不动。
/// - 专属密钥泄露时，换一把新随机密钥**重新包裹**即可让它立刻作废 —— 这就是
///   "泄露可即时重置、不损伤数据"的实现方式。
///
/// 安全纪律：
/// - **认证加密**：encrypt-then-MAC（AES-256-CBC + HMAC-SHA256），先验 MAC 再解密；
///   篡改/错密钥一律抛异常，绝不返回半截密钥。
/// - 加密与 MAC 用两把**由 HMAC 派生的独立子密钥**（不要复用同一把）。
/// - 专属密钥是 256-bit **随机数**（不是用户密码），因此不存在字典攻击面。
class AgentKeyMaterial {
  AgentKeyMaterial._();

  static const int version = 1;

  /// vaultKey 的长度（`AppConstants.pbkdf2KeyLength`）。
  static const int keyBytes = 32;

  /// 专属密钥的长度：256-bit 随机。
  static const int agentKeyBytes = 32;

  static const int _ivBytes = 16;

  static const String _encLabel = 'easypass-agent-wrap-enc-v1';
  static const String _macLabel = 'easypass-agent-wrap-mac-v1';

  /// 生成一把专属密钥（256-bit 随机）。
  static Uint8List generateAgentKey() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(agentKeyBytes, (_) => random.nextInt(256)),
    );
  }

  /// 把 [vaultKey] 用 [agentKey] 包裹成可落库的 base64 字符串。
  static String wrap({
    required Uint8List vaultKey,
    required Uint8List agentKey,
  }) {
    _requireLength(vaultKey, keyBytes, 'vaultKey');
    _requireLength(agentKey, agentKeyBytes, 'agentKey');

    final iv = _randomBytes(_ivBytes);
    final ciphertext = _encrypter(agentKey).encryptBytes(vaultKey, iv: encrypt.IV(iv)).bytes;
    final mac = _mac(agentKey, iv, ciphertext);

    return base64Encode(utf8.encode(jsonEncode({
      'v': version,
      'iv': base64Encode(iv),
      'ct': base64Encode(ciphertext),
      'mac': base64Encode(mac),
    })));
  }

  /// 解包；任何异常都抛 [AgentKeyMaterialException]（调用方据此 fail closed）。
  static Uint8List unwrap({
    required String blob,
    required Uint8List agentKey,
  }) {
    _requireLength(agentKey, agentKeyBytes, 'agentKey');

    final Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(blob)));
      if (decoded is! Map) {
        throw AgentKeyMaterialException('包裹格式不是 JSON 对象');
      }
      map = Map<String, dynamic>.from(decoded);
    } catch (error) {
      throw AgentKeyMaterialException('包裹数据损坏：$error');
    }

    if ((map['v'] as num?)?.toInt() != version) {
      throw AgentKeyMaterialException('未知的包裹版本：${map['v']}');
    }

    final Uint8List iv;
    final Uint8List ciphertext;
    final Uint8List mac;
    try {
      iv = base64Decode(map['iv'] as String);
      ciphertext = base64Decode(map['ct'] as String);
      mac = base64Decode(map['mac'] as String);
    } catch (error) {
      throw AgentKeyMaterialException('包裹字段损坏：$error');
    }

    if (iv.length != _ivBytes) {
      throw AgentKeyMaterialException('IV 长度不对');
    }

    // **先验 MAC 再解密**：否则等于把未认证的密文喂给解密器。
    final expected = _mac(agentKey, iv, ciphertext);
    if (!SecureChannelCrypto.constantTimeEquals(mac, expected)) {
      throw AgentKeyMaterialException('MAC 校验失败（密钥不对或密文被篡改）');
    }

    final Uint8List plain;
    try {
      plain = Uint8List.fromList(
        _encrypter(agentKey).decryptBytes(
          encrypt.Encrypted(ciphertext),
          iv: encrypt.IV(iv),
        ),
      );
    } catch (error) {
      throw AgentKeyMaterialException('解包失败：$error');
    }

    if (plain.length != keyBytes) {
      throw AgentKeyMaterialException('解出的密钥长度不对：${plain.length}');
    }
    return plain;
  }

  /// 校验一段包裹能否用 [agentKey] 解开（不返回密钥本体）。
  static bool verifies({required String blob, required Uint8List agentKey}) {
    try {
      final key = unwrap(blob: blob, agentKey: agentKey);
      key.fillRange(0, key.length, 0);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─── 内部 ──────────────────────────────────────────────

  static encrypt.Encrypter _encrypter(Uint8List agentKey) {
    return encrypt.Encrypter(
      encrypt.AES(
        encrypt.Key(_derive(agentKey, _encLabel)),
        mode: encrypt.AESMode.cbc,
      ),
    );
  }

  /// 由专属密钥派生独立的**加密子密钥**与 **MAC 子密钥**（互不复用）。
  static Uint8List _derive(Uint8List agentKey, String label) {
    return Uint8List.fromList(
      Hmac(sha256, agentKey).convert(utf8.encode(label)).bytes,
    );
  }

  static Uint8List _mac(Uint8List agentKey, Uint8List iv, Uint8List ciphertext) {
    final macKey = _derive(agentKey, _macLabel);
    final data = Uint8List.fromList([...iv, ...ciphertext]);
    return Uint8List.fromList(Hmac(sha256, macKey).convert(data).bytes);
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static void _requireLength(Uint8List value, int expected, String name) {
    if (value.length != expected) {
      throw AgentKeyMaterialException('$name 长度必须是 $expected，实际 ${value.length}');
    }
  }
}
