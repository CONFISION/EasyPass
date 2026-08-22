import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

  /// Start the native messaging host listening on stdin (browser-launched
  /// host mode).
  Future<void> start() => serve(StreamIterator(stdin), stdout);

  /// Serve the native messaging protocol over arbitrary byte streams.
  ///
  /// Used by the browser-launched host (stdin/stdout) and by the 2.0 daemon
  /// (a TCP socket). [iterator] must already be positioned after any
  /// handshake frame. Responses are written to [output] as length-prefixed
  /// JSON frames.
  Future<void> serve(
      StreamIterator<List<int>> iterator, IOSink output) async {
    if (_running) return;
    _running = true;

    while (_running) {
      try {
        final message = await readMessage(iterator);
        if (message == null) {
          break; // peer closed the stream
        }
        final response = await handleRequest(message);
        await _writeFrame(output, response);
      } catch (e) {
        if (!_running) break;
        await _writeFrame(output, {'error': e.toString()});
      }
    }
  }

  Future<void> _writeFrame(IOSink output, Map<String, dynamic> response) async {
    output.add(encodeMessage(response));
    // The stream buffers; without an explicit flush the peer (browser or
    // daemon client) would never receive the response.
    await output.flush();
  }

  void stop() {
    _running = false;
    _sessionKey = null;
  }

  /// Encode a JSON message as a native-messaging frame: a 4-byte little-endian
  /// length prefix followed by the UTF-8 JSON bytes.
  @visibleForTesting
  static Uint8List encodeMessage(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    final bytes = utf8.encode(json);
    final length = bytes.length;

    final header = Uint8List(4);
    header[0] = length & 0xff;
    header[1] = (length >> 8) & 0xff;
    header[2] = (length >> 16) & 0xff;
    header[3] = (length >> 24) & 0xff;

    return Uint8List.fromList([...header, ...bytes]);
  }

  /// Read one native-messaging frame from [iterator]: a 4-byte little-endian
  /// length prefix followed by that many UTF-8 JSON bytes.
  ///
  /// The browser may write the header and the payload in a single write or
  /// split them across arbitrary chunk boundaries (e.g. header in one write
  /// and payload in another, or even the header itself split), so bytes are
  /// accumulated until both the header and the full payload are available.
  ///
  /// Returns the decoded message, or null on EOF (peer closed the pipe).
  static Future<Map<String, dynamic>?> readMessage(
      StreamIterator<List<int>> iterator) async {
    final buffer = BytesBuilder(copy: false);

    // Accumulate until we have the 4-byte length header.
    while (buffer.length < 4) {
      if (!await iterator.moveNext()) return null;
      buffer.add(iterator.current);
    }

    final headBytes = buffer.takeBytes();
    final length = (headBytes[0] & 0xff) |
        ((headBytes[1] & 0xff) << 8) |
        ((headBytes[2] & 0xff) << 16) |
        ((headBytes[3] & 0xff) << 24);
    if (length <= 0) return null;

    final payload = BytesBuilder(copy: false)..add(headBytes.sublist(4));
    while (payload.length < length) {
      if (!await iterator.moveNext()) return null;
      payload.add(iterator.current);
    }

    final messageBytes = payload.takeBytes();
    final message = utf8.decode(messageBytes.sublist(0, length));
    return jsonDecode(message) as Map<String, dynamic>;
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
