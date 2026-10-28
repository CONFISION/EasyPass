// 智能体授权/审批/审计的**安全行为回归**。
//
// 这些用例对应评审 H1/H3/H4/H5/H9/M2/M4/M7，写法是"先把攻击条件造出来、
// 再断言系统拒绝且不落库"——不是测实现细节，而是钉住评审里实证过的缺陷。
//
// 历史：`zz_review_poc_test.dart` 的 POC-1/2/6/7/8 原本断言"缺陷成立"；
// 这里全部反转为"安全行为"（期望拒绝/不落库/不回滚）。
import 'dart:async';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/core_service/agent_actions.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/mcp/mcp_handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const trustedKey = 'k-trusted-sec';
  const approvalKey = 'k-approval-sec';
  const password = 'S3cr3t-P@ssw0rd';

  late AppDatabase db;
  late CryptoService crypto;
  late SessionDomains sessions;
  late VaultRepository repository;
  late AgentPairingStore pairingStore;
  late AgentAccessStore accessStore;
  late AgentActions actions;
  late List<String> clipboardWrites;
  late List<AgentAuditEntry> audits;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    crypto = CryptoService(secureStorage: InMemorySecretStore());
    sessions = SessionDomains(idleTimeout: const Duration(minutes: 5));
    final key = Uint8List.fromList(List<int>.filled(32, 9));
    sessions.agent.unlock(key);

    repository = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => sessions.agent.key,
    );
    await repository.saveItem(VaultItem(
      id: 'e-open',
      type: EntryType.login,
      name: 'GitHub',
      agentOpen: true,
      login: const LoginData(
        url: 'https://github.com',
        username: 'alice',
        password: password,
      ),
      notes: '这条备注不能泄露',
      createdAt: 1,
      updatedAt: 2,
    ));
    await repository.saveItem(VaultItem(
      id: 'e-closed',
      type: EntryType.login,
      name: '银行',
      login: const LoginData(username: 'bob', password: 'other-secret'),
      createdAt: 1,
      updatedAt: 2,
    ));

    pairingStore = AgentPairingStore(db);
    await pairingStore.save(AgentPairing(
      id: 'p-trusted',
      nickname: 'trusted',
      mode: AgentMode.trusted,
      trusted: true,
      keyHash: AgentPairingStore.hashKey(trustedKey),
      createdAt: 1,
    ));
    await pairingStore.save(AgentPairing(
      id: 'p-approval',
      nickname: 'approval',
      mode: AgentMode.approval,
      keyHash: AgentPairingStore.hashKey(approvalKey),
      createdAt: 1,
    ));

    accessStore = AgentAccessStore(db);
    await accessStore.setEnabled(true);

    clipboardWrites = <String>[];
    audits = <AgentAuditEntry>[];
    actions = AgentActions(
      repository: repository,
      sessions: sessions,
      pairingStore: pairingStore,
      agentAccess: accessStore,
      totpService: TotpService(),
      clipboardWriter: (text) async {
        clipboardWrites.add(text);
        return true;
      },
      auditSink: (entry) async {
        audits.add(entry);
      },
    );
  });

  tearDown(() async {
    actions.onApprovalRequested = null;
    actions.onApprovalResolved = null;
    await db.close();
  });

  McpPrincipal principal(String id, String nickname) =>
      McpPrincipal(pairingId: id, nickname: nickname);

  McpPrincipal approvalPrincipal() => principal('p-approval', 'approval');
  McpPrincipal trustedPrincipal() => principal('p-trusted', 'trusted');

  /// 等待某个条件成立（并发用例用；不用 sleep 猜时序）。
  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('等待条件超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// 跑一次调用并返回它抛出的 McpToolException（没抛返回 null）。
  Future<McpToolException?> captureToolError(
    Future<Map<String, Object?>> future,
  ) async {
    try {
      await future;
      return null;
    } on McpToolException catch (error) {
      return error;
    }
  }

  /// 并发用例：把异常也当作"结果"收下来，避免 Future.wait 提前中断。
  Future<Object?> settle(Future<Map<String, Object?>> future) async {
    try {
      return await future;
    } catch (error) {
      return error;
    }
  }

  // ─── H1：审批窗口内的事实必须重新校验 ────────────────────

  test('H1：审批期间条目被改成永久拒绝 → 调用被拒且不返回数据', () async {
    var approvals = 0;
    actions.onApprovalRequested = (request) async {
      approvals++;
      final item = await repository.getItem('e-open');
      await repository.saveItem(item!.copyWith(agentOpen: false));
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(approvalPrincipal(), 'get_entry', {'id': 'e-open'}),
    );
    expect(approvals, 1);
    expect(error, isNotNull);
    expect(error!.code, 'denied', reason: 'I-9 硬闸必须在审批后重新生效');
    expect((await repository.getItem('e-open'))!.agentOpen, isFalse);
    expect(
      audits.where((e) => e.tool == 'get_entry').single.decision,
      'denied',
    );
  });

  test('H1：审批期间配对被撤销 → 调用被拒', () async {
    actions.onApprovalRequested = (request) async {
      await pairingStore.revoke('p-approval');
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(approvalPrincipal(), 'get_entry', {'id': 'e-open'}),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
  });

  test('H1：审批期间访问方式被切换 → 调用被拒', () async {
    actions.onApprovalRequested = (request) async {
      final pairing = (await pairingStore.findById('p-approval'))!;
      await pairingStore.save(
        pairing.copyWith(mode: AgentMode.trusted, trusted: true),
      );
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(approvalPrincipal(), 'get_entry', {'id': 'e-open'}),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
  });

  test('H1：审批期间总开关被关闭 → 调用被拒且不执行', () async {
    actions.onApprovalRequested = (request) async {
      await accessStore.setEnabled(false);
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(
        approvalPrincipal(),
        'update_entry',
        {'id': 'e-open', 'notes': 'agent-note'},
      ),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
    expect((await repository.getItem('e-open'))!.notes, '这条备注不能泄露');
  });

  test('H1：审批期间条目进回收站 → update 被拒，且不会被"复活"（POC-6）', () async {
    actions.onApprovalRequested = (request) async {
      await repository.deleteItem('e-open');
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(
        approvalPrincipal(),
        'update_entry',
        {'id': 'e-open', 'notes': 'agent-note'},
      ),
    );
    expect(error, isNotNull);
    expect(error!.code, 'invalidRequest');
    // 库里仍然是"在回收站"，没有被 stale 快照写回 deleted_at=NULL。
    final row = await db.getEntryById('e-open');
    expect(row, isNotNull);
    expect(row!.deletedAt, isNotNull, reason: '回收站状态不能被 update 覆盖');
    expect(await repository.getItem('e-open'), isNull);
  });

  test('H1：审批期间条目被彻底删除 → update 不会把它重新插入（POC-7）', () async {
    actions.onApprovalRequested = (request) async {
      await repository.deleteItem('e-open');
      await repository.permanentlyDeleteItem('e-open');
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(
        approvalPrincipal(),
        'update_entry',
        {'id': 'e-open', 'notes': 'agent-note'},
      ),
    );
    expect(error, isNotNull);
    expect(error!.code, 'notFound');
    expect(await db.getEntryById('e-open'), isNull, reason: '彻底删除不可被 upsert 复活');
  });

  test('H1：审批期间用户改了密码 → agent 局部更新保留用户的新密码（POC-8）', () async {
    actions.onApprovalRequested = (request) async {
      final latest = (await repository.getItem('e-open'))!;
      await repository.saveItem(latest.copyWith(
        login: latest.loginOrEmpty.copyWith(password: 'NEW-user-password'),
        updatedAt: latest.updatedAt + 1,
      ));
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final result = await actions.callTool(
      approvalPrincipal(),
      'update_entry',
      {'id': 'e-open', 'notes': 'agent-note'},
    );
    expect(result['ok'], isTrue);
    final item = (await repository.getItem('e-open'))!;
    expect(item.loginOrEmpty.password, 'NEW-user-password',
        reason: '审批期间的凭据修改不能被旧快照回滚');
    expect(item.notes, 'agent-note');
  });

  test('H1：审批期间条目被改成 SSH 类型 → 类型硬闸仍然拒绝', () async {
    actions.onApprovalRequested = (request) async {
      final latest = (await repository.getItem('e-open'))!;
      await repository.saveItem(latest.copyWith(
        type: EntryType.sshKey,
        login: null,
        sshKey: const SshKeyData(privateKey: 'private'),
      ));
      actions.respondApproval(request['approvalId'] as String, true);
    };

    final error = await captureToolError(
      actions.callTool(approvalPrincipal(), 'get_entry', {'id': 'e-open'}),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
  });

  // ─── H3：agent 域锁定时单条目工具报 locked ───────────────

  test('H3：agent 域锁定时单条目工具明确报 locked，且不弹审批', () async {
    var approvals = 0;
    actions.onApprovalRequested = (request) {
      approvals++;
      scheduleMicrotask(() {
        actions.respondApproval(request['approvalId'] as String, true);
      });
    };
    // ui 可用、agent 域锁（模拟"用户显式锁定智能体会话"）。
    sessions.ui.unlock(Uint8List.fromList(List<int>.filled(32, 9)));
    sessions.agent.lock();

    final cases = <(String, Map<String, Object?>)>[
      ('get_entry', {'id': 'e-open'}),
      ('update_entry', {'id': 'e-open', 'notes': 'x'}),
      ('delete_entry', {'id': 'e-open'}),
      ('restore_entry', {'id': 'e-open'}),
      ('copy_to_clipboard', {'id': 'e-open', 'field': 'password'}),
    ];
    for (final (tool, args) in cases) {
      final error = await captureToolError(
        actions.callTool(approvalPrincipal(), tool, args),
      );
      expect(error, isNotNull, reason: tool);
      expect(error!.code, 'locked', reason: '$tool 必须报 locked 而不是 notFound');
    }
    expect(approvals, 0, reason: '锁定态弹审批也借不到钥匙，不该打扰用户');
    // 库里数据没被任何失败路径改动（用 ui 钥匙读：agent 域此刻锁着）。
    final uiRepository = VaultRepository(
      db: db,
      cryptoService: crypto,
      keyReader: () => sessions.ui.key,
    );
    final item = (await uiRepository.getItem('e-open'))!;
    expect(item.notes, '这条备注不能泄露');
    expect(item.deletedAt, isNull);

    // 对照：list_entries 仍走审批 + 借 ui 钥匙（窗口期合法路径）。
    final listed = await actions.callTool(
      approvalPrincipal(),
      'list_entries',
      <String, Object?>{},
    );
    expect(approvals, 1);
    expect((listed['entries'] as List), isNotEmpty);
    expect(sessions.agent.isUnlocked, isFalse, reason: '借来的钥匙必须用后锁回');
  });

  // ─── H4：免询问 API 语义 ─────────────────────────────────

  test('H4：免询问可授予 / 查询 / 单项撤销 / 全量清空', () async {
    actions.onApprovalRequested = (request) {
      scheduleMicrotask(() {
        actions.respondApproval(
          request['approvalId'] as String,
          true,
          allowStandingRead: true,
        );
      });
    };

    await actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{});
    expect(actions.isStandingRead('p-approval'), isTrue);

    actions.clearStandingRead('p-approval');
    expect(actions.isStandingRead('p-approval'), isFalse);

    await actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{});
    expect(actions.isStandingRead('p-approval'), isTrue);
    actions.clearAllStandingRead();
    expect(actions.isStandingRead('p-approval'), isFalse);
  });

  // ─── H5 / D4：类型硬闸 ─────────────────────────────────

  test('H5：identity / SSH 即使 agentOpen 也不可读 / 不可写 / 不可复制', () async {
    await repository.saveItem(VaultItem(
      id: 'e-ssh',
      type: EntryType.sshKey,
      name: 'prod-key',
      agentOpen: true,
      sshKey: const SshKeyData(
        privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\nSECRET\n',
        passphrase: 'ssh-pass',
      ),
      createdAt: 1,
      updatedAt: 2,
    ));
    await repository.saveItem(VaultItem(
      id: 'e-identity',
      type: EntryType.identity,
      name: '我的身份',
      agentOpen: true,
      identity: const IdentityData(username: 'alice-id'),
      createdAt: 1,
      updatedAt: 2,
    ));

    for (final id in ['e-ssh', 'e-identity']) {
      final read = await captureToolError(
        actions.callTool(trustedPrincipal(), 'get_entry', {'id': id}),
      );
      expect(read, isNotNull, reason: id);
      expect(read!.code, 'denied', reason: '类型硬闸：$id 不可读');

      final updated = await captureToolError(
        actions.callTool(
          trustedPrincipal(),
          'update_entry',
          {'id': id, 'name': '改名尝试'},
        ),
      );
      expect(updated, isNotNull, reason: id);
      expect(updated!.code, 'denied', reason: '类型硬闸：$id 不可写');
    }

    final list = await actions.callTool(
      trustedPrincipal(),
      'list_entries',
      <String, Object?>{},
    );
    final ids = (list['entries'] as List).map((e) => (e as Map)['id']).toSet();
    expect(ids.contains('e-ssh'), isFalse);
    expect(ids.contains('e-identity'), isFalse);

    // 已从工具面移除的字段：服务端在 HTTP/服务层仍拒绝（纵深防御）。
    final copied = await captureToolError(
      actions.callTool(
        trustedPrincipal(),
        'copy_to_clipboard',
        {'id': 'e-ssh', 'field': 'private_key'},
      ),
    );
    expect(copied, isNotNull);
    expect(copied!.code, 'invalidRequest');
    final passwordOnSsh = await captureToolError(
      actions.callTool(
        trustedPrincipal(),
        'copy_to_clipboard',
        {'id': 'e-ssh', 'field': 'password'},
      ),
    );
    expect(passwordOnSsh, isNotNull);
    expect(passwordOnSsh!.code, 'invalidRequest');
    expect(clipboardWrites, isEmpty);
  });

  // ─── H9：审批「详细」完整化 ─────────────────────────────

  test('H9：审批详细展示 old→new / 字段名 / purpose+TTL / 筛选条件', () async {
    final requests = <Map<String, Object?>>[];
    actions.onApprovalRequested = (request) {
      requests.add(request);
      scheduleMicrotask(() {
        actions.respondApproval(request['approvalId'] as String, false);
      });
    };

    await captureToolError(
      actions.callTool(approvalPrincipal(), 'update_entry', {
        'id': 'e-open',
        'url': 'https://evil.example',
        'password': 'new-secret-value',
        'isFavorite': true,
      }),
    );
    final updateDetail = requests.last['detail'] as String;
    expect(updateDetail, contains('https://github.com'));
    expect(updateDetail, contains('https://evil.example'),
        reason: '用户必须能看出 URL 被改成哪里（防凭据投毒）');
    expect(updateDetail, contains('密码：已修改（值不显示）'));
    expect(updateDetail, isNot(contains('new-secret-value')),
        reason: '秘密值绝不能进审批文案');

    await captureToolError(
      actions.callTool(approvalPrincipal(), 'copy_to_clipboard', {
        'id': 'e-open',
        'field': 'notes',
      }),
    );
    expect(requests.last['detail'], contains('复制字段：notes'));

    await captureToolError(
      actions.callTool(approvalPrincipal(), 'begin_session', {
        'purpose': '整理工作区',
        'ttlSeconds': 120,
      }),
    );
    final beginDetail = requests.last['detail'] as String;
    expect(beginDetail, contains('整理工作区'));
    expect(beginDetail, contains('120'));

    await captureToolError(
      actions.callTool(approvalPrincipal(), 'list_entries', {
        'type': 'login',
        'query': 'git',
      }),
    );
    final listDetail = requests.last['detail'] as String;
    expect(listDetail, contains('类型=login'));
    expect(listDetail, contains('git'));
  });

  // ─── M2：审批限流 ──────────────────────────────────────

  test('M2：同一配对最多 3 个 pending 审批，第 4 个立即拒绝且不弹窗', () async {
    final requests = <Map<String, Object?>>[];
    actions.onApprovalRequested = (request) {
      requests.add(request);
    };

    final firstThree = <Future<Object?>>[
      for (var i = 0; i < 3; i++)
        settle(actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{})),
    ];
    await waitUntil(() => requests.length == 3);

    final error = await captureToolError(
      actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{}),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
    expect(requests, hasLength(3), reason: '超限请求不弹窗');

    actions.cancelPendingApprovals();
    final results = await Future.wait(firstThree);
    expect(results.every((r) => r is McpToolException), isTrue);
  });

  test('M2：全局最多 8 个 pending 审批，第 9 个立即拒绝', () async {
    for (final id in ['p-a2', 'p-a3']) {
      await pairingStore.save(AgentPairing(
        id: id,
        nickname: id,
        mode: AgentMode.approval,
        keyHash: AgentPairingStore.hashKey('$id-key'),
        createdAt: 1,
      ));
    }
    final requests = <Map<String, Object?>>[];
    actions.onApprovalRequested = (request) {
      requests.add(request);
    };

    final futures = <Future<Object?>>[];
    for (final id in ['p-approval', 'p-a2', 'p-a3']) {
      final count = id == 'p-a3' ? 2 : 3;
      for (var i = 0; i < count; i++) {
        futures.add(settle(
          actions.callTool(principal(id, id), 'list_entries', <String, Object?>{}),
        ));
      }
    }
    await waitUntil(() => requests.length == 8);

    final ninth = await captureToolError(
      actions.callTool(principal('p-a3', 'p-a3'), 'list_entries', <String, Object?>{}),
    );
    expect(ninth, isNotNull);
    expect(ninth!.code, 'denied');
    expect(requests, hasLength(8));

    actions.cancelPendingApprovals();
    await Future.wait(futures);
  });

  // ─── M4：审计"一次调用一行"与覆盖 ───────────────────────

  test('M4：审批超时按拒绝、只写一行 timeout 审计并广播 resolved', () async {
    // 用更短的超时覆盖关闭路径（生产默认 45s）。
    final shortActions = AgentActions(
      repository: repository,
      sessions: sessions,
      pairingStore: pairingStore,
      agentAccess: accessStore,
      totpService: TotpService(),
      clipboardWriter: (text) async {
        clipboardWrites.add(text);
        return true;
      },
      auditSink: (entry) async {
        audits.add(entry);
      },
      approvalTimeout: const Duration(milliseconds: 40),
    );
    final requests = <Map<String, Object?>>[];
    final resolutions = <String>[];
    shortActions.onApprovalRequested = (request) {
      requests.add(request); // 永不回应 ⇒ 超时
    };
    shortActions.onApprovalResolved = (approvalId, decision) {
      resolutions.add('$approvalId:$decision');
    };

    final error = await captureToolError(
      shortActions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{}),
    );
    expect(error, isNotNull);
    expect(error!.code, 'denied');
    expect(requests, hasLength(1));
    expect(resolutions, hasLength(1));
    expect(resolutions.single.endsWith(':timeout'), isTrue);
    final timeoutRows = audits.where((e) => e.tool == 'list_entries').toList();
    expect(timeoutRows, hasLength(1), reason: '超时只写一行（不写 denied 第二行）');
    expect(timeoutRows.single.decision, 'timeout');
  });

  test('M4：取消挂起审批 → 广播 cancelled，调用只写一行 denied', () async {
    final requests = <Map<String, Object?>>[];
    final resolutions = <String>[];
    actions.onApprovalRequested = (request) => requests.add(request);
    actions.onApprovalResolved = (approvalId, decision) =>
        resolutions.add('$approvalId:$decision');

    final pending = settle(
      actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{}),
    );
    await waitUntil(() => requests.length == 1);
    actions.cancelPendingApprovals();
    final result = await pending;
    expect(result, isA<McpToolException>());
    expect((result! as McpToolException).code, 'denied');
    expect(resolutions.single.endsWith(':cancelled'), isTrue);
    final rows = audits.where((e) => e.tool == 'list_entries').toList();
    expect(rows, hasLength(1));
    expect(rows.single.decision, 'denied');
  });

  test('M4：copy_to_clipboard 审计 op 记字段名，响应不回长度', () async {
    final result = await actions.callTool(
      trustedPrincipal(),
      'copy_to_clipboard',
      {'id': 'e-open', 'field': 'password'},
    );
    expect(result['ok'], isTrue);
    expect(result.containsKey('length'), isFalse);
    final entry = audits.single;
    expect(entry.tool, 'copy_to_clipboard');
    expect(entry.op, 'clipboard:password', reason: '审计必须能看出复制了哪个字段');
    expect(entry.decision, 'allowed');
  });

  test('M4：HTTP 层拒绝写一行未认证审计', () async {
    actions.recordHttpRejection('HTTP 401 unknown_pairing');
    final entry = audits.single;
    expect(entry.pairingId, isEmpty);
    expect(entry.nickname, '未认证');
    expect(entry.mode, 'unknown');
    expect(entry.tool, 'http');
    expect(entry.decision, 'denied');
    expect(entry.entryName, contains('401'));
  });

  test('M4：HTTP 拒绝审计不需要认证上下文，reason 截断到上限', () async {
    actions.recordHttpRejection(List.filled(500, 'x').join());
    expect(audits.single.entryName!.length, lessThanOrEqualTo(201));
  });

  // ─── M7：并发调用的 per-call 状态 ────────────────────────

  test('M7：并发调用各写一行审计，失败调用不会被另一调用吞掉', () async {
    final results = await Future.wait([
      settle(actions.callTool(trustedPrincipal(), 'get_entry', {'id': 'no-such'})),
      settle(actions.callTool(trustedPrincipal(), 'list_entries', <String, Object?>{})),
      settle(actions.callTool(trustedPrincipal(), 'create_entry', {'name': '并发创建'})),
    ]);
    expect(results[0], isA<McpToolException>());
    expect(audits.where((e) => e.tool == 'get_entry'), hasLength(1));
    expect(audits.where((e) => e.tool == 'list_entries'), hasLength(1));
    expect(audits.where((e) => e.tool == 'create_entry'), hasLength(1));
    expect(audits.where((e) => e.tool == 'get_entry').single.decision, 'error');
  });

  test('M7：并发借用 ui 钥匙时，一个调用结束不会把另一个的钥匙锁掉', () async {
    sessions.ui.unlock(Uint8List.fromList(List<int>.filled(32, 9)));
    sessions.agent.lock();
    actions.onApprovalRequested = (request) {
      scheduleMicrotask(() {
        actions.respondApproval(request['approvalId'] as String, true);
      });
    };

    final results = await Future.wait([
      settle(actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{})),
      settle(actions.callTool(approvalPrincipal(), 'list_entries', <String, Object?>{})),
    ]);
    // 两个调用都必须拿到完整结果（不是被中途锁回导致的空列表/异常）。
    for (final result in results) {
      expect(result, isA<Map<String, Object?>>());
      expect(((result! as Map)['entries'] as List), isNotEmpty);
    }
    // 引用计数归零后才锁回。
    expect(sessions.agent.isUnlocked, isFalse);
  });
}
