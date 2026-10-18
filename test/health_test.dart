import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/health/health_provider.dart';
import 'package:easypass/features/health/health_service.dart';

import 'fake_vault_api.dart';

void main() {
  // ─── 纯函数分析逻辑 ────────────────────────────────────

  group('HealthService.analyze - 弱密码', () {
    test('长度不足 12 位判为弱密码', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'short1'),
      ]);
      expect(report.weakPasswordCount, 1);
      expect(report.weakPasswords.single.entryId, 'a');
      expect(report.weakPasswords.single.reason, WeakPasswordReason.tooShort);
    });

    test('纯数字（长度足够）判为单一字符类型弱密码', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: '123456789012'),
      ]);
      expect(report.weakPasswordCount, 1);
      expect(
        report.weakPasswords.single.reason,
        WeakPasswordReason.singleCharType,
      );
    });

    test('纯小写字母判为单一字符类型弱密码', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'abcdefghijkl'),
      ]);
      expect(
        report.weakPasswords.single.reason,
        WeakPasswordReason.singleCharType,
      );
    });

    test('命中常见弱密码列表判为常见弱密码（大小写不敏感）', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: '123456'),
      ]);
      expect(
        report.weakPasswords.single.reason,
        WeakPasswordReason.commonPassword,
      );

      final report2 = HealthService.analyze(const [
        HealthEntry(id: 'b', name: 'B', password: 'Password123'),
      ]);
      expect(
        report2.weakPasswords.single.reason,
        WeakPasswordReason.commonPassword,
      );
    });

    test('常见弱密码列表至少包含 15 个且覆盖要求项', () {
      expect(HealthService.commonPasswords.length, greaterThanOrEqualTo(15));
      expect(
        HealthService.commonPasswords,
        containsAll([
          '123456',
          'password',
          '123456789',
          'qwerty',
          '111111',
          'abc123',
          'password123',
          '12345678',
          '1234567',
          'admin',
          'letmein',
          'welcome',
          'monkey',
          '123123',
          'iloveyou',
        ]),
      );
    });

    test('多类型长密码不判为弱密码', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'Tr0ub4dor&3X!9'),
      ]);
      expect(report.weakPasswordCount, 0);
    });
  });

  group('HealthService.analyze - 重复密码', () {
    HealthEntry healthy(String id, String name, String password) => HealthEntry(
          id: id,
          name: name,
          password: password,
          url: 'https://$id.example.com',
          totpSecret: 'SECRET',
        );

    test('同一明文被多个条目使用时全部列出并去重统计组数', () {
      final report = HealthService.analyze([
        healthy('a', 'SiteA', 'Tr0ub4dor&3X!9'),
        healthy('b', 'SiteB', 'Tr0ub4dor&3X!9'),
        healthy('c', 'SiteC', 'UniquePass!9x'),
      ]);
      expect(report.reusedGroupCount, 1);
      expect(report.reusedEntryCount, 2);
      expect(report.reusedPasswords.map((i) => i.entryId).toSet(), {'a', 'b'});
      for (final issue in report.reusedPasswords) {
        expect(issue.sharedCount, 2);
      }
      // 报告只保留条目 id/name（结构上无 password 字段，不保留明文密码）。
      expect(
        report.reusedPasswords.map((i) => i.entryName).toSet(),
        {'SiteA', 'SiteB'},
      );
    });

    test('多组重复密码分别统计', () {
      final report = HealthService.analyze([
        healthy('a', 'A', 'Tr0ub4dor&3X!9'),
        healthy('b', 'B', 'Tr0ub4dor&3X!9'),
        healthy('c', 'C', 'AnotherStr0ng!pw'),
        healthy('d', 'D', 'AnotherStr0ng!pw'),
        healthy('e', 'E', 'SoloStr0ng!pw'),
      ]);
      expect(report.reusedGroupCount, 2);
      expect(report.reusedEntryCount, 4);
      expect(
        report.reusedPasswords.map((i) => i.entryId).toSet(),
        {'a', 'b', 'c', 'd'},
      );
    });

    test('独有密码不计入重复', () {
      final report = HealthService.analyze([
        healthy('a', 'A', 'Tr0ub4dor&3X!9'),
        healthy('b', 'B', 'AnotherStr0ng!pw'),
      ]);
      expect(report.reusedGroupCount, 0);
      expect(report.reusedEntryCount, 0);
    });
  });

  group('HealthService.analyze - 无 TOTP / 无 URL', () {
    test('totp 为 null 或空判为无两步验证', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'Tr0ub4dor&3X!9'),
        HealthEntry(
          id: 'b',
          name: 'B',
          password: 'Tr0ub4dor&3X!9',
          totpSecret: '',
        ),
      ]);
      expect(report.noTotpCount, 2);
      expect(report.noTotpEntries.map((i) => i.entryId).toSet(), {'a', 'b'});
    });

    test('有 totp 不判为无两步验证', () {
      final report = HealthService.analyze(const [
        HealthEntry(
          id: 'a',
          name: 'A',
          password: 'Tr0ub4dor&3X!9',
          totpSecret: 'JBSWY3DPEHPK3PXP',
        ),
      ]);
      expect(report.noTotpCount, 0);
    });

    test('url 为空判为缺少网址', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'Tr0ub4dor&3X!9'),
        HealthEntry(
          id: 'b',
          name: 'B',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://b.example.com',
        ),
      ]);
      expect(report.noUrlCount, 1);
      expect(report.noUrlEntries.single.entryId, 'a');
    });

    test('url 有值不判为缺少网址', () {
      final report = HealthService.analyze(const [
        HealthEntry(
          id: 'a',
          name: 'A',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://a.example.com',
        ),
      ]);
      expect(report.noUrlCount, 0);
    });
  });

  group('HealthService.analyze - 空库与评分', () {
    test('空库全绿：score=100、level=good、各分类为空', () {
      final report = HealthService.analyze(const []);
      expect(report.totalEntries, 0);
      expect(report.score, 100);
      expect(report.isHealthy, isTrue);
      expect(report.level, HealthLevel.good);
      expect(report.weakPasswordCount, 0);
      expect(report.reusedGroupCount, 0);
      expect(report.noTotpCount, 0);
      expect(report.noUrlCount, 0);
    });

    test('全部健康 = 100', () {
      final report = HealthService.analyze(const [
        HealthEntry(
          id: 'a',
          name: 'A',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://a.example.com',
          totpSecret: 'SECRET',
        ),
      ]);
      expect(report.score, 100);
      expect(report.level, HealthLevel.good);
    });

    test('1 个弱密码 = 90', () {
      final report = HealthService.analyze(const [
        HealthEntry(
          id: 'a',
          name: 'A',
          password: 'short1',
          url: 'https://a.example.com',
          totpSecret: 'SECRET',
        ),
      ]);
      expect(report.score, 90);
    });

    test('1 组重复密码 = 85', () {
      final report = HealthService.analyze([
        const HealthEntry(
          id: 'a',
          name: 'A',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://a.example.com',
          totpSecret: 'SECRET',
        ),
        const HealthEntry(
          id: 'b',
          name: 'B',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://b.example.com',
          totpSecret: 'SECRET',
        ),
      ]);
      expect(report.score, 85);
      expect(report.level, HealthLevel.good);
    });

    test('无 TOTP / 无 URL 每项 -2', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'Tr0ub4dor&3X!9'),
      ]);
      expect(report.score, 96);
    });

    test('弱密码扣分封顶 40', () {
      final entries = [
        for (var i = 0; i < 10; i++)
          HealthEntry(
            id: 'e$i',
            name: 'E$i',
            password: 'short$i',
            url: 'https://e.example.com',
            totpSecret: 'SECRET',
          ),
      ];
      final report = HealthService.analyze(entries);
      expect(report.weakPasswordCount, 10);
      expect(report.score, 60);
    });

    test('扣分封顶后分数不会低于 0', () {
      // 10 个条目、2 组重复密码：弱密码(-40 封顶) + 重复(-30 封顶)
      // + 无TOTP(-20 封顶) + 无URL(-20 封顶) = 110 → 下限 0
      final entries = [
        for (var i = 0; i < 5; i++)
          HealthEntry(id: 'a$i', name: 'A$i', password: 'short1'),
        for (var i = 0; i < 5; i++)
          HealthEntry(id: 'b$i', name: 'B$i', password: 'short2'),
      ];
      final report = HealthService.analyze(entries);
      expect(report.score, 0);
      expect(report.level, HealthLevel.poor);
    });

    test('等级边界：>=80 良好 / >=50 一般 / <50 危险', () {
      HealthEntry healthy(String id, String name, String password) =>
          HealthEntry(
            id: id,
            name: name,
            password: password,
            url: 'https://$id.example.com',
            totpSecret: 'SECRET',
          );

      // good：1 个弱密码 → 90
      final good = HealthService.analyze([
        healthy('a', 'A', 'short'),
      ]);
      expect(good.score, 90);
      expect(good.level, HealthLevel.good);

      // fair：1 个弱密码(-10) + 2 组重复(-30) → 60
      final fair = HealthService.analyze([
        healthy('a', 'A', 'Tr0ub4dor&3X!9'),
        healthy('b', 'B', 'Tr0ub4dor&3X!9'),
        healthy('c', 'C', 'Tr0ub4dor&3X!9'),
        healthy('d', 'D', 'AnotherStr0ng!pw'),
        healthy('e', 'E', 'AnotherStr0ng!pw'),
        healthy('f', 'F', 'short'),
      ]);
      expect(fair.score, 60);
      expect(fair.level, HealthLevel.fair);

      // poor：4 个弱密码(-40) + 1 组重复(-15) → 45
      final poor = HealthService.analyze([
        healthy('a', 'A', 'Tr0ub4dor&3X!9'),
        healthy('b', 'B', 'Tr0ub4dor&3X!9'),
        healthy('c', 'C', 'shortA'),
        healthy('d', 'D', 'shortB'),
        healthy('e', 'E', 'shortC'),
        healthy('f', 'F', 'shortD'),
      ]);
      expect(poor.score, 45);
      expect(poor.level, HealthLevel.poor);
    });
  });

  // ─── 只有登录条目参与评分（2.3.0）────────────────────────

  group('HealthService.analyze - 只有登录条目参与评分', () {
    test('安全笔记 / 身份 / SSH 条目被跳过（防御性第二道闸）', () {
      final report = HealthService.analyze(const [
        HealthEntry(
          id: 'n',
          name: 'Note',
          password: '',
          type: EntryType.secureNote,
        ),
        HealthEntry(
          id: 'i',
          name: 'Identity',
          password: '',
          type: EntryType.identity,
        ),
        HealthEntry(id: 'k', name: 'Key', password: '', type: EntryType.sshKey),
      ]);

      expect(report.totalEntries, 0);
      expect(report.score, 100);
      expect(report.isHealthy, isTrue);
      expect(report.level, HealthLevel.good);
      expect(report.weakPasswords, isEmpty);
      expect(report.reusedPasswords, isEmpty);
      expect(report.reusedGroupCount, 0);
      expect(report.noTotpEntries, isEmpty);
      expect(report.noUrlEntries, isEmpty);
    });

    test('totalEntries 只数登录条目', () {
      final report = HealthService.analyze(const [
        HealthEntry(id: 'a', name: 'A', password: 'Tr0ub4dor&3X!9'),
        HealthEntry(
          id: 'n',
          name: 'N',
          password: '',
          type: EntryType.secureNote,
        ),
      ]);
      expect(report.totalEntries, 1);
    });

    test('HealthEntry.fromItem：登录取登录字段，非登录字段全空', () {
      final login = HealthEntry.fromItem(const VaultItem(
        id: 'a',
        type: EntryType.login,
        name: 'A',
        login: LoginData(
          url: 'https://a.example.com',
          username: 'u',
          password: 'p',
          totpSecret: 'SEC',
        ),
        createdAt: 0,
        updatedAt: 0,
      ));
      expect(login.type, EntryType.login);
      expect(login.url, 'https://a.example.com');
      expect(login.password, 'p');
      expect(login.totpSecret, 'SEC');

      final note = HealthEntry.fromItem(const VaultItem(
        id: 'n',
        type: EntryType.secureNote,
        name: 'N',
        notes: 'body',
        createdAt: 0,
        updatedAt: 0,
      ));
      expect(note.type, EntryType.secureNote);
      expect(note.password, isEmpty);
      expect(note.url, isEmpty);
      expect(note.totpSecret, isNull);
    });
  });

  // ─── provider 装配（经核心取数 + 本地分析）──────────────

  group('healthReportProvider', () {
    late ProviderContainer container;
    late FakeVaultApi api;

    setUp(() {
      api = FakeVaultApi(initialStatus: 'unlocked');
      container = ProviderContainer(
        overrides: [vaultApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      addTearDown(api.dispose);
    });

    VaultItem loginItem({
      required String id,
      required String name,
      required String password,
      String url = '',
      String totpSecret = '',
    }) {
      return VaultItem(
        id: id,
        type: EntryType.login,
        name: name,
        login: LoginData(
          url: url,
          username: 'user-$id',
          password: password,
          totpSecret: totpSecret,
        ),
        createdAt: 0,
        updatedAt: 0,
      );
    }

    /// 三种非登录条目：它们没有密码 / 网址 / TOTP，不该被扣分。
    List<VaultItem> nonLoginItems() => const [
          VaultItem(
            id: 'note-1',
            type: EntryType.secureNote,
            name: 'Recovery codes',
            notes: 'a very long secret note body',
            createdAt: 0,
            updatedAt: 0,
          ),
          VaultItem(
            id: 'identity-1',
            type: EntryType.identity,
            name: 'Passport',
            identity: IdentityData(firstName: 'Ada', idNumber: 'ID-123'),
            createdAt: 0,
            updatedAt: 0,
          ),
          VaultItem(
            id: 'ssh-1',
            type: EntryType.sshKey,
            name: 'Deploy key',
            sshKey: SshKeyData(publicKey: 'ssh-ed25519 AAAA marker@host'),
            createdAt: 0,
            updatedAt: 0,
          ),
        ];

    test('装配：弱密码/重复密码/无TOTP/无URL 全部识别', () async {
      // 只经核心取数（VaultApi），UI 侧不再有数据库句柄。
      // a: 常见弱密码 + 无 url + 无 totp
      await api.saveItem(loginItem(id: 'a', name: 'SiteA', password: '123456'));
      // b/c: 共用强密码 + 有 url + 有 totp
      for (final id in ['b', 'c']) {
        await api.saveItem(loginItem(
          id: id,
          name: 'Site$id',
          password: 'Tr0ub4dor&3X!9',
          url: 'https://$id.example.com',
          totpSecret: 'JBSWY3DPEHPK3PXP',
        ));
      }

      final report = await container.read(healthReportProvider.future);

      expect(api.listItemRequests.last.type, EntryType.login,
          reason: '健康报告只该问核心要登录条目（非登录类型不参与评分）');
      expect(report.totalEntries, 3);
      expect(report.weakPasswordCount, 1);
      expect(report.weakPasswords.single.entryId, 'a');
      expect(
        report.weakPasswords.single.reason,
        WeakPasswordReason.commonPassword,
      );

      expect(report.reusedGroupCount, 1);
      expect(report.reusedEntryCount, 2);
      expect(
        report.reusedPasswords.map((i) => i.entryId).toSet(),
        {'b', 'c'},
      );
      expect(report.reusedPasswords.every((i) => i.sharedCount == 2), isTrue);

      expect(report.noTotpCount, 1);
      expect(report.noTotpEntries.single.entryId, 'a');
      expect(report.noUrlCount, 1);
      expect(report.noUrlEntries.single.entryId, 'a');
    });

    test('核心给回的机密字段是空的（核心里解不开）时按空串分析，不泄漏明文', () async {
      // 解密容错本身是**核心**的职责（`VaultItemMapper` 解不开就按空串处理，
      // 见 vault_repository_items_test.dart）；UI 侧要守的是"空密码照样被识别成
      // 弱密码，报告里不出现任何明文"。
      await api.saveItem(loginItem(
        id: 'a',
        name: 'SiteA',
        // 解不开 → 空串；TOTP 同理 → 按"没有 TOTP"处理。
        password: '',
        totpSecret: '',
      ));

      final report = await container.read(healthReportProvider.future);
      expect(report.totalEntries, 1);
      // 空密码 → 长度不足（弱）+ 无 TOTP + 无 URL
      expect(report.weakPasswordCount, 1);
      expect(report.weakPasswords.single.reason, WeakPasswordReason.tooShort);
      expect(report.noTotpCount, 1);
      expect(report.noUrlCount, 1);
      // 报告里只有 id / 名字 / 统计数字，永远没有密码本身。
      expect(report.weakPasswords.single.entryId, 'a');
    });

    test('只有安全笔记 / 身份 / SSH 的保险库：100 分且各问题列表为空', () async {
      for (final item in nonLoginItems()) {
        await api.saveItem(item);
      }
      // 确认库里真的有 3 条（而不是空库恰好 100 分）
      expect(api.items, hasLength(3));

      final report = await container.read(healthReportProvider.future);

      expect(report.totalEntries, 0);
      expect(report.score, 100);
      expect(report.isHealthy, isTrue);
      expect(report.level, HealthLevel.good);
      expect(report.weakPasswords, isEmpty);
      expect(report.reusedPasswords, isEmpty);
      expect(report.reusedGroupCount, 0);
      expect(report.noTotpEntries, isEmpty);
      expect(report.noUrlEntries, isEmpty);
    });

    test('混合库只报告登录条目，非登录条目不出现在任何问题列表里', () async {
      // 唯一的登录条目：常见弱密码 + 无 URL + 无 TOTP
      await api.saveItem(
        loginItem(id: 'login-1', name: 'GitHub', password: '123456'),
      );
      for (final item in nonLoginItems()) {
        await api.saveItem(item);
      }
      expect(api.items, hasLength(4));

      final report = await container.read(healthReportProvider.future);

      expect(report.totalEntries, 1);
      expect(report.weakPasswordCount, 1);
      expect(report.weakPasswords.single.entryId, 'login-1');
      expect(report.noTotpCount, 1);
      expect(report.noTotpEntries.single.entryId, 'login-1');
      expect(report.noUrlCount, 1);
      expect(report.noUrlEntries.single.entryId, 'login-1');
      expect(report.reusedPasswords, isEmpty);
      // 100 - 10（弱密码）- 2（无 TOTP）- 2（无 URL）
      expect(report.score, 86);
    });

    test('未解锁：空报告（不是异常，也不是"假装满分"）', () async {
      await api.saveItem(loginItem(id: 'a', name: 'SiteA', password: '123456'));
      api.lockEnforcedReads = true;
      api.forceStatus('locked');

      final report = await container.read(healthReportProvider.future);

      // 核心抛 locked ⇒ 当成"没有可分析的条目"，不把健康页打成红屏。
      expect(report.totalEntries, 0, reason: '锁定时不该把 1 条登录条目算进去');
      expect(report.weakPasswords, isEmpty);
      expect(report.score, 100,
          reason: '空报告就是 0 条 / 100 分；旧实现是抛 StateError 让整页报错');

      // 结束前显式 dispose：未解锁时流在轮询会话状态，留着定时器会让测试
      // 在"还有后台任务"的状态下结束（dispose 是幂等的，tearDown 再调一次无害）。
      container.dispose();
    });
  });
}
