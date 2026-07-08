import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

@DriftDatabase(include: {'tables.drift'})
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
        },
        onUpgrade: (m, from, to) async {},
      );

  // ─── Folders ───────────────────────────────────────────

  Future<List<Folder>> getAllFolders() => select(folders).get();

  Future<Folder?> getFolderById(String id) {
    return (select(folders)..where((t) => t.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertFolder(FoldersCompanion folder) {
    return into(folders).insertOnConflictUpdate(folder);
  }

  Future<void> updateFolder(String id, FoldersCompanion folder) {
    return (update(folders)..where((t) => t.id.equals(id))).write(folder);
  }

  Future<void> deleteFolder(String id) {
    return (delete(folders)..where((t) => t.id.equals(id))).go();
  }

  // ─── Password Entries ──────────────────────────────────

  Future<List<PasswordEntry>> getAllEntries() => select(passwordEntries).get();

  Stream<List<PasswordEntry>> watchAllEntries() {
    return select(passwordEntries).watch();
  }

  /// When [folderId] is null, returns all entries.
  /// When [folderId] is a valid ID, returns only entries in that folder.
  Stream<List<PasswordEntry>> watchEntriesByFolder(String? folderId) {
    final query = select(passwordEntries);
    if (folderId != null) {
      query.where((t) => t.folderId.equals(folderId));
    }
    return query.watch();
  }

  Future<List<PasswordEntry>> searchEntries(String query) {
    final lowerQuery = '%${query.toLowerCase()}%';
    return (select(passwordEntries)
          ..where((t) => t.name.lower().like(lowerQuery) | t.url.lower().like(lowerQuery) | t.username.lower().like(lowerQuery)))
        .get();
  }

  Stream<List<PasswordEntry>> watchFavoriteEntries() {
    return (select(passwordEntries)..where((t) => t.isFavorite.equals(true)))
        .watch();
  }

  Future<PasswordEntry?> getEntryById(String id) {
    return (select(passwordEntries)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<void> insertEntry(PasswordEntriesCompanion entry) {
    return into(passwordEntries).insertOnConflictUpdate(entry);
  }

  Future<void> updateEntry(String id, PasswordEntriesCompanion entry) {
    return (update(passwordEntries)..where((t) => t.id.equals(id))).write(entry);
  }

  Future<void> deleteEntry(String id) {
    return (delete(passwordEntries)..where((t) => t.id.equals(id))).go();
  }

  Future<int> getEntryCount() {
    return (selectOnly(passwordEntries)..addColumns([passwordEntries.id.count()]))
        .map((row) => row.read(passwordEntries.id.count()) ?? 0)
        .getSingle();
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    // Store the database next to the executable
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final file = File(p.join(exeDir, 'easypass.db'));

    return NativeDatabase.createInBackground(file);
  });
}