import 'dart:typed_data';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/models/vault_item_mapper.dart';
import 'package:flutter_test/flutter_test.dart';

/// 智能体可访问性开关（`agent_access`）与第三个会话域。
///
/// 两条最容易静默丢数据的地方就在这里：
/// 1. `EntryPayload.isEmpty` —— 只设了开关、没有其它载荷内容的条目如果被判空，
///    `data_encrypted` 会保持空串，**开关悄悄消失**；
/// 2. `VaultItemMapper.normalize` 的四个类型分支 —— 每个分支都重建一个
///    `VaultItem`，漏传一个字段就等于保存时把开关清掉。
void main() {
  final key = Uint8List.fromList(List<int>.filled(32, 7));
  final mapper = VaultItemMapper(CryptoService(secureStorage: InMemorySecretStore()));

  VaultItem item(EntryType type, {bool agentOpen = false}) => VaultItem(
        id: 'e1',
        folderId: 'f1',
        type: type,
        name: 'GitHub',
        notes: '',
        isFavorite: false,
        agentOpen: agentOpen,
        login: type == EntryType.login ? const LoginData() : null,
        identity: type == EntryType.identity ? IdentityData.empty : null,
        sshKey: type == EntryType.sshKey ? SshKeyData.empty : null,
        createdAt: 1,
        updatedAt: 2,
      );

  group('EntryPayload：只写"开放"，拒绝是默认态', () {
    test('开放 → JSON 里出现 agent_access=open', () {
      final json = const EntryPayload(agentOpen: true).toJson();
      expect(json['agent_access'], 'open');
    });

    test('拒绝 → JSON 里没有这个键（不占字节，旧库无需回填）', () {
      expect(const EntryPayload().toJson().containsKey('agent_access'), isFalse);
    });

    test('fromJson 宽容：只认字面值 open，其它一律拒绝', () {
      expect(EntryPayload.fromJson({'agent_access': 'open'}).agentOpen, isTrue);
      expect(EntryPayload.fromJson({'agent_access': 'denied'}).agentOpen, isFalse);
      expect(EntryPayload.fromJson({'agent_access': true}).agentOpen, isFalse);
      expect(EntryPayload.fromJson({}).agentOpen, isFalse);
      expect(EntryPayload.fromJson(null).agentOpen, isFalse);
    });

    test('陷阱：只有开关的载荷不算空（否则开关不会被写进 data_encrypted）', () {
      expect(const EntryPayload(agentOpen: true).isEmpty, isFalse,
          reason: '判空会让 mapper 跳过写 data_encrypted，开关静默丢失');
      expect(const EntryPayload().isEmpty, isTrue);
    });

    test('加密载荷往返：开关能穿过 encode/decode', () {
      final sealed = mapper.encodePayload(
        const EntryPayload(agentOpen: true),
        key,
      );
      expect(sealed, isNotEmpty,
          reason: '只有开关时也必须真的加密落库，不能是空串');

      final decoded = mapper.decodePayload(sealed, key);
      expect(decoded.agentOpen, isTrue);
    });

    test('拒绝态载荷往返后仍是拒绝', () {
      final sealed = mapper.encodePayload(EntryPayload.empty, key);
      expect(sealed, isEmpty);
      expect(mapper.decodePayload(sealed, key).agentOpen, isFalse);
    });
  });

  group('VaultItem：开关不会被 normalize / copyWith 丢掉', () {
    for (final type in EntryType.values) {
      test('normalize 保留 agentOpen（${type.wireName}）', () {
        final normalized = VaultItemMapper.normalize(item(type, agentOpen: true));
        expect(normalized.agentOpen, isTrue,
            reason: 'normalize 会重建 VaultItem；漏传就等于保存时清掉开关');
      });
    }

    test('copyWith 可改、缺省时保留', () {
      final open = item(EntryType.login, agentOpen: true);
      expect(open.copyWith(name: 'x').agentOpen, isTrue);
      expect(open.copyWith(agentOpen: false).agentOpen, isFalse);
    });

    test('withoutTypeData 保留开关（切类型不该顺手关掉授权）', () {
      expect(item(EntryType.login, agentOpen: true).withoutTypeData().agentOpen,
          isTrue);
    });

    test('明文 JSON 往返：open / denied 都是显值', () {
      final open = item(EntryType.login, agentOpen: true).toJson();
      expect(open['agent_access'], 'open');
      expect(VaultItem.fromJson(open).agentOpen, isTrue);

      final denied = item(EntryType.login).toJson();
      expect(denied['agent_access'], 'denied');
      expect(VaultItem.fromJson(denied).agentOpen, isFalse);
    });

    test('旧导出（没有 agent_access 键）按拒绝处理', () {
      final legacy = item(EntryType.login).toJson()..remove('agent_access');
      expect(VaultItem.fromJson(legacy).agentOpen, isFalse);
    });
  });

  group('SessionDomains：agent 是第三个独立域', () {
    SessionDomains build() =>
        SessionDomains(idleTimeout: const Duration(minutes: 5));

    Uint8List fakeKey([int seed = 0x5A]) =>
        Uint8List.fromList(List<int>.filled(32, seed));

    test('agent 域默认锁定，且与 ui/bridge 是不同的实例', () {
      final domains = build();
      expect(domains.agent.isUnlocked, isFalse);
      expect(identical(domains.agent, domains.ui), isFalse);
      expect(identical(domains.agent, domains.bridge), isFalse);
    });

    test('单独解锁 agent 不影响 ui/bridge（I-3：不入侵 ui 域）', () {
      final domains = build();
      domains.agent.unlock(fakeKey());

      expect(domains.agent.isUnlocked, isTrue);
      expect(domains.ui.isUnlocked, isFalse);
      expect(domains.bridge.isUnlocked, isFalse);
    });

    test('lockAll 不锁 agent 域（智能体访问与 UI 状态解耦）', () {
      final domains = build();
      domains.agent.unlock(fakeKey());
      domains.lockAll();
      expect(domains.agent.isUnlocked, isTrue,
          reason: '用户明确要求：智能体访问一旦授权，不随 UI 锁库而失效');
    });

    test('改空闲超时会同步到 agent 域', () {
      final domains = build();
      domains.setIdleTimeout(const Duration(minutes: 9));
      expect(domains.agent.idleTimeout, const Duration(minutes: 9));
    });

    test('of(agent) 返回同一实例', () {
      final domains = build();
      expect(identical(domains.of(SessionDomain.agent), domains.agent), isTrue);
    });

    test('agent 解锁的广播只报 agent', () {
      final events = <String>[];
      final domains = build();
      domains.onStateChanged =
          (domain, unlocked) => events.add('${domain.name}:$unlocked');

      domains.agent.unlock(fakeKey());

      expect(events, ['agent:true']);
    });
  });
}
