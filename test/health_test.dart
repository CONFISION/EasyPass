import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/auth/providers/auth_provider.dart';
import 'package:easypass/features/health/health_provider.dart';
import 'package:easypass/features/health/health_service.dart';

import 'fakes.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  // ─── provider 装配（解密 + 分析）────────────────────────

  group('healthReportProvider', () {
    late ProviderContainer container;
    late Uint8List key;

    setUp(() {
      container = ProviderContainer(
        overrides: [
          cryptoServiceProvider.overrideWithValue(
            CryptoService(secureStorage: FakeSecureStorage()),
          ),
          databaseProvider.overrideWithValue(
            AppDatabase.forTesting(NativeDatabase.memory()),
          ),
        ],
      );
      addTearDown(container.dispose);
      key = CryptoService().deriveKey(
        'testmaster',
        CryptoService().generateSalt(),
      );
      container.read(encryptionKeyProvider.notifier).state = key;
    });

    test('解密装配：弱密码/重复密码/无TOTP/无URL 全部识别', () async {
      final repo = container.read(vaultRepositoryProvider);
      final crypto = CryptoService();
      final now = DateTime.now().millisecondsSinceEpoch;

      // a: 常见弱密码 + 无 url + 无 totp
      await repo.saveEntry(PasswordEntriesCompanion.insert(
        id: 'a',
        name: 'SiteA',
        passwordEncrypted: crypto.encryptData('123456', key),
        url: const Value(''),
        totpSecretEncrypted: const Value(''),
        createdAt: now,
        updatedAt: now,
      ));
      // b/c: 共用强密码 + 有 url + 有 totp
      for (final id in ['b', 'c']) {
        await repo.saveEntry(PasswordEntriesCompanion.insert(
          id: id,
          name: 'Site$id',
          passwordEncrypted: crypto.encryptData('Tr0ub4dor&3X!9', key),
          url: Value('https://$id.example.com'),
          totpSecretEncrypted: Value(
            crypto.encryptData('JBSWY3DPEHPK3PXP', key),
          ),
          createdAt: now,
          updatedAt: now,
        ));
      }

      final report = await container.read(healthReportProvider.future);

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

    test('加密字段解密失败时不泄漏明文并继续分析', () async {
      final repo = container.read(vaultRepositoryProvider);
      final now = DateTime.now().millisecondsSinceEpoch;
      // 用错误密钥加密的密码无法解密，按空串处理，不抛异常
      final wrongKey = CryptoService().deriveKey(
        'wrongmaster',
        CryptoService().generateSalt(),
      );
      await repo.saveEntry(PasswordEntriesCompanion.insert(
        id: 'a',
        name: 'SiteA',
        passwordEncrypted: CryptoService().encryptData('123456', wrongKey),
        createdAt: now,
        updatedAt: now,
      ));

      final report = await container.read(healthReportProvider.future);
      expect(report.totalEntries, 1);
      expect(report.weakPasswordCount, 1);
      expect(report.noTotpCount, 1);
      expect(report.noUrlCount, 1);
    });
  });
}
