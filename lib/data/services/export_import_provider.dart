import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/auth_provider.dart';
import '../repositories/vault_repository.dart';
import 'export_import_service.dart';

final exportImportServiceProvider = Provider<ExportImportService>((ref) {
  return ExportImportService(
    ref.watch(databaseProvider),
    () => ref.read(encryptionKeyProvider) ??
        (throw Exception('Vault is locked')),
    // 导入导出与 UI 共用同一个仓储：加密 / 解密的口径完全一致。
    repository: ref.watch(vaultRepositoryProvider),
    cryptoService: ref.watch(cryptoServiceProvider),
  );
});
