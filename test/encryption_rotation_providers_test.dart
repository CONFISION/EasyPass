import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/client/api_providers.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/features/vault/providers/entry_item_provider.dart';
import 'package:easypass/features/vault/providers/vault_provider.dart';
import 'package:easypass/protocol/events.dart';

import 'fake_vault_api.dart';

/// 核心推送 × 流式 provider 的交叉回归（原 `encryption_rotation_providers_test`）。
///
/// 历史：2.3.1 审查发现 `VaultRepository.watch*` 在**创建流的那一刻**抓一把会话
/// 密钥，provider 不监听密钥变化就会一直用旧钥匙解密 —— 宽容模式不报错，把
/// 密码解成空串，用户看到"改完主密码全空了"。
///
/// M4 之后这条性质换了责任人：**密钥在核心里**，UI 不持有也不解密。UI 侧唯一
/// 要守的就是"核心说数据变了 → 重取快照"，所以本文件的用例改成：
/// 1) 核心推 `item` / `items` / `search` 主题后，详情 / 列表 / 搜索三条流都
///    **自己**重取（不 invalidate），拿到的是核心当前的那份数据；
/// 2) 核心锁定时（`locked`）重取只能得到 null / 空列表，**不允许继续把上一份
///    明文交出去**；解锁后自动恢复。
///
/// 真正的"轮换会换钥匙、旧密码立刻失效"由核心侧测试盯着：
/// `master_password_rotation_atomicity_test.dart`、`change_password_*`。
void main() {
  late FakeVaultApi api;
  late ProviderContainer container;

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

  VaultItem rotateItem({String password = 'before-pw'}) => VaultItem(
        id: 'rotate-me',
        type: EntryType.login,
        name: 'Rotate',
        login: LoginData(
          url: 'https://example.com/rotate',
          username: 'alice',
          password: password,
          totpSecret: 'JBSWY3DPEHPK3PXP',
        ),
        customFields: const [
          CustomField(label: 'PIN', value: '4321', type: CustomFieldType.hidden),
        ],
        createdAt: 0,
        updatedAt: 0,
      );

  setUp(() async {
    api = FakeVaultApi(initialStatus: 'unlocked');
    container = ProviderContainer(
      overrides: [vaultApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    addTearDown(api.dispose);

    await api.saveItem(rotateItem());
  });

  test('详情流：核心推 item 主题后自己重取，拿到的是核心当前的值', () async {
    final seen = <String?>[];
    final sub = container.listen(entryItemProvider('rotate-me'), (_, next) {
      final item = next.valueOrNull;
      if (item != null) seen.add(item.loginOrEmpty.password);
    });
    addTearDown(sub.close);

    await waitUntil(() => seen.isNotEmpty, reason: '首次推送没来');
    expect(seen.last, 'before-pw');

    // 模拟"别处改了这个条目"（编辑页 / 另一个客户端 / 核心侧轮换）：
    // 只碰核心，不 invalidate 任何 provider。
    await api.saveItem(rotateItem(password: 'after-pw'));
    await waitUntil(() => seen.length > 1, reason: '核心推了主题但流没重取');

    expect(seen.last, 'after-pw',
        reason: '重取拿到的必须是核心当前那份（旧实现是"永远用旧钥匙解"）');
  });

  test('列表流与搜索流：核心推主题后同样自动重取', () async {
    final listPasswords = <String?>[];
    final listSub = container.listen(vaultEntriesProvider, (_, next) {
      final items = next.valueOrNull;
      if (items == null) return;
      final mine = items.where((i) => i.id == 'rotate-me');
      if (mine.isNotEmpty) listPasswords.add(mine.first.loginOrEmpty.password);
    });
    addTearDown(listSub.close);

    final searchPasswords = <String?>[];
    final searchSub = container.listen(searchResultsProvider('Rotate'), (_, next) {
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
    await api.saveItem(rotateItem(password: 'after-pw'));

    await waitUntil(() => listPasswords.length > listCountBefore,
        reason: '列表流没跟着主题重取');
    await waitUntil(() => searchPasswords.length > searchCountBefore,
        reason: '搜索流没跟着主题重取');

    expect(listPasswords.last, 'after-pw');
    expect(searchPasswords.last, 'after-pw');
  });

  test('核心锁定时重取只能拿到 null/空，不交出上一份明文；解锁后自动恢复', () async {
    final seen = <VaultItem?>[];
    final sub = container.listen(entryItemProvider('rotate-me'), (_, next) {
      if (next.hasValue) seen.add(next.valueOrNull);
    });
    addTearDown(sub.close);

    await waitUntil(() => seen.isNotEmpty);
    expect(seen.last?.loginOrEmpty.password, 'before-pw');

    // 核心锁了（空闲超时 / 用户点锁定）→ 推一次主题让 UI 重取。
    api.lockEnforcedReads = true;
    api.forceStatus('locked');
    api.emitChange(Topics.item);

    final countBefore = seen.length;
    await waitUntil(() => seen.length > countBefore,
        reason: '核心锁定后流应当重取成"空值"状态');
    expect(seen.last, isNull,
        reason: '锁着的时候不能继续把上一份明文挂在界面上');
    expect(api.getItemRequests, isNotEmpty,
        reason: '重取必须真问核心（由核心决定给不给），而不是 UI 自己猜');

    // 解锁 → 轮询兜底把数据接回来（核心的 sessionUnlocked 事件不经 UI 通道）。
    api.forceStatus('unlocked');
    await waitUntil(
      () => seen.isNotEmpty && seen.last?.loginOrEmpty.password == 'before-pw',
      reason: '解锁后没有自动恢复',
      timeout: const Duration(seconds: 10),
    );
  });
}
