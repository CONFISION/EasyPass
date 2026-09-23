import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/entry_type.dart';
import '../../data/repositories/vault_repository.dart';
import '../auth/providers/auth_provider.dart';
import 'health_service.dart';

/// 密码健康报告 provider。
///
/// 装配流程：从 [vaultRepositoryProvider] 取**登录条目**
/// （`getItems(type: EntryType.login)` —— 安全笔记 / 身份 / SSH 密钥不参与
/// 评分，契约 §5），仓储负责用会话密钥解密，再交给纯函数
/// [HealthService.analyze] 计算 [HealthReport]。
///
/// 安全纪律：明文密码只存在于仓储返回的 [VaultItem] 列表与 analyze 的局部
/// 变量中，分析完成后即被回收；绝不打印、绝不写日志、绝不持久化；
/// 报告本身不含任何明文密码。
///
/// **流式**（2.3.1 修复）：原来是 `FutureProvider`，编辑条目后再打开健康页
/// 看到的仍是上次算出的旧分数。现在监听登录条目，写库即重算。
final healthReportProvider = StreamProvider<HealthReport>((ref) {
  final key = ref.watch(encryptionKeyProvider);
  if (key == null) {
    throw StateError('Vault is locked — cannot analyze health report');
  }

  final repository = ref.watch(vaultRepositoryProvider);
  return repository.watchItems(type: EntryType.login).map(
        (items) => HealthService.analyze([
          for (final item in items) HealthEntry.fromItem(item),
        ]),
      );
});
