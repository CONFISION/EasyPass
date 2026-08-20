import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:uuid/uuid.dart';

import '../database/database.dart';

/// Handles export and import of password vault data.
///
/// Two export formats are supported:
/// - Plain JSON: sensitive fields are decrypted and written as plaintext
///   (`password`, `notes`, `totp_secret` keys). Meant for the user's own
///   review, not for sharing.
/// - Encrypted JSON: the whole plain JSON payload is AES-256-CBC encrypted
///   with the session key (`format: 'encrypted'`). Recommended for backups.
class ExportImportService {
  final AppDatabase _db;
  final Uint8List Function() _getEncryptionKey;

  ExportImportService(this._db, this._getEncryptionKey);

  /// Export all entries as plain (decrypted) JSON.
  Future<String> exportPlainJson() async {
    final key = _getEncryptionKey();
    final entries = await _db.getAllEntries();
    final folders = await _db.getAllFolders();

    final data = {
      'version': '1.0.0',
      'app': 'EasyPass',
      'format': 'plain',
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
      'entries': entries.map((e) {
        String? decryptField(String? encrypted) {
          if (encrypted == null || encrypted.isEmpty) return '';
          try {
            return _decrypt(encrypted, key);
          } catch (_) {
            return encrypted; // keep raw if it cannot be decrypted
          }
        }

        return {
          'id': e.id,
          'folder_id': e.folderId,
          'name': e.name,
          'url': e.url,
          'username': e.username,
          'password': decryptField(e.passwordEncrypted),
          'notes': decryptField(e.notesEncrypted),
          'totp_secret': decryptField(e.totpSecretEncrypted),
          'is_favorite': e.isFavorite,
          'created_at': e.createdAt,
          'updated_at': e.updatedAt,
        };
      }).toList(),
    };

    return const JsonEncoder.withIndent('  ').convert(data);
  }

  /// Export all entries as encrypted JSON (the backup format).
  Future<String> exportEncrypted() async {
    final jsonData = await exportPlainJson();

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

  /// Import from either a plain JSON export or an encrypted backup.
  /// Returns `{'folders': n, 'entries': m}` counts.
  Future<Map<String, int>> importFromJson(String jsonContent) async {
    final data = jsonDecode(jsonContent) as Map<String, dynamic>;

    if (data['format'] == 'encrypted') {
      final raw = base64Decode(data['data'] as String);
      final key = _getEncryptionKey();
      final ivBytes = raw.sublist(0, 16);
      final cipherBytes = raw.sublist(16);
      final encrypter = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
      );
      final decrypted = encrypter.decrypt(
        encrypt.Encrypted(cipherBytes),
        iv: encrypt.IV(ivBytes),
      );
      return _importPlainJson(jsonDecode(decrypted) as Map<String, dynamic>);
    }

    return _importPlainJson(data);
  }

  Future<Map<String, int>> _importPlainJson(Map<String, dynamic> data) async {
    var folderCount = 0;
    var entryCount = 0;

    // Import folders
    if (data['folders'] != null) {
      for (final folderData in data['folders'] as List<dynamic>) {
        final folder = FoldersCompanion.insert(
          id: (folderData['id'] as String?) ?? const Uuid().v4(),
          name: (folderData['name'] as String?) ?? 'Unnamed Folder',
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

    // Import entries. Accept both the plain keys (password/notes/totp_secret)
    // and the legacy encrypted keys (password_encrypted/notes_encrypted/
    // totp_secret_encrypted) for backwards compatibility.
    if (data['entries'] != null) {
      // Plain exports carry decrypted values under the plain keys; those must
      // be re-encrypted with the session key before persisting. Legacy
      // exports already carry ciphertext under the *_encrypted keys.
      final needsEncryption = (data['entries'] as List<dynamic>).any((e) {
        final map = e as Map<String, dynamic>;
        return map.containsKey('password') ||
            map.containsKey('notes') ||
            map.containsKey('totp_secret');
      });
      final sessionKey = needsEncryption ? _getEncryptionKey() : null;

      for (final entryData in data['entries'] as List<dynamic>) {
        final map = entryData as Map<String, dynamic>;

        String importField(String plainKey, String legacyKey) {
          final plain = map[plainKey] as String?;
          if (plain != null) {
            if (plain.isEmpty || sessionKey == null) return plain;
            try {
              return _encrypt(plain, sessionKey);
            } catch (_) {
              return plain;
            }
          }
          return (map[legacyKey] as String?) ?? '';
        }

        final entry = PasswordEntriesCompanion.insert(
          id: (map['id'] as String?) ?? const Uuid().v4(),
          folderId: map['folder_id'] != null
              ? Value(map['folder_id'] as String)
              : const Value.absent(),
          name: (map['name'] as String?) ?? 'Unnamed Entry',
          url: Value(map['url'] as String? ?? ''),
          username: Value(map['username'] as String? ?? ''),
          passwordEncrypted: importField('password', 'password_encrypted'),
          notesEncrypted: Value(importField('notes', 'notes_encrypted')),
          totpSecretEncrypted:
              Value(importField('totp_secret', 'totp_secret_encrypted')),
          isFavorite: Value(map['is_favorite'] as bool? ?? false),
          createdAt: (map['created_at'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
        await _db.insertEntry(entry);
        entryCount++;
      }
    }

    return {'folders': folderCount, 'entries': entryCount};
  }

  /// Encrypt plaintext in the same format as [CryptoService.encryptData]
  /// (16-byte IV prefix + ciphertext, base64), using the session key.
  String _encrypt(String plaintext, Uint8List key) {
    final iv = encrypt.IV.fromSecureRandom(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    final combined = Uint8List.fromList(iv.bytes + encrypted.bytes);
    return base64Encode(combined);
  }

  String _decrypt(String encryptedBase64, Uint8List key) {
    final combined = base64Decode(encryptedBase64);
    final ivBytes = combined.sublist(0, 16);
    final cipherBytes = combined.sublist(16);
    final encrypter = encrypt.Encrypter(
      encrypt.AES(encrypt.Key(key), mode: encrypt.AESMode.cbc),
    );
    return encrypter.decrypt(
      encrypt.Encrypted(cipherBytes),
      iv: encrypt.IV(ivBytes),
    );
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
