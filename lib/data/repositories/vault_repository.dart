import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/crypto/crypto_service.dart';
import '../database/database.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  return AppDatabase();
});

final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});

final vaultRepositoryProvider = Provider<VaultRepository>((ref) {
  final db = ref.watch(databaseProvider);
  final crypto = ref.watch(cryptoServiceProvider);
  return VaultRepository(db: db, cryptoService: crypto);
});

class VaultRepository {
  final AppDatabase db;
  final CryptoService cryptoService;

  VaultRepository({required this.db, required this.cryptoService});

  // ─── Folders ────────────────────────────────────────────

  Future<List<Folder>> getFolders() => db.getAllFolders();

  Future<void> addFolder(FoldersCompanion folder) => db.insertFolder(folder);

  Future<void> removeFolder(String id) => db.deleteFolder(id);

  // ─── Password Entries ──────────────────────────────────

  Stream<List<PasswordEntry>> watchEntries() => db.watchAllEntries();

  Stream<List<PasswordEntry>> watchEntriesByFolder(String? folderId) =>
      db.watchEntriesByFolder(folderId);

  Stream<List<PasswordEntry>> watchFavorites() => db.watchFavoriteEntries();

  Future<List<PasswordEntry>> getAllEntries() => db.getAllEntries();

  Future<List<PasswordEntry>> search(String query) => db.searchEntries(query);

  Future<PasswordEntry?> getEntry(String id) => db.getEntryById(id);

  Future<void> saveEntry(PasswordEntriesCompanion entry) =>
      db.insertEntry(entry);

  Future<void> updateEntry(String id, PasswordEntriesCompanion entry) =>
      db.updateEntry(id, entry);

  Future<void> deleteEntry(String id) => db.deleteEntry(id);
}
