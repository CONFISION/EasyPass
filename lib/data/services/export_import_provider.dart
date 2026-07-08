import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/providers/auth_provider.dart';
import '../repositories/vault_repository.dart';
import 'export_import_service.dart';

final exportImportServiceProvider = Provider<ExportImportService>((ref) {
  final db = ref.watch(databaseProvider);
  return ExportImportService(
    db,
    () => ref.read(encryptionKeyProvider) ??
        (throw Exception('Vault is locked')),
  );
});