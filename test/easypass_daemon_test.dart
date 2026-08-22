import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/features/browser_bridge/easypass_daemon.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';

import 'fakes.dart';

/// Integration tests for the 2.0 background daemon: loopback TCP listener,
/// token handshake, and the reused native messaging protocol.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Uint8List frameOf(Map<String, dynamic> message) {
    final json = utf8.encode(jsonEncode(message));
    final frame = Uint8List(4 + json.length);
    frame.buffer.asByteData().setUint32(0, json.length, Endian.little);
    frame.setAll(4, json);
    return frame;
  }

  Future<Map<String, dynamic>> readMessage(
      StreamIterator<List<int>> iterator) async {
    final message = await NativeMessagingService.readMessage(iterator)
        .timeout(const Duration(seconds: 5));
    if (message == null) throw StateError('connection closed by daemon');
    return message;
  }

  late FakeSecureStorage storage;
  late AppDatabase db;
  late CryptoService crypto;
  late File infoFile;
  late EasypassDaemon daemon;
  late int port;
  late String token;

  setUp(() async {
    storage = FakeSecureStorage();
    crypto = CryptoService(secureStorage: storage);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    infoFile = File(
        '${Directory.systemTemp.path}\\easypass_daemon_test_${DateTime.now().millisecondsSinceEpoch}.json');
    daemon = EasypassDaemon(db, crypto, TotpService(), infoFile: infoFile);
    await daemon.start();
    final info = jsonDecode(await infoFile.readAsString());
    port = info['port'] as int;
    token = info['token'] as String;
  });

  tearDown(() async {
    daemon.stop();
    await db.close();
    if (infoFile.existsSync()) infoFile.deleteSync();
  });

  test('persists port and token for the bridge', () async {
    expect(port, greaterThan(0));
    expect(token.length, 64);
  });

  test('rejects a connection with a wrong token', () async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(frameOf({'token': 'wrong-token'}));
    await socket.flush();
    // The daemon closes the connection without replying.
    final closed = await socket.drain<void>().then((_) => true).catchError((_) => true)
        .timeout(const Duration(seconds: 5));
    expect(closed, isTrue);
    await socket.close();
  });

  test('serves getStatus after a valid handshake', () async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(frameOf({'token': token}));
    await socket.flush();

    final it = StreamIterator(socket);
    socket.add(frameOf({'requestId': 'd1', 'action': 'getStatus'}));
    await socket.flush();
    final response = await readMessage(it);
    expect(response['requestId'], 'd1');
    expect((response['data'] as Map)['connected'], true);
    expect((response['data'] as Map)['locked'], true);
    await socket.close();
  });

  test('returns Vault is locked for credentials before unlock', () async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(frameOf({'token': token}));
    await socket.flush();

    final it = StreamIterator(socket);
    socket.add(frameOf({'requestId': 'd2', 'action': 'getAllCredentials'}));
    await socket.flush();
    final response = await readMessage(it);
    expect(response['requestId'], 'd2');
    expect(response['error'], contains('locked'));
    await socket.close();
  });

  test('serves two requests over one connection', () async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(frameOf({'token': token}));
    await socket.flush();

    final it = StreamIterator(socket);
    socket.add(frameOf({'requestId': 'a', 'action': 'getStatus'}));
    await socket.flush();
    expect((await readMessage(it))['requestId'], 'a');

    socket.add(frameOf({'requestId': 'b', 'action': 'getStatus'}));
    await socket.flush();
    expect((await readMessage(it))['requestId'], 'b');
    await socket.close();
  });
}
