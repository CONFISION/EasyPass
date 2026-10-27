import 'dart:convert';

import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/codecs.dart';
import 'package:flutter_test/flutter_test.dart';

/// 智能体授权判定（§7.3）与智能体视图编解码器。
///
/// 这一层是最该被测试压死的地方 —— 两个真实先例（Asana 跨租户、
/// Supabase MCP 外泄）都不是"权限被攻破"，而是**授权本身放行了**。
void main() {
  AgentAccessRequest req({
    AgentOp op = AgentOp.read,
    bool entryOpen = true,
    bool revoked = false,
    bool expired = false,
    bool keyMatches = true,
    bool sessionUnlocked = true,
    bool inScope = true,
    bool opAllowed = true,
    AgentMode mode = AgentMode.approval,
    bool trusted = false,
    bool approvedThisCall = false,
    bool standingRead = false,
  }) {
    return AgentAccessRequest(
      op: op,
      entryOpen: entryOpen,
      revoked: revoked,
      expired: expired,
      keyMatches: keyMatches,
      sessionUnlocked: sessionUnlocked,
      inScope: inScope,
      opAllowed: opAllowed,
      mode: mode,
      trusted: trusted,
      approvedThisCall: approvedThisCall,
      standingRead: standingRead,
    );
  }

  group('I-9：条目开关是硬闸，先于一切', () {
    test('条目永久拒绝时，可信直通 + 已同意也拿不到允许', () {
      final result = AgentAccessPolicy.evaluate(req(
        entryOpen: false,
        mode: AgentMode.trusted,
        trusted: true,
        approvedThisCall: true,
      ));
      expect(result.allowed, isFalse);
      expect(result.reason, AgentDenyReason.entryClosed);
    });

    test('条目永久拒绝时，写/删同样拒绝', () {
      for (final op in [AgentOp.write, AgentOp.delete, AgentOp.sensitiveRead]) {
        expect(
          AgentAccessPolicy.evaluate(req(op: op, entryOpen: false, approvedThisCall: true))
              .reason,
          AgentDenyReason.entryClosed,
        );
      }
    });

    test('顺序：entryClosed 先于 pairingRevoked', () {
      expect(
        AgentAccessPolicy.evaluate(req(entryOpen: false, revoked: true)).reason,
        AgentDenyReason.entryClosed,
      );
    });
  });

  group('配对身份与会话（顺序在范围之前）', () {
    test('撤销 / 过期 / 密钥不符 / 会话已锁 各自的原因', () {
      expect(AgentAccessPolicy.evaluate(req(revoked: true)).reason,
          AgentDenyReason.pairingRevoked);
      expect(AgentAccessPolicy.evaluate(req(expired: true)).reason,
          AgentDenyReason.pairingExpired);
      expect(AgentAccessPolicy.evaluate(req(keyMatches: false)).reason,
          AgentDenyReason.keyRejected);
      expect(AgentAccessPolicy.evaluate(req(sessionUnlocked: false)).reason,
          AgentDenyReason.sessionLocked);
    });

    test('会话已锁时，即使本条已获同意也拒绝', () {
      expect(
        AgentAccessPolicy.evaluate(req(sessionUnlocked: false, approvedThisCall: true))
            .reason,
        AgentDenyReason.sessionLocked,
      );
    });

    test('范围外 / 操作类型不允许', () {
      expect(AgentAccessPolicy.evaluate(req(inScope: false)).reason,
          AgentDenyReason.outOfScope);
      expect(AgentAccessPolicy.evaluate(req(opAllowed: false)).reason,
          AgentDenyReason.opNotAllowed);
    });
  });

  group('方式 2：可信直通', () {
    test('未认证可信 ⇒ 拒绝', () {
      expect(
        AgentAccessPolicy.evaluate(req(mode: AgentMode.trusted)).reason,
        AgentDenyReason.notTrusted,
      );
    });

    test('已认证可信 ⇒ 放行（不要求逐次同意）', () {
      final result = AgentAccessPolicy.evaluate(
        req(mode: AgentMode.trusted, trusted: true, op: AgentOp.write),
      );
      expect(result.allowed, isTrue);
      expect(result.standing, isFalse);
    });

    test('可信也要先过条目开关（见上一组）', () {
      expect(
        AgentAccessPolicy.evaluate(
          req(mode: AgentMode.trusted, trusted: true, entryOpen: false),
        ).reason,
        AgentDenyReason.entryClosed,
      );
    });
  });

  group('方式 1：逐次审批 +「本会话内允许读取」', () {
    test('读未同意 ⇒ 拒绝', () {
      expect(AgentAccessPolicy.evaluate(req()).reason, AgentDenyReason.notApproved);
    });

    test('读已同意 ⇒ 放行', () {
      expect(AgentAccessPolicy.evaluate(req(approvedThisCall: true)).allowed, isTrue);
    });

    test('读靠免询问放行 ⇒ 标记 standing', () {
      final result = AgentAccessPolicy.evaluate(req(standingRead: true));
      expect(result.allowed, isTrue);
      expect(result.standing, isTrue);
    });

    test('**敏感读不享受免询问**（关键：否则免询问成了绕过审批的后门）', () {
      final result = AgentAccessPolicy.evaluate(
        req(op: AgentOp.sensitiveRead, standingRead: true),
      );
      expect(result.allowed, isFalse);
      expect(result.reason, AgentDenyReason.notApproved);
    });

    test('写 / 删也不享受免询问', () {
      for (final op in [AgentOp.write, AgentOp.delete]) {
        expect(
          AgentAccessPolicy.evaluate(req(op: op, standingRead: true)).reason,
          AgentDenyReason.notApproved,
        );
      }
    });

    test('写 / 删经同意后放行', () {
      for (final op in [AgentOp.write, AgentOp.delete]) {
        expect(
          AgentAccessPolicy.evaluate(req(op: op, approvedThisCall: true)).allowed,
          isTrue,
        );
      }
    });

    test('免询问不能绕过撤销 / 锁定', () {
      expect(AgentAccessPolicy.evaluate(req(standingRead: true, revoked: true)).reason,
          AgentDenyReason.pairingRevoked);
      expect(
        AgentAccessPolicy.evaluate(req(standingRead: true, sessionUnlocked: false))
            .reason,
        AgentDenyReason.sessionLocked,
      );
    });
  });

  group('entryToAgentJson：只给元数据，绝不带秘密', () {
    const password = 'S3cr3t-P@ssw0rd';
    const totpSecret = 'JBSWY3DPEHPK3PXP';
    const notes = '这是安全笔记正文，绝不能给智能体';
    const hiddenValue = 'hidden-value-must-not-leak';
    const sshPrivate = '-----BEGIN OPENSSH PRIVATE KEY-----';

    VaultItem loginItem() => VaultItem(
          id: 'e1',
          folderId: 'f1',
          type: EntryType.login,
          name: 'GitHub',
          notes: notes,
          isFavorite: true,
          login: const LoginData(
            url: 'https://github.com',
            username: 'alice',
            password: password,
            totpSecret: totpSecret,
          ),
          customFields: const [
            CustomField(label: '恢复码', value: hiddenValue, type: CustomFieldType.hidden),
          ],
          createdAt: 1,
          updatedAt: 2,
        );

    test('登录条目：元数据齐全，四个秘密一个都不出现', () {
      final json = entryToAgentJson(loginItem());
      final encoded = jsonEncode(json);

      expect(json['id'], 'e1');
      expect(json['name'], 'GitHub');
      expect(json['type'], 'login');
      expect(json['url'], 'https://github.com');
      expect(json['username'], 'alice');
      expect(json['hasPassword'], isTrue);
      expect(json['hasTotp'], isTrue);
      expect(json['isFavorite'], isTrue);

      for (final secret in [password, totpSecret, notes, hiddenValue]) {
        expect(encoded.contains(secret), isFalse, reason: '不得泄露 $secret');
      }
      expect(json.containsKey('password'), isFalse);
      expect(json.containsKey('notes'), isFalse);
      expect(json.containsKey('custom_fields'), isFalse);
    });

    test('文件夹：缺省回退 id，传了名称就用名称', () {
      expect(entryToAgentJson(loginItem())['folder'], 'f1');
      expect(entryToAgentJson(loginItem(), folderName: '工作')['folder'], '工作');
    });

    test('deletedAt 只在显式传入时出现（普通 list_entries 不带回收站时间）', () {
      expect(entryToAgentJson(loginItem()).containsKey('deletedAt'), isFalse);
      expect(
        entryToAgentJson(loginItem(), deletedAt: 1793120000000)['deletedAt'],
        1793120000000,
      );
    });

    test('安全笔记：正文不出现，hasPassword/hasTotp 都是 false', () {
      final json = entryToAgentJson(VaultItem(
        id: 'e2',
        type: EntryType.secureNote,
        name: 'WiFi',
        notes: notes,
        createdAt: 1,
        updatedAt: 2,
      ));
      expect(jsonEncode(json).contains(notes), isFalse);
      expect(json['hasPassword'], isFalse);
      expect(json['hasTotp'], isFalse);
    });

    test('身份条目：username 取身份块里的，url 为空', () {
      final json = entryToAgentJson(VaultItem(
        id: 'e3',
        type: EntryType.identity,
        name: '我',
        identity: const IdentityData(username: 'alice-id', email: 'a@b.c'),
        createdAt: 1,
        updatedAt: 2,
      ));
      expect(json['username'], 'alice-id');
      expect(json['url'], '');
    });

    test('SSH 条目：私钥与口令不出现', () {
      final json = entryToAgentJson(VaultItem(
        id: 'e4',
        type: EntryType.sshKey,
        name: 'deploy key',
        sshKey: const SshKeyData(
          publicKey: 'ssh-ed25519 AAAA comment',
          privateKey: sshPrivate,
          passphrase: 'passphrase-should-not-leak',
          fingerprint: 'SHA256:abc',
        ),
        createdAt: 1,
        updatedAt: 2,
      ));
      final encoded = jsonEncode(json);
      expect(encoded.contains('passphrase-should-not-leak'), isFalse);
      expect(encoded.contains('BEGIN OPENSSH'), isFalse);
      expect(encoded.contains('ssh-ed25519'), isFalse);
    });
  });

  group('precheck：审批前的硬闸预检', () {
    test('条目「永久拒绝」：任何方式都直接拒（连信任直通也一样）', () {
      expect(
        AgentAccessPolicy.precheck(req(entryOpen: false)),
        AgentDenyReason.entryClosed,
      );
      expect(
        AgentAccessPolicy.precheck(
          req(entryOpen: false, mode: AgentMode.trusted, trusted: true),
        ),
        AgentDenyReason.entryClosed,
      );
    });

    test('越界 / 配对失效 / 会话锁定：都该在弹审批之前拒绝', () {
      expect(AgentAccessPolicy.precheck(req(inScope: false)),
          AgentDenyReason.outOfScope);
      expect(AgentAccessPolicy.precheck(req(revoked: true)),
          AgentDenyReason.pairingRevoked);
      expect(AgentAccessPolicy.precheck(req(expired: true)),
          AgentDenyReason.pairingExpired);
      expect(AgentAccessPolicy.precheck(req(sessionUnlocked: false)),
          AgentDenyReason.sessionLocked);
      expect(AgentAccessPolicy.precheck(req(opAllowed: false)),
          AgentDenyReason.opNotAllowed);
    });

    test('开放且合规：返回 null（要不要弹审批交给 _gate）', () {
      expect(AgentAccessPolicy.precheck(req()), isNull);
      expect(
        AgentAccessPolicy.precheck(
          req(op: AgentOp.write, mode: AgentMode.trusted),
        ),
        isNull,
      );
    });
  });
}
