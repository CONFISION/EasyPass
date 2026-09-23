import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/vault_item.dart';
import '../../../data/repositories/vault_repository.dart';
import '../../../data/state/session_key.dart';

/// 单个条目（表单 / 详情页共用）—— **流式**，任何写操作后自动刷新。
///
/// 为什么必须是 StreamProvider（2.3.1 的 bug 修复）：
/// 详情页原先读一次性 `FutureProvider.family`，provider 会把结果缓存住；
/// 而"编辑条目保存 → 弹回详情页"这条路径上没有人去 `ref.invalidate`，
/// 于是详情页一直显示旧条目 —— 用户新增的自定义字段死活不出现。
/// 改成监听 drift 的单行查询后，写库即推送，"忘记失效"这类 bug 从根上消失。
///
/// 契约不变：未解锁或条目不存在时给 `null`；`.future` 依旧可用。
final entryItemProvider = StreamProvider.family<VaultItem?, String>(
  (ref, id) {
    // 必须 watch 会话密钥：底层 `watchItem` 在**创建流时**抓一把密钥，
    // 改主密码（密钥轮换）或锁定后若不重建流，它会继续用旧钥匙解密 ——
    // 宽容模式把密码解成空串，界面上看起来就是"改完主密码这条空了"。
    ref.watch(encryptionKeyProvider);
    final repository = ref.watch(vaultRepositoryProvider);
    return repository.watchItem(id);
  },
);
