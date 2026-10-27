import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_actions_harness.dart';

/// 智能体访问的**核心侧动作**（配对管理、方式切换、agent 域解锁）。
///
/// 这些动作只对 `ui` 域开放 —— 智能体自己永远改不到授权。
/// 重点钉住三条：密钥只出现一次且库里只有哈希、切可信/切回逐次审批的锁语义、
/// agent 域拿的是**副本**（锁 ui 不得清空 agent 的钥匙）。
void main() {
  late CoreVault vault;
  late CoreHarness core;

  const password = 'master-pw';

  setUp(() async {
    vault = CoreVault.create();
    core = await vault.boot();
    await core.call(Actions.setMasterPassword, {
      'password': password,
      'confirmPassword': password,
    });
  });

  tearDown(() => vault.close());

  AgentPairingStore store() => AgentPairingStore(vault.db);

  group('配对创建 / 列出', () {
    test('密钥只返回一次，库里只有哈希', () async {
      final created = await core.call(
        Actions.createAgentPairing,
        {'nickname': 'DSH', 'mode': 'trusted'},
      );
      final key = created['key'] as String;
      final id = created['id'] as String;
      expect(key.length, 64);

      final stored = await store().findById(id);
      expect(stored, isNotNull);
      expect(stored!.keyHash, AgentPairingStore.hashKey(key));

      final raw = await vault.db.getMeta('${AgentPairingStore.keyPrefix}$id');
      expect(raw!.contains(key), isFalse, reason: '明文密钥绝不能落库');
    });

    test('列表不返回 keyHash', () async {
      await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      final listed = await core.call(Actions.listAgentPairings);
      final pairings = (listed['pairings'] as List).cast<Map>();
      expect(pairings.length, 1);
      expect(pairings.first.containsKey('keyHash'), isFalse);
      expect(listed['agentUnlocked'], isFalse);
    });

    test('昵称必填', () async {
      await expectLater(
        core.call(Actions.createAgentPairing, {'nickname': '   '}),
        throwsA(anything),
      );
    });
  });

  group('agent 域解锁 / 锁定', () {
    test('需要主密码：错的拒绝，对的解锁', () async {
      expect(core.sessions.agent.isUnlocked, isFalse);

      await expectLater(
        core.call(Actions.unlockAgentDomain, {'password': 'wrong-pw'}),
        throwsA(anything),
      );
      expect(core.sessions.agent.isUnlocked, isFalse);

      final result =
          await core.call(Actions.unlockAgentDomain, {'password': password});
      expect(result['agentUnlocked'], isTrue);
      expect(core.sessions.agent.isUnlocked, isTrue);
      expect(core.sessions.ui.isUnlocked, isTrue);
    });

    test('agent 域拿的是副本：锁 ui 不会清空 agent 的密钥', () async {
      await core.call(Actions.unlockAgentDomain, {'password': password});
      final agentKey = List<int>.from(core.sessions.agent.key!);

      core.sessions.ui.lock();

      expect(core.sessions.agent.isUnlocked, isTrue);
      expect(core.sessions.agent.key, agentKey,
          reason: '共享同一个 Uint8List 时这里会变成全 0');
    });

    test('lockAgentDomain 与 getAgentAccessState', () async {
      await core.call(Actions.unlockAgentDomain, {'password': password});
      expect((await core.call(Actions.getAgentAccessState))['agentUnlocked'],
          isTrue);

      await core.call(Actions.lockAgentDomain);
      expect((await core.call(Actions.getAgentAccessState))['agentUnlocked'],
          isFalse);
    });
  });

  group('方式切换', () {
    test('切到可信直通必须给主密码，成功后 trusted=true 且 agent 域解锁', () async {
      final created = await core.call(
        Actions.createAgentPairing,
        {'nickname': 'DSH', 'mode': 'approval'},
      );
      final id = created['id'] as String;

      await expectLater(
        core.call(Actions.setAgentAccessMode, {'id': id, 'mode': 'trusted'}),
        throwsA(anything),
      );
      expect(core.sessions.agent.isUnlocked, isFalse);

      final ok = await core.call(Actions.setAgentAccessMode,
          {'id': id, 'mode': 'trusted', 'password': password});
      expect(ok['agentUnlocked'], isTrue);

      final pairing = await store().findById(id);
      expect(pairing!.mode, AgentMode.trusted);
      expect(pairing.trusted, isTrue);
      expect(core.sessions.agent.isUnlocked, isTrue);
    });

    test('切回逐次审批：信任清零并立刻锁 agent 域', () async {
      final created = await core.call(
        Actions.createAgentPairing,
        {'nickname': 'DSH', 'mode': 'trusted'},
      );
      final id = created['id'] as String;
      await core.call(Actions.setAgentAccessMode,
          {'id': id, 'mode': 'trusted', 'password': password});
      expect(core.sessions.agent.isUnlocked, isTrue);

      final back =
          await core.call(Actions.setAgentAccessMode, {'id': id, 'mode': 'approval'});
      expect(back['agentUnlocked'], isFalse);
      expect(core.sessions.agent.isUnlocked, isFalse);

      final pairing = await store().findById(id);
      expect(pairing!.trusted, isFalse);
      expect(pairing.mode, AgentMode.approval);
    });

    test('未知方式 ⇒ invalidRequest', () async {
      final created =
          await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      await expectLater(
        core.call(Actions.setAgentAccessMode,
            {'id': created['id'], 'mode': 'full-access'}),
        throwsA(anything),
      );
    });
  });

  group('撤销', () {
    test('撤销会立刻锁 agent 域，记录保留（审计要对得上昵称）', () async {
      final created =
          await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      final id = created['id'] as String;
      await core.call(Actions.unlockAgentDomain, {'password': password});
      expect(core.sessions.agent.isUnlocked, isTrue);

      await core.call(Actions.revokeAgentPairing, {'id': id});

      expect(core.sessions.agent.isUnlocked, isFalse);
      final pairing = await store().findById(id);
      expect(pairing, isNotNull);
      expect(pairing!.isRevoked, isTrue);
      expect(pairing.nickname, 'DSH');
    });
  });
}
