import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';

/// Handles Native Messaging communication with the browser extension
/// via stdin/stdout JSON protocol.
///
/// The host runs inside the desktop app process (`easypass.exe --native-host`,
/// see [main.dart]), sharing the same database file and secure storage. The
/// vault stays locked until the user sends an `unlock` action with the master
/// password; the derived key is kept in memory only for the host session.
class NativeMessagingService {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  bool _running = false;

  /// Session AES key derived from the master password on `unlock`.
  /// Null while the vault is locked; cleared on `lock`/disconnect.
  Uint8List? _sessionKey;

  NativeMessagingService(this._db, this._cryptoService, this._totpService);

  bool get isUnlocked => _sessionKey != null;

  /// Start the native messaging host listening on stdin
  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Read 4-byte length prefix, then the message
    while (_running) {
      try {
        final lengthBytes = await stdin.first;
        if (lengthBytes.length < 4) break;

        final length = (lengthBytes[0] & 0xff) |
            ((lengthBytes[1] & 0xff) << 8) |
            ((lengthBytes[2] & 0xff) << 16) |
            ((lengthBytes[3] & 0xff) << 24);

        final messageBytes = await stdin.first;
        while (messageBytes.length < length) {
          final remaining = await stdin.first;
          messageBytes.addAll(remaining);
        }

        final message = utf8.decode(messageBytes.sublist(0, length));
        final response =
            await handleRequest(jsonDecode(message) as Map<String, dynamic>);

        _sendResponse(response);
      } catch (e) {
        if (!_running) break;
        _sendResponse({'error': e.toString()});
      }
    }
  }

  void stop() {
    _running = false;
    _sessionKey = null;
  }

  /// Send a JSON response to the browser extension
  void _sendResponse(Map<String, dynamic> response) {
    final json = jsonEncode(response);
    final bytes = utf8.encode(json);
    final length = bytes.length;

    final header = Uint8List(4);
    header[0] = length & 0xff;
    header[1] = (length >> 8) & 0xff;
    header[2] = (length >> 16) & 0xff;
    header[3] = (length >> 24) & 0xff;

    stdout.add(header);
    stdout.add(bytes);
  }

  /// Handle a single incoming message from the browser extension.
  /// Public so the protocol can be unit-tested without a real stdin/stdout.
  Future<Map<String, dynamic>> handleRequest(Map<String, dynamic> message) async {
    final requestId = message['requestId'] as String?;
    final action = message['action'] as String?;
    final baseResponse = <String, dynamic>{'requestId': requestId};

    try {
      switch (action) {
        case 'getCredentials':
          return baseResponse
            ..['data'] = await _getCredentials(message['url'] as String?);

        case 'getAllCredentials':
          return baseResponse..['data'] = await _getAllCredentials();

        case 'searchCredentials':
          return baseResponse
            ..['data'] =
                await _searchCredentials(message['query'] as String? ?? '');

        case 'getStatus':
          return baseResponse..['data'] = await _getStatus();

        case 'unlock':
          return baseResponse
            ..['data'] = await _unlock(message['password'] as String? ?? '');

        case 'lock':
          _sessionKey = null;
          return baseResponse..['data'] = {'success': true};

        case 'generatePassword':
          return baseResponse
            ..['data'] =
                _generatePassword(message['options'] as Map<String, dynamic>?);

        case 'getTotp':
          return baseResponse
            ..['data'] = await _getTotp(message['entryId'] as String? ?? '');

        default:
          return baseResponse..['error'] = 'Unknown action: $action';
      }
    } catch (e) {
      return baseResponse..['error'] = e.toString();
    }
  }

  // ─── Action Handlers ────────────────────────────────────

  Future<List<Map<String, dynamic>>> _getCredentials(String? url) async {
    _requireUnlocked();
    if (url == null || url.isEmpty) {
      return await _getAllCredentials();
    }

    final entries = await _db.searchEntries(url);
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<List<Map<String, dynamic>>> _getAllCredentials() async {
    _requireUnlocked();
    final entries = await _db.getAllEntries();
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<List<Map<String, dynamic>>> _searchCredentials(String query) async {
    _requireUnlocked();
    if (query.isEmpty) return await _getAllCredentials();
    final entries = await _db.searchEntries(query);
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<Map<String, dynamic>> _getStatus() async {
    final count = await _db.getEntryCount();
    return {
      'connected': true,
      'locked': !isUnlocked,
      'entryCount': count,
    };
  }

  Future<Map<String, dynamic>> _unlock(String password) async {
    final storedSalt = await _cryptoService.getStoredSalt();
    final storedHash = await _cryptoService.getStoredPasswordHash();

    if (storedSalt == null || storedHash == null) {
      throw Exception('No master password configured');
    }

    final computedHash =
        _cryptoService.hashMasterPassword(password, storedSalt);
    if (computedHash == storedHash) {
      // Derive and keep the session key so credential fields can be
      // decrypted. The key lives in memory only for this host session.
      _sessionKey = _cryptoService.deriveKey(password, storedSalt);
      return {'success': true};
    }
    throw Exception('Incorrect master password');
  }

  Map<String, dynamic> _generatePassword(Map<String, dynamic>? options) {
    final length = options?['length'] as int? ?? 16;
    final useUpper = options?['useUpper'] as bool? ?? true;
    final useLower = options?['useLower'] as bool? ?? true;
    final useNumbers = options?['useNumbers'] as bool? ?? true;
    final useSymbols = options?['useSymbols'] as bool? ?? true;

    final random = Random.secure();
    final charSets = <String>[];

    if (useUpper) charSets.add('ABCDEFGHIJKLMNOPQRSTUVWXYZ');
    if (useLower) charSets.add('abcdefghijklmnopqrstuvwxyz');
    if (useNumbers) charSets.add('0123456789');
    if (useSymbols) charSets.add('!@#\$%^&*()-_=+[]{}|;:,.<>?');

    if (charSets.isEmpty) return {'password': ''};

    final allChars = charSets.join();
    final buffer = StringBuffer();
    for (final set in charSets) {
      buffer.write(set[random.nextInt(set.length)]);
    }
    while (buffer.length < length) {
      buffer.write(allChars[random.nextInt(allChars.length)]);
    }
    final chars = buffer.toString().split('')..shuffle(random);

    return {'password': chars.join()};
  }

  Future<Map<String, dynamic>> _getTotp(String entryId) async {
    _requireUnlocked();
    final entry = await _db.getEntryById(entryId);
    if (entry == null || (entry.totpSecretEncrypted ?? '').isEmpty) {
      throw Exception('No TOTP secret configured for this entry');
    }
    final secret = _decrypt(entry.totpSecretEncrypted);
    final totp = _totpService.generateTotp(secret);
    final remaining = _totpService.getRemainingSeconds();
    return {'totp': totp, 'remaining': remaining};
  }

  // ─── Helpers ────────────────────────────────────────────

  void _requireUnlocked() {
    if (_sessionKey == null) {
      throw Exception('Vault is locked');
    }
  }

  /// Decrypt a stored field with the session key. Empty/null stays empty.
  String _decrypt(String? encrypted) {
    if (encrypted == null || encrypted.isEmpty) return '';
    return _cryptoService.decryptData(encrypted, _sessionKey!);
  }

  Map<String, dynamic> _entryToJson(PasswordEntry entry) {
    _requireUnlocked();
    return {
      'id': entry.id,
      'name': entry.name,
      'url': entry.url,
      'username': entry.username,
      'password': _decrypt(entry.passwordEncrypted),
      'notes': _decrypt(entry.notesEncrypted),
      'totp': _decrypt(entry.totpSecretEncrypted),
      'isFavorite': entry.isFavorite,
    };
  }
}
