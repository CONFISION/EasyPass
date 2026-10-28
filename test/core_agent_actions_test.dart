import 'dart:io';

import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_access_store.dart';
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
        {'nickname': 'DSH', 'mode': 'trusted', 'password': password},
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

    test('要 trusted 却没有任何主密码 ⇒ 拒绝，且不留下配对', () async {
      await expectLater(
        core.call(Actions.createAgentPairing, {'nickname': 'DSH', 'mode': 'trusted'}),
        throwsA(anything),
      );
      expect(await store().list(), isEmpty,
          reason: 'trusted 必须由主密码确认，失败不能留下半成品配对');
      expect(core.sessions.agent.isUnlocked, isFalse);
    });

    test('主密码错 ⇒ 拒绝，且不留下配对', () async {
      await expectLater(
        core.call(Actions.createAgentPairing, {
          'nickname': 'DSH',
          'mode': 'trusted',
          'password': 'wrong-pw',
        }),
        throwsA(anything),
      );
      expect(await store().list(), isEmpty);
    });

    test('trusted 配对成功后 trusted=true（否则策略会判 notTrusted）', () async {
      final created = await core.call(Actions.createAgentPairing, {
        'nickname': 'DSH',
        'mode': 'trusted',
        'password': password,
      });
      expect(created['trusted'], isTrue);

      final stored = await store().findById(created['id'] as String);
      expect(stored!.trusted, isTrue);
      expect(stored.mode, AgentMode.trusted);
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

    test('打开/关闭总开关会广播 agentAccess 主题（侧边栏入口显隐靠它）', () async {
      await core.call(Actions.enableAgentAccess);
      expect(core.changedTopics, contains(Topics.agentAccess),
          reason: 'UI 的「智能体活动」入口只在开启时出现，切开关必须推送');

      core.changedTopics.clear();
      await core.call(Actions.disableAgentAccess);
      expect(core.changedTopics, contains(Topics.agentAccess));
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

    test('切回逐次审批：信任清零、不清 agent 域（3.1.0 修复）', () async {
      final created = await core.call(
        Actions.createAgentPairing,
        {'nickname': 'DSH', 'mode': 'trusted', 'password': password},
      );
      final id = created['id'] as String;
      expect(core.sessions.agent.isUnlocked, isTrue);

      final back = await core.call(
          Actions.setAgentAccessMode, {'id': id, 'mode': 'approval'});
      // 旧实现会在这里锁掉 agent 域，导致方式 1 的单条目工具"先读库后过闸"
      // 拿不到钥匙、审批弹窗根本不出现（评审 H2/H3）。切方式只清授权，
      // 会话域仍由总开关控制。
      expect(back['agentUnlocked'], isTrue);
      expect(core.sessions.agent.isUnlocked, isTrue,
          reason: 'agent 域生命周期只随总开关/显式锁定/核心退出变化');

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
    test('撤销 = 彻底移除记录，列表里不再出现（真机反馈：留着像没生效）', () async {
      final created =
          await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      final id = created['id'] as String;

      await core.call(Actions.revokeAgentPairing, {'id': id});

      expect(await store().findById(id), isNull, reason: '记录必须真的被删掉');
      final listed = await core.call(Actions.listAgentPairings);
      expect((listed['pairings'] as List), isEmpty);
    });

    test('撤销一个配对不会锁掉整个 agent 域（其它配对可能还在用）', () async {
      final a = await core.call(Actions.createAgentPairing, {'nickname': 'A'});
      await core.call(Actions.createAgentPairing, {'nickname': 'B'});
      await core.call(Actions.unlockAgentDomain, {'password': password});

      final result =
          await core.call(Actions.revokeAgentPairing, {'id': a['id']});

      expect(core.sessions.agent.isUnlocked, isTrue,
          reason: '总开关还开着，撤一个配对不该殃及其它智能体');
      expect(result['remaining'], 1);
    });

    test('同一毫秒内连建两个配对不会撞 id（回归：曾用时间戳当 id）', () async {
      final a = await core.call(Actions.createAgentPairing, {'nickname': 'A'});
      final b = await core.call(Actions.createAgentPairing, {'nickname': 'B'});

      expect(a['id'], isNot(b['id']));
      expect((await store().list()).length, 2);
    });

    test('撤销不存在的配对 ⇒ notFound', () async {
      await expectLater(
        core.call(Actions.revokeAgentPairing, {'id': 'p_nope'}),
        throwsA(anything),
      );
    });
  });

  group('重名', () {
    test('同名配对只能有一个（真机反馈：连点两次出现两个 DSH）', () async {
      await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});

      await expectLater(
        core.call(Actions.createAgentPairing, {'nickname': 'DSH'}),
        throwsA(anything),
      );

      final listed = await core.call(Actions.listAgentPairings);
      expect((listed['pairings'] as List).length, 1);
    });

    test('首尾空白也算同一个昵称', () async {
      await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      await expectLater(
        core.call(Actions.createAgentPairing, {'nickname': '  DSH  '}),
        throwsA(anything),
      );
    });

    test('撤销后可以用回同一个昵称', () async {
      final first =
          await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      await core.call(Actions.revokeAgentPairing, {'id': first['id']});

      final again = await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      expect(again['id'], isNot(first['id']));
    });
  });

  group('免询问 / 删除所有数据（3.1.0 评审修复）', () {
    test('clearStandingRead 动作存在且返回 ok；配对列表带 standingRead 字段', () async {
      final created =
          await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      final listed = await core.call(Actions.listAgentPairings);
      final pairings = (listed['pairings'] as List).cast<Map>();
      expect(pairings.first.containsKey('standingRead'), isTrue);

      final cleared = await core.call(
          Actions.clearStandingRead, {'id': created['id'] as String});
      expect(cleared['ok'], isTrue);
    });

    test('删除所有数据会清掉智能体审计、配对与开关（M8）', () async {
      await core.call(Actions.enableAgentAccess);
      await core.call(Actions.createAgentPairing, {'nickname': 'DSH'});
      await vault.db.insertAgentAudit(
        at: 1,
        pairingId: 'p1',
        nickname: 'DSH',
        mode: 'trusted',
        tool: 'status',
        op: 'read',
        decision: 'allowed',
      );

      final result = await core.call(Actions.deleteAllData, {'confirm': true});
      expect(result['agentDataCleared'], isTrue);
      expect(await vault.db.getMetaByPrefix(AgentPairingStore.keyPrefix), isEmpty);
      expect(await vault.db.countAgentAudit(), 0);
      expect(
        await AgentAccessStore(vault.db, blobFile: File(
                '${Directory.systemTemp.path}\\unused-${DateTime.now().microsecondsSinceEpoch}.dpapi'))
            .isEnabled(),
        isFalse,
      );
      expect(core.sessions.agent.isUnlocked, isFalse);
      expect(core.changedTopics, contains(Topics.agentAccess));
    });
  });
}
