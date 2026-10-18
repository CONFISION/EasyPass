import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core_session.dart';
import 'vault_api.dart';

/// 进程级唯一的 [CoreSession]（连接管理 + 自动重连 + 变更广播）。
final coreSessionProvider = Provider<CoreSession>((ref) {
  final session = CoreSession();
  ref.onDispose(session.dispose);
  return session;
});

/// UI 的数据通道。**UI 层只许通过它读写保险库**，不得再碰 AppDatabase /
/// VaultRepository / encryptionKeyProvider。
final vaultApiProvider = Provider<VaultApi>((ref) {
  return CoreVaultApi(ref.watch(coreSessionProvider));
});

/// 核心推送的数据变更主题流（`items` / `item` / `folders` / `search`）。
///
/// 流式 provider 的写法（"写库即刷新"）：
/// ```dart
/// Stream<List<VaultItem>> watchItems(...) async* {
///   final api = ref.watch(vaultApiProvider);
///   yield await api.listItems(...);
///   await for (final topic in ref.watch(coreChangesProvider.stream)) {
///     if (topic != Topics.items) continue;
///     yield await api.listItems(...);
///   }
/// }
/// ```
final coreChangesProvider = StreamProvider<String>((ref) {
  return ref.watch(coreSessionProvider).changes;
});
