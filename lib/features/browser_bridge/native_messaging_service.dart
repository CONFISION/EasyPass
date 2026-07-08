import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';

/// Handles Native Messaging communication with the browser extension
/// via stdin/stdout JSON protocol
class NativeMessagingService {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  bool _running = false;

  NativeMessagingService(this._db, this._cryptoService, this._totpService);

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
            await _handleMessage(jsonDecode(message) as Map<String, dynamic>);

        _sendResponse(response);
      } catch (e) {
        if (!_running) break;
        _sendResponse({'error': e.toString()});
      }
    }
  }

  void stop() {
    _running = false;
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

  /// Handle incoming messages from the browser extension
  Future<Map<String, dynamic>> _handleMessage(
      Map<String, dynamic> message) async {
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
    if (url == null || url.isEmpty) {
      return await _getAllCredentials();
    }

    final entries = await _db.searchEntries(url);
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<List<Map<String, dynamic>>> _getAllCredentials() async {
    final entries = await _db.getAllEntries();
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<List<Map<String, dynamic>>> _searchCredentials(String query) async {
    if (query.isEmpty) return await _getAllCredentials();
    final entries = await _db.searchEntries(query);
    return entries.map((e) => _entryToJson(e)).toList();
  }

  Future<Map<String, dynamic>> _getStatus() async {
    final count = await _db.getEntryCount();
    return {
      'connected': true,
      'locked': false,
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
    final password = StringBuffer();
    for (final set in charSets) {
      password.write(set[random.nextInt(set.length)]);
    }
    while (password.length < length) {
      password.write(allChars[random.nextInt(allChars.length)]);
    }
    final shuffled = password.toString().split('')..shuffle(random);

    return {'password': shuffled.join()};
  }

  Future<Map<String, dynamic>> _getTotp(String entryId) async {
    final entry = await _db.getEntryById(entryId);
    if (entry == null || (entry.totpSecretEncrypted ?? '').isEmpty) {
      throw Exception('No TOTP secret configured for this entry');
    }
    final secret = entry.totpSecretEncrypted!;
    final totp = _totpService.generateTotp(secret);
    final remaining = _totpService.getRemainingSeconds();
    return {'totp': totp, 'remaining': remaining};
  }

  // ─── Helpers ────────────────────────────────────────────

  Map<String, dynamic> _entryToJson(PasswordEntry entry) {
    return {
      'id': entry.id,
      'name': entry.name,
      'url': entry.url,
      'username': entry.username,
      'password': entry.passwordEncrypted,
      'notes': entry.notesEncrypted,
      'isFavorite': entry.isFavorite,
    };
  }
}