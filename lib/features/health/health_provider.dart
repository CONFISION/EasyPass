import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/crypto_service.dart';
import '../auth/providers/auth_provider.dart';
import '../vault/providers/vault_provider.dart';
import 'health_service.dart';

/// 密码健康报告 provider。
///
/// 装配流程：从 [vaultEntriesProvider]（加密条目流）读取全部条目，用
/// [encryptionKeyProvider] 中的会话密钥解密，再交给纯函数
/// [HealthService.analyze] 计算 [HealthReport]。
///
/// 安全纪律：明文密码只存在于本函数的局部列表 [decrypted] 中，分析完成后
/// 即被回收；绝不打印、绝不写日志、绝不持久化；报告本身不含任何明文密码。
final healthReportProvider = FutureProvider<HealthReport>((ref) async {
  final entries = await ref.watch(vaultEntriesProvider.future);
  final key = ref.watch(encryptionKeyProvider);
  if (key == null) {
    throw StateError('Vault is locked — cannot analyze health report');
  }

  final crypto = CryptoService();
  final decrypted = <HealthEntry>[
    for (final entry in entries)
      HealthEntry(
        id: entry.id,
        name: entry.name,
        url: entry.url,
        password: _decrypt(entry.passwordEncrypted, key, crypto),
        totpSecret: (entry.totpSecretEncrypted == null ||
                entry.totpSecretEncrypted!.isEmpty)
            ? null
            : _decrypt(entry.totpSecretEncrypted!, key, crypto),
      ),
  ];

  return HealthService.analyze(decrypted);
});

/// 解密失败时返回空串（不抛异常、不打印明文），保证分析流程不中断。
String _decrypt(String ciphertext, Uint8List key, CryptoService crypto) {
  try {
    return crypto.decryptData(ciphertext, key);
  } catch (_) {
    return '';
  }
}
