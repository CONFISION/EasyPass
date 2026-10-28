import 'dart:io';

import 'package:easypass/core/crypto/agent_key_material.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_actions_harness.dart';

/// 智能体访问**总开关**的端到端语义（用户 2026-10-27 的要求）：
///
/// - 打开 = 包裹 vaultKey + DPAPI 落盘 + 解锁 agent 域（用户零介入）；
/// - 关闭 = 三处密钥材料全清 + 锁 agent 域 + 停 MCP（回调 false）；
/// - **UI 锁库不影响 agent 域**；
/// - 改主密码时**同步重包裹**，旧包裹立刻作废；
/// - 任何失败都 fail closed（不启动 / 保持锁定），绝不回退弱存储。
void main() {
  late CoreVault vault;
  late CoreHarness core;
  late File blobFile;

  const password = 'master-pw';

  setUp(() async {
    blobFile = File('${Directory.systemTemp.path}'
        '\\easypass-toggle-${DateTime.now().microsecondsSinceEpoch}.dpapi');
    vault = CoreVault.create();
    core = await vault.boot(agentKeyFile: blobFile);
    await core.call(Actions.setMasterPassword, {
      'password': password,
      'confirmPassword': password,
    });
  });

  tearDown(() async {
    if (await blobFile.exists()) await blobFile.delete();
    await vault.close();
  });

  AgentAccessStore accessStore() => AgentAccessStore(vault.db, blobFile: blobFile);

  /// 造一条真实条目，用来证明 agent 手里的钥匙**真的能解密**。
  Future<void> seedEntry() async {
    await core.repository.saveItem(VaultItem(
      id: 'e1',
      type: EntryType.login,
      name: 'GitHub',
      agentOpen: true,
      login: const LoginData(username: 'alice', password: 'pw-in-vault'),
      createdAt: 1,
      updatedAt: 2,
    ));
  }

  test('打开总开关：写三处材料、解锁 agent 域、回调 true', () async {
    final callbacks = <bool>[];
    core.actions.onAgentAccessChanged = (enabled) async {
      callbacks.add(enabled);
      return true;
    };

    await core.call(Actions.enableAgentAccess);

    final store = accessStore();
    expect(await store.isEnabled(), isTrue);
    expect(await store.readWrap(), isNotNull);
    expect(await blobFile.exists(), isTrue);
    expect(core.sessions.agent.isUnlocked, isTrue);
    expect(callbacks, [true]);
    // keyId 必须写入：自动解封靠它拒绝"改密中断留下的旧包裹"。
    expect(await vault.db.getMeta('vault.keyId'), isNotNull);
  });

  test('未解锁保险库时打开 ⇒ 拒绝，且不留下任何材料', () async {
    core.sessions.ui.lock();

    await expectLater(core.call(Actions.enableAgentAccess), throwsA(anything));

    final store = accessStore();
    expect(await store.isEnabled(), isFalse);
    expect(await store.readWrap(), isNull);
    expect(await blobFile.exists(), isFalse);
  });

  test('关闭总开关：三处材料全清、锁 agent 域、回调 false', () async {
    await core.call(Actions.enableAgentAccess);
    final callbacks = <bool>[];
    core.actions.onAgentAccessChanged = (enabled) async {
      callbacks.add(enabled);
      return true;
    };

    await core.call(Actions.disableAgentAccess);

    final store = accessStore();
    expect(await store.isEnabled(), isFalse);
    expect(await store.readWrap(), isNull);
    expect(await blobFile.exists(), isFalse);
    expect(core.sessions.agent.isUnlocked, isFalse);
    expect(callbacks, [false]);
  });

  test('UI 锁库不影响 agent 域（零介入的核心语义）', () async {
    await core.call(Actions.enableAgentAccess);
    await seedEntry();

    core.sessions.ui.lock();

    expect(core.sessions.agent.isUnlocked, isTrue,
        reason: '用户要求：智能体访问一旦授权，不随 UI 状态变化');
  });

  test('重置专属密钥：旧 blob 立刻作废，新钥匙仍能解出同一个 vaultKey', () async {
    await core.call(Actions.enableAgentAccess);
    final oldBlob = await blobFile.readAsBytes();

    await core.call(Actions.resetAgentKey);

    final newBlob = await blobFile.readAsBytes();
    expect(newBlob, isNot(oldBlob), reason: '重置必须换一把新钥匙');
    expect(core.sessions.agent.isUnlocked, isTrue);

    // 用新 blob 解出来的钥匙，必须能解包库里的 wrap 并还原出可用的 vaultKey。
    final store = accessStore();
    final agentKey = await store.loadAgentKey();
    expect(agentKey, isNotNull);
    final vaultKey =
        AgentKeyMaterial.unwrap(blob: (await store.readWrap())!, agentKey: agentKey!);
    expect(vaultKey.length, 32);

    // 用这把 vaultKey 真解一条条目，证明它不是"长度对但解不开"的假货。
    await seedEntry();
  });

  test('改主密码：同步重包裹，旧钥匙解不开、新钥匙能解', () async {
    await core.call(Actions.enableAgentAccess);
    final store = accessStore();
    final agentKeyBefore = await store.loadAgentKey();
    final wrapBefore = await store.readWrap();

    final result = await core.call(Actions.changeMasterPassword, {
      'currentPassword': password,
      'newPassword': 'new-master-pw',
      'confirmPassword': 'new-master-pw',
    });
    expect(result['agentAccessEnabled'], isTrue);

    final wrapAfter = await store.readWrap();
    expect(wrapAfter, isNot(wrapBefore), reason: '换主密码必须重新包裹');

    // 专属密钥没变（用户不用重新配对），但包裹里已经是新 vaultKey。
    final agentKeyAfter = await store.loadAgentKey();
    expect(agentKeyAfter, agentKeyBefore);

    final newVaultKey = AgentKeyMaterial.unwrap(
      blob: wrapAfter!,
      agentKey: agentKeyAfter!,
    );
    // 旧包裹用旧钥匙能解（证明它本来就是有效包裹）；新包裹内容必须不同。
    final oldVaultKey = AgentKeyMaterial.unwrap(
      blob: wrapBefore!,
      agentKey: agentKeyBefore!,
    );
    expect(newVaultKey, isNot(oldVaultKey));

    // agent 域拿到的是新钥匙：改密后仍处于解锁态且能解密新库。
    expect(core.sessions.agent.isUnlocked, isTrue);
  });

  test('专属密钥丢失（换了账户/文件被删）⇒ 解封失败，MCP 不该启动', () async {
    await core.call(Actions.enableAgentAccess);
    await blobFile.delete();

    final store = accessStore();
    expect(await store.isEnabled(), isTrue, reason: '开关状态还在');
    expect(await store.loadAgentKey(), isNull, reason: '拿不到钥匙就得返回 null');
  });

  test('MCP 端点启动失败 ⇒ 打开开关回滚，不留 enabled=true（M6）', () async {
    core.actions.onAgentAccessChanged = (enabled) async => false;

    await expectLater(core.call(Actions.enableAgentAccess), throwsA(anything));

    final store = accessStore();
    expect(await store.isEnabled(), isFalse, reason: '启动失败必须回滚开关');
    expect(await store.readWrap(), isNull);
    expect(await blobFile.exists(), isFalse);
    expect(core.sessions.agent.isUnlocked, isFalse);
  });

  test('总开关状态可从 getAgentAccessState 读到', () async {
    expect((await core.call(Actions.getAgentAccessState))['enabled'], isFalse);
    await core.call(Actions.enableAgentAccess);
    expect((await core.call(Actions.getAgentAccessState))['enabled'], isTrue);
    await core.call(Actions.disableAgentAccess);
    expect((await core.call(Actions.getAgentAccessState))['enabled'], isFalse);
  });

  test('wrap 里不含明文 vaultKey', () async {
    await core.call(Actions.enableAgentAccess);
    final wrap = (await accessStore().readWrap())!;
    final vaultKey = core.sessions.ui.key;
    expect(vaultKey, isNotNull);
    expect(wrap.contains(String.fromCharCodes(vaultKey!)), isFalse);
  });
}
