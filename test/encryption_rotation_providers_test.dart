import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/state/session_key.dart';
import 'package:easypass/features/vault/providers/entry_item_provider.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';

import 'fakes.dart';

/// 主密码轮换 × 流式 provider 的交叉回归（lead 维护）。
///
/// 背景（2.3.1 审查时发现）：`VaultRepository.watchItem/watchItems/watchSearch`
/// 是在**创建流的那一刻**抓一把会话密钥的。如果 provider 不监听
/// `encryptionKeyProvider`，改完主密码后这些流会一直用旧钥匙解密 ——
/// 宽容模式不报错，直接把密码/私钥解成空串，用户看到的是"改完主密码全空了"。
///
/// 判定方式刻意**不看 provider 的缓存值**（旧实现里缓存值仍是轮换前的正确数据，
/// 会骗过断言）：这里等的是"轮换之后**新到达**的那次推送"，它必须能解开。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late Uint8List oldKey;
  late Uint8List newKey;

  Future<void> waitUntil(
    bool Function() condition, {
    String reason = '等待条件超时',
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    container = ProviderContainer(overrides: [
      cryptoServiceProvider.overrideWithValue(
        CryptoService(secureStorage: FakeSecureStorage()),
      ),
      databaseProvider.overrideWithValue(
        AppDatabase.forTesting(NativeDatabase.memory()),
      ),
    ]);
    addTearDown(container.dispose);

    final crypto = container.read(cryptoServiceProvider);
    oldKey = crypto.deriveKey('old-master', crypto.generateSalt());
    newKey = crypto.deriveKey('new-master', crypto.generateSalt());
    container.read(encryptionKeyProvider.notifier).state = oldKey;

    await container.read(vaultRepositoryProvider).saveItem(VaultItem(
          id: 'rotate-me',
          type: EntryType.login,
          name: 'Rotate',
          login: const LoginData(
            url: 'https://example.com/rotate',
            username: 'alice',
            password: 'before-pw',
            totpSecret: 'JBSWY3DPEHPK3PXP',
          ),
          customFields: const [
            CustomField(label: 'PIN', value: '4321', type: CustomFieldType.hidden),
          ],
          createdAt: 0,
          updatedAt: 0,
        ));
  });

  /// 轮换：完全照 `AuthNotifier.changeMasterPassword` 的顺序
  /// （先整库重加密，再换会话密钥）。
  Future<void> rotateMasterPassword() async {
    await container
        .read(vaultRepositoryProvider)
        .reencryptAll(oldKey: oldKey, newKey: newKey);
    container.read(encryptionKeyProvider.notifier).state = newKey;
  }

  test('详情流：轮换后新到达的推送能用新钥匙解开（不是空值）', () async {
    final seen = <String?>[];
    final sub = container.listen(entryItemProvider('rotate-me'), (_, next) {
      final item = next.valueOrNull;
      if (item != null) seen.add(item.loginOrEmpty.password);
    });
    addTearDown(sub.close);

    await waitUntil(() => seen.isNotEmpty, reason: '首次推送没来');
    expect(seen.last, 'before-pw');

    await rotateMasterPassword();
    await waitUntil(() => seen.length > 1,
        reason: '轮换后没有任何新推送（流没跟着密钥重建）');

    expect(seen.last, 'before-pw',
        reason: '新推送到手但解成了空串 —— 这就是"用旧钥匙解密"的症状');
  });

  test('列表流与搜索流：轮换后同样自动换钥匙', () async {
    final listPasswords = <String?>[];
    final listSub = container.listen(vaultEntriesProvider, (_, next) {
      final items = next.valueOrNull;
      if (items == null) return;
      final mine = items.where((i) => i.id == 'rotate-me');
      if (mine.isNotEmpty) listPasswords.add(mine.first.loginOrEmpty.password);
    });
    addTearDown(listSub.close);

    final searchPasswords = <String?>[];
    final searchSub = container.listen(searchResultsProvider('rotate'), (_, next) {
      final items = next.valueOrNull;
      if (items == null || items.isEmpty) return;
      searchPasswords.add(items.first.loginOrEmpty.password);
    });
    addTearDown(searchSub.close);

    await waitUntil(() => listPasswords.isNotEmpty && searchPasswords.isNotEmpty);
    expect(listPasswords.last, 'before-pw');
    expect(searchPasswords.last, 'before-pw');

    final listCountBefore = listPasswords.length;
    final searchCountBefore = searchPasswords.length;
    await rotateMasterPassword();

    await waitUntil(() => listPasswords.length > listCountBefore,
        reason: '列表流没跟着密钥重建');
    await waitUntil(() => searchPasswords.length > searchCountBefore,
        reason: '搜索流没跟着密钥重建');

    expect(listPasswords.last, 'before-pw');
    expect(searchPasswords.last, 'before-pw');
  });

  test('锁定（密钥置空）后流会被重建，读出来是空的而不是旧数据', () async {
    final seen = <VaultItem?>[];
    final sub = container.listen(entryItemProvider('rotate-me'), (_, next) {
      if (next.hasValue) seen.add(next.valueOrNull);
    });
    addTearDown(sub.close);

    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last?.loginOrEmpty.password, 'before-pw');

    final countBefore = seen.length;
    container.read(encryptionKeyProvider.notifier).state = null;

    await waitUntil(() => seen.length > countBefore,
        reason: '锁定时流应当重建为"空值"状态');
    expect(seen.last, isNull,
        reason: '锁着的时候不能继续把明文交出去');
  });
}
