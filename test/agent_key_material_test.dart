import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:easypass/core/crypto/agent_key_material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 专属密钥的包裹层（wrap / unwrap）。
///
/// 不变量：
/// 1. 用对了 key 能还原出**同一个** vaultKey；
/// 2. 用错了 key、密文被改、MAC 被改、格式损坏 —— 一律**抛异常**（fail closed），
///    绝不返回半截或"先给你一个试试"的密钥；
/// 3. 每次包裹的 IV 都不同（同 key 同明文也不能产出相同密文）。
void main() {
  Uint8List key([int seed = 0x11]) =>
      Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

  group('往返', () {
    test('用对的专属密钥能解回同一个 vaultKey', () {
      final vaultKey = key(0x10);
      final agentKey = AgentKeyMaterial.generateAgentKey();

      final blob = AgentKeyMaterial.wrap(vaultKey: vaultKey, agentKey: agentKey);
      final restored =
          AgentKeyMaterial.unwrap(blob: blob, agentKey: agentKey);

      expect(restored, vaultKey);
      expect(blob, isNot(contains(base64Encode(vaultKey))));
    });

    test('同一个密钥两次包裹的密文不同（IV 随机）', () {
      final vaultKey = key(0x20);
      final agentKey = AgentKeyMaterial.generateAgentKey();

      final a = AgentKeyMaterial.wrap(vaultKey: vaultKey, agentKey: agentKey);
      final b = AgentKeyMaterial.wrap(vaultKey: vaultKey, agentKey: agentKey);
      expect(a, isNot(b));
    });

    test('verifies 只做校验，不泄出密钥', () {
      final agentKey = AgentKeyMaterial.generateAgentKey();
      final blob = AgentKeyMaterial.wrap(vaultKey: key(0x30), agentKey: agentKey);

      expect(AgentKeyMaterial.verifies(blob: blob, agentKey: agentKey), isTrue);
      expect(
        AgentKeyMaterial.verifies(
          blob: blob,
          agentKey: AgentKeyMaterial.generateAgentKey(),
        ),
        isFalse,
      );
    });
  });

  group('失败即关（fail closed）', () {
    test('专属密钥不对 ⇒ 抛异常', () {
      final blob = AgentKeyMaterial.wrap(
        vaultKey: key(0x40),
        agentKey: AgentKeyMaterial.generateAgentKey(),
      );
      expect(
        () => AgentKeyMaterial.unwrap(
          blob: blob,
          agentKey: AgentKeyMaterial.generateAgentKey(),
        ),
        throwsA(isA<AgentKeyMaterialException>()),
      );
    });

    test('密文被篡改一个字节 ⇒ MAC 校验失败', () {
      final agentKey = AgentKeyMaterial.generateAgentKey();
      final vaultKey = key(0x50);
      final blob = AgentKeyMaterial.wrap(vaultKey: vaultKey, agentKey: agentKey);

      final outer = jsonDecode(utf8.decode(base64Decode(blob))) as Map;
      final ct = base64Decode(outer['ct'] as String);
      ct[0] = ct[0] ^ 0x01;
      outer['ct'] = base64Encode(ct);
      final tampered = base64Encode(utf8.encode(jsonEncode(outer)));

      expect(
        () => AgentKeyMaterial.unwrap(blob: tampered, agentKey: agentKey),
        throwsA(isA<AgentKeyMaterialException>()),
      );
    });

    test('MAC 被篡改 ⇒ 拒绝', () {
      final agentKey = AgentKeyMaterial.generateAgentKey();
      final blob = AgentKeyMaterial.wrap(vaultKey: key(0x60), agentKey: agentKey);

      final outer = jsonDecode(utf8.decode(base64Decode(blob))) as Map;
      final mac = base64Decode(outer['mac'] as String);
      mac[mac.length - 1] = mac[mac.length - 1] ^ 0xff;
      outer['mac'] = base64Encode(mac);
      final tampered = base64Encode(utf8.encode(jsonEncode(outer)));

      expect(
        () => AgentKeyMaterial.unwrap(blob: tampered, agentKey: agentKey),
        throwsA(isA<AgentKeyMaterialException>()),
      );
    });

    test('非 base64 / 非 JSON / 版本不对 / 字段缺失 ⇒ 都抛异常', () {
      final agentKey = AgentKeyMaterial.generateAgentKey();
      for (final bad in [
        'not-base64!!',
        base64Encode(utf8.encode('not json')),
        base64Encode(utf8.encode(jsonEncode({'v': 99}))),
        base64Encode(utf8.encode(jsonEncode({'v': 1, 'iv': 'AAAA'}))),
      ]) {
        expect(
          () => AgentKeyMaterial.unwrap(blob: bad, agentKey: agentKey),
          throwsA(isA<AgentKeyMaterialException>()),
          reason: '输入：$bad',
        );
      }
    });

    test('密钥长度不对直接拒绝（不给解密器喂垃圾）', () {
      expect(
        () => AgentKeyMaterial.wrap(
          vaultKey: Uint8List(16),
          agentKey: AgentKeyMaterial.generateAgentKey(),
        ),
        throwsA(isA<AgentKeyMaterialException>()),
      );
      expect(
        () => AgentKeyMaterial.wrap(
          vaultKey: Uint8List(32),
          agentKey: Uint8List(31),
        ),
        throwsA(isA<AgentKeyMaterialException>()),
      );
    });
  });

  /// 钥匙指纹：改密时与 agent 包裹同事务写进 `vault_meta.vault.keyId`，
  /// 启动自动解封时用它校验"包裹里那把钥匙仍是当前库的钥匙"（H6）。
  group('钥匙指纹 keyId', () {
    test('是 64 位小写十六进制，且对同一把钥匙是确定的', () {
      final vaultKey = key(0x70);
      final id = AgentKeyMaterial.keyId(vaultKey);

      expect(id, hasLength(64));
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(id), isTrue);
      expect(AgentKeyMaterial.keyId(vaultKey), id);
    });

    test('等于 SHA-256(vaultKey) 的十六进制（与 crypto 包直算一致）', () {
      final vaultKey = key(0x30);
      expect(AgentKeyMaterial.keyId(vaultKey), sha256.convert(vaultKey).toString());
    });

    test('不同钥匙的指纹不同（可用于识别旧包裹）', () {
      expect(
        AgentKeyMaterial.keyId(key(0x10)),
        isNot(AgentKeyMaterial.keyId(key(0x20))),
      );
    });

    test('指纹不泄漏钥匙本身', () {
      final vaultKey = key(0x40);
      final id = AgentKeyMaterial.keyId(vaultKey);

      expect(id.contains(base64Encode(vaultKey)), isFalse);
      expect(id.contains(vaultKey.map((b) => b.toRadixString(16)).join()),
          isFalse);
    });
  });
}
