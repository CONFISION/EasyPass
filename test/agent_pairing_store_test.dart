import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/data/database/database.dart';
import 'package:flutter_test/flutter_test.dart';

/// 配对记录的存取与密钥处理。
///
/// 两条不变量：
/// 1. **密钥永不明文落库**（只存 SHA-256）；
/// 2. 配对记录复用 `vault_meta` 的 `agent.pairing.` 前缀 —— **不新增表**，
///    且坏记录只跳过、不炸整张列表。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late AgentPairingStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = AgentPairingStore(db);
  });

  tearDown(() => db.close());

  AgentPairing sample({
    String id = 'p1',
    AgentMode mode = AgentMode.approval,
    bool trusted = false,
    int? revokedAt,
    int? expiresAt,
  }) {
    return AgentPairing(
      id: id,
      nickname: 'DSH（工作机）',
      mode: mode,
      trusted: trusted,
      keyHash: AgentPairingStore.hashKey('key-$id'),
      createdAt: 100,
      revokedAt: revokedAt,
      expiresAt: expiresAt,
      scopeFolders: const ['f_work'],
      scopeTypes: const ['login'],
    );
  }

  group('密钥生成与哈希', () {
    test('生成 64 位十六进制，且每次不同', () {
      final a = AgentPairingStore.generateKey();
      final b = AgentPairingStore.generateKey();
      expect(a.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
    });

    test('哈希稳定、不同密钥不同哈希', () {
      expect(AgentPairingStore.hashKey('k1'), AgentPairingStore.hashKey('k1'));
      expect(AgentPairingStore.hashKey('k1'), isNot(AgentPairingStore.hashKey('k2')));
      expect(AgentPairingStore.hashKey('k1').length, 64);
    });

    test('keyMatchesHash：正确/错误/空值', () {
      final hash = AgentPairingStore.hashKey('right-key');
      expect(AgentPairingStore.keyMatchesHash('right-key', hash), isTrue);
      expect(AgentPairingStore.keyMatchesHash('wrong-key', hash), isFalse);
      expect(AgentPairingStore.keyMatchesHash('', hash), isFalse);
      expect(AgentPairingStore.keyMatchesHash('right-key', ''), isFalse);
    });
  });

  group('JSON 往返', () {
    test('字段完整往返，含 mode / trusted / scope', () {
      final pairing = sample(mode: AgentMode.trusted, trusted: true);
      final parsed = AgentPairing.tryParse(
        // 经 store 的序列化路径（jsonEncode 在 save 里）。
        '{"id":"p1","nickname":"DSH（工作机）","mode":"trusted","trusted":true,'
        '"keyHash":"${pairing.keyHash}","createdAt":100,"calls":0,'
        '"scopeFolders":["f_work"],"scopeTypes":["login"]}',
      );
      expect(parsed, isNotNull);
      expect(parsed!.id, 'p1');
      expect(parsed.mode, AgentMode.trusted);
      expect(parsed.trusted, isTrue);
      expect(parsed.scopeFolders, ['f_work']);
      expect(parsed.scopeTypes, ['login']);
      expect(parsed.isRevoked, isFalse);
    });

    test('坏记录返回 null（缺 id / 缺 keyHash / 非 JSON）', () {
      expect(AgentPairing.tryParse('not json'), isNull);
      expect(AgentPairing.tryParse('{}'), isNull);
      expect(AgentPairing.tryParse('{"id":"p1"}'), isNull);
      expect(AgentPairing.tryParse('{"keyHash":"abc"}'), isNull);
    });

    test('过期判断', () {
      final expired = sample(expiresAt: 1000);
      expect(expired.isExpiredAt(1001), isTrue);
      expect(expired.isExpiredAt(999), isFalse);
      expect(sample().isExpiredAt(1 << 40), isFalse);
    });
  });

  group('存取（vault_meta，不新增表）', () {
    test('保存后能列出、按 id 找到', () async {
      await store.save(sample());
      final all = await store.list();
      expect(all.length, 1);
      expect(all.first.nickname, 'DSH（工作机）');

      final byId = await store.findById('p1');
      expect(byId, isNotNull);
      expect(byId!.keyHash, AgentPairingStore.hashKey('key-p1'));
    });

    test('按明文密钥查找：对的能找到，错的找不到', () async {
      await store.save(sample());
      expect((await store.findByKey('key-p1'))?.id, 'p1');
      expect(await store.findByKey('key-p2'), isNull);
      expect(await store.findByKey(''), isNull);
    });

    test('撤销写 revokedAt，记录仍保留（审计与昵称要对得上）', () async {
      await store.save(sample());
      await store.revoke('p1', now: 4242);

      final revoked = await store.findById('p1');
      expect(revoked!.isRevoked, isTrue);
      expect(revoked.revokedAt, 4242);
      expect((await store.list()).length, 1);
    });

    test('touch 累加 calls 并刷新 lastUsedAt', () async {
      await store.save(sample());
      await store.touch('p1', now: 555);
      final touched = await store.findById('p1');
      expect(touched!.calls, 1);
      expect(touched.lastUsedAt, 555);
    });

    test('删除后查不到', () async {
      await store.save(sample());
      await store.delete('p1');
      expect(await store.findById('p1'), isNull);
      expect(await store.list(), isEmpty);
    });

    test('坏记录只跳过，不炸整张列表', () async {
      await store.save(sample());
      await db.setMeta('${AgentPairingStore.keyPrefix}broken', 'not json');

      final all = await store.list();
      expect(all.length, 1);
      expect(all.first.id, 'p1');
    });

    test('库里存的确实是哈希，不是明文密钥', () async {
      await store.save(sample());
      final raw = await db.getMeta('${AgentPairingStore.keyPrefix}p1');
      expect(raw, isNotNull);
      expect(raw!.contains('key-p1'), isFalse,
          reason: '明文密钥绝不能落库');
      expect(raw.contains(AgentPairingStore.hashKey('key-p1')), isTrue);
    });
  });
}
