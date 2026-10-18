import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../client/api_providers.dart';
import '../../../client/vault_api.dart';
import '../../../data/models/entry_type.dart';
import '../../../data/models/vault_item.dart';
import '../../../protocol/codecs.dart' show WireFolder;

/// 未解锁时轮询会话状态的间隔（见 [coreSnapshotStream] 的说明）。
///
/// 只在"锁着"的时候跑：解锁之后完全由核心的主题推送驱动，没有定时器。
const Duration lockedPollInterval = Duration(seconds: 1);

/// 一次快照读取的结果：[value] 交给 UI，[locked] 表示读的时候核心处于锁定态。
typedef CoreSnapshot<T> = ({T value, bool locked});

/// 把 [VaultApi] 的一次性读取包成 UI 的流式 provider：**取快照 + 订阅主题重取**。
///
/// 核心只推"变更通知 + 主题"，不推数据（见 `lib/protocol/events.dart`），所以
/// 每条旧的 drift 流（`watchItems` / `watchItem` / `watchFolders` /
/// `watchSearch`）在 UI 侧都变成"收到对应主题 → 重取一次快照"。
///
/// 两个必须显式处理的状态：
/// - **未解锁**：`listItems` 之类会抛 `VaultApiException(code: locked)`。
///   这里降级成 [lockedValue]（空列表 / null），绝不冒泡成红屏；同时低频轮询
///   `authSnapshot()`，一旦解锁立刻重取。核心的 `sessionUnlocked` /
///   `sessionLocked` 事件**没有**经 UI 通道转发，所以解锁这件事目前没有推送可用
///   —— 这是 `CoreSession` 的接口缺口，轮询是这一轮的权宜处理。
/// - **锁了又解**：同上，轮询把数据接回来；期间到达的主题事件不会丢。
///
/// 别的异常（核心起不来、协议不匹配…）照旧冒泡成 `AsyncError`，让界面显示
/// 失败 + 重试，而不是伪装成"空保险库"。
///
/// 主题订阅直接读 [VaultApi.changes]（与 `coreChangesProvider` 同一条广播流），
/// 不走 `StreamProvider.stream`：那个 getter 在 Riverpod 2.6 已标 deprecated，
/// 而且它包出来的是 `AsyncValue`，连续两个相同主题会被去重掉 —— 那正好是
/// "连写两次只刷新一次"的幽灵 bug。
Stream<T> coreSnapshotStream<T>(
  Ref ref, {
  required String topic,
  required Future<CoreSnapshot<T>> Function(VaultApi api) fetch,
  required T lockedValue,
}) {
  final api = ref.watch(vaultApiProvider);

  // 单订阅控制器 + 全程只订阅一次：重取期间到达的主题事件会被缓存下来，
  // 触发下一轮重取（不会像 broadcast 那样在"没人在听"的窗口里丢掉）。
  final triggers = StreamController<void>();
  var disposed = false;
  Timer? pollTimer;
  Completer<void>? pollWaiter;
  final subscription = api.changes.listen((changed) {
    if (!disposed && changed == topic) triggers.add(null);
  });
  ref.onDispose(() {
    disposed = true;
    subscription.cancel();
    triggers.close();
    // 轮询用的 Timer 必须显式取消：`Future.delayed` 留下的定时器在 widget
    // 测试里会以 "A Timer is still pending" 直接判失败，真机上也是白烧一轮。
    pollTimer?.cancel();
    if (pollWaiter case final waiter? when !waiter.isCompleted) {
      waiter.complete();
    }
  });

  /// 可取消的等待（[lockedPollInterval]）。
  Future<void> pollDelay() {
    final waiter = Completer<void>();
    pollWaiter = waiter;
    pollTimer = Timer(lockedPollInterval, () {
      if (!waiter.isCompleted) waiter.complete();
    });
    return waiter.future;
  }

  /// 未解锁时轮询会话状态；返回 true = 已解锁（可以重取），false = 已经销毁。
  Future<bool> waitUntilUnlocked() async {
    while (!disposed) {
      await pollDelay();
      if (disposed) return false;
      try {
        if ((await api.authSnapshot()).isUnlocked) return true;
      } on VaultApiException {
        // 核心暂时不可达（还没起来 / 正在重启）：下一轮再试。
      }
    }
    return false;
  }

  return () async* {
    // 连续两次拿到"完全相同"的值就不再往下游推：未解锁时的空列表是 const 实例，
    // 每次都推会白白重建界面（widget 测试里还会让 pumpAndSettle 等不到头）。
    // 只去重"同一个实例"：重新取回的新列表是不同实例，照常推。
    var snapshot = await fetch(api);
    var lastValue = snapshot.value;
    yield snapshot.value;

    // 锁着时先把数据等回来，再进入"主题推送 → 重取"的稳态。
    while (snapshot.locked) {
      if (!await waitUntilUnlocked()) return;
      snapshot = await fetch(api);
      if (!identical(snapshot.value, lastValue)) {
        lastValue = snapshot.value;
        yield snapshot.value;
      }
    }

    await for (final _ in triggers.stream) {
      snapshot = await fetch(api);
      if (!identical(snapshot.value, lastValue)) {
        lastValue = snapshot.value;
        yield snapshot.value;
      }
      // 会话可能在两次主题之间就锁上了：重新走等待解锁的分支。
      while (snapshot.locked) {
        if (!await waitUntilUnlocked()) return;
        snapshot = await fetch(api);
        if (!identical(snapshot.value, lastValue)) {
          lastValue = snapshot.value;
          yield snapshot.value;
        }
      }
    }
  }();
}

/// `listItems` 的流式快照读取；未解锁 → 空列表 + `locked`。
Future<CoreSnapshot<List<VaultItem>>> fetchItems(
  VaultApi api, {
  String? folderId,
  EntryType? type,
  bool favoritesOnly = false,
}) async {
  try {
    final items = await api.listItems(
      folderId: folderId,
      type: type,
      favoritesOnly: favoritesOnly,
    );
    return (value: items, locked: false);
  } on VaultApiException catch (error) {
    if (error.isLocked) return (value: const <VaultItem>[], locked: true);
    rethrow;
  }
}

/// `searchItems` 的流式快照读取；未解锁 → 空列表 + `locked`。
Future<CoreSnapshot<List<VaultItem>>> fetchSearch(
  VaultApi api,
  String query,
) async {
  try {
    return (value: await api.searchItems(query), locked: false);
  } on VaultApiException catch (error) {
    if (error.isLocked) return (value: const <VaultItem>[], locked: true);
    rethrow;
  }
}

/// `getItem` 的流式快照读取；未解锁 / 不存在 → null。
Future<CoreSnapshot<VaultItem?>> fetchItem(VaultApi api, String id) async {
  try {
    return (value: await api.getItem(id), locked: false);
  } on VaultApiException catch (error) {
    if (error.isLocked) return (value: null, locked: true);
    rethrow;
  }
}

/// `listFolders` 的流式快照读取；未解锁 → 空列表 + `locked`。
Future<CoreSnapshot<List<WireFolder>>> fetchFolders(VaultApi api) async {
  try {
    return (value: await api.listFolders(), locked: false);
  } on VaultApiException catch (error) {
    if (error.isLocked) return (value: const <WireFolder>[], locked: true);
    rethrow;
  }
}
