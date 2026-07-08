import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/database/database.dart';
import '../../../data/repositories/vault_repository.dart';

// ─── Vault Entries Stream ─────────────────────────────────

final vaultEntriesProvider = StreamProvider<List<PasswordEntry>>((ref) {
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchEntries();
});

/// Filtered by selected folder — the one used in the vault screen
final filteredVaultEntriesProvider = StreamProvider<List<PasswordEntry>>((ref) {
  final folderId = ref.watch(selectedFolderIdProvider);
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchEntriesByFolder(folderId);
});

final vaultFavoritesProvider = StreamProvider<List<PasswordEntry>>((ref) {
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.watchFavorites();
});

// ─── Search ───────────────────────────────────────────────

final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = FutureProvider.family<List<PasswordEntry>, String>(
  (ref, query) async {
    if (query.trim().isEmpty) return [];
    final repo = ref.watch(vaultRepositoryProvider);
    return repo.search(query);
  },
);

// ─── Selected Entry ──────────────────────────────────────

final selectedEntryIdProvider = StateProvider<String?>((ref) => null);

final selectedEntryProvider = FutureProvider.family<PasswordEntry?, String>(
  (ref, id) async {
    final repo = ref.watch(vaultRepositoryProvider);
    return repo.getEntry(id);
  },
);

// ─── Folders ─────────────────────────────────────────────

final foldersProvider = FutureProvider<List<Folder>>((ref) async {
  final repo = ref.watch(vaultRepositoryProvider);
  return repo.getFolders();
});

final selectedFolderIdProvider = StateProvider<String?>((ref) => null);

/// When true, the vault shows only favorites
final showFavoritesProvider = StateProvider<bool>((ref) => false);

/// Resolves the currently selected folder's name for the title bar
final selectedFolderNameProvider = Provider<String?>((ref) {
  final folderId = ref.watch(selectedFolderIdProvider);
  if (folderId == null) return null;
  final folders = ref.watch(foldersProvider).valueOrNull;
  return folders?.firstWhere((f) => f.id == folderId).name;
});
