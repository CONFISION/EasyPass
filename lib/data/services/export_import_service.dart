import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:uuid/uuid.dart';

import '../database/database.dart';

/// Handles export and import of password vault data
class ExportImportService {
  final AppDatabase _db;
  final Uint8List Function() _getEncryptionKey;

  ExportImportService(this._db, this._getEncryptionKey);

  /// Export all entries as unencrypted JSON (for user export)
  Future<String> exportToJson() async {
    final entries = await _db.getAllEntries();
    final folders = await _db.getAllFolders();

    final data = {
      'version': '1.0.0',
      'app': 'EasyPass',
      'exported_at': DateTime.now().toIso8601String(),
      'folders': folders
          .map((f) => {
                'id': f.id,
                'name': f.name,
                'icon': f.icon,
                'created_at': f.createdAt,
                'updated_at': f.updatedAt,
              })
          .toList(),
      'entries': entries
          .map((e) => {
                'id': e.id,
                'folder_id': e.folderId,
                'name': e.name,
                'url': e.url,
                'username': e.username,
                'password_encrypted': e.passwordEncrypted,
                'notes_encrypted': e.notesEncrypted,
                'totp_secret_encrypted': e.totpSecretEncrypted,
                'is_favorite': e.isFavorite,
                'created_at': e.createdAt,
                'updated_at': e.updatedAt,
              })
          .toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Export all entries as encrypted JSON
  Future<String> exportEncrypted() async {
    final jsonData = await exportToJson();

    final key = _getEncryptionKey();
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );

    final encrypted = encrypter.encrypt(jsonData, iv: iv);
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);

    final data = {
      'version': '1.0.0',
      'app': 'EasyPass',
      'format': 'encrypted',
      'data': base64Encode(combined),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Import from unencrypted JSON
  Future<Map<String, int>> importFromJson(String jsonContent) async {
    final data = jsonDecode(jsonContent) as Map<String, dynamic>;
    var folderCount = 0;
    var entryCount = 0;

    // Import folders
    if (data['folders'] != null) {
      for (final folderData in data['folders'] as List<dynamic>) {
        final folder = FoldersCompanion.insert(
          id: (folderData['id'] as String?) ?? const Uuid().v4(),
          name: folderData['name'] as String,
          icon: folderData['icon'] != null
              ? Value(folderData['icon'] as String)
              : const Value.absent(),
          createdAt: (folderData['created_at'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _db.insertFolder(folder);
        folderCount++;
      }
    }

    // Import entries
    if (data['entries'] != null) {
      for (final entryData in data['entries'] as List<dynamic>) {
        final entry = PasswordEntriesCompanion.insert(
          id: (entryData['id'] as String?) ?? const Uuid().v4(),
          folderId: entryData['folder_id'] != null
              ? Value(entryData['folder_id'] as String)
              : const Value.absent(),
          name: entryData['name'] as String,
          url: Value(entryData['url'] as String? ?? ''),
          username: Value(entryData['username'] as String? ?? ''),
          passwordEncrypted: entryData['password_encrypted'] as String,
          notesEncrypted: Value(entryData['notes_encrypted'] as String? ?? ''),
          totpSecretEncrypted:
              Value(entryData['totp_secret_encrypted'] as String? ?? ''),
          isFavorite: Value(entryData['is_favorite'] as bool? ?? false),
          createdAt: (entryData['created_at'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _db.insertEntry(entry);
        entryCount++;
      }
    }

    return {'folders': folderCount, 'entries': entryCount};
  }

  /// Write export to a file
  Future<File> writeToFile(String content, String filePath) async {
    final file = File(filePath);
    await file.writeAsString(content);
    return file;
  }

  /// Read import from a file
  Future<String> readFromFile(String filePath) async {
    final file = File(filePath);
    return await file.readAsString();
  }
}