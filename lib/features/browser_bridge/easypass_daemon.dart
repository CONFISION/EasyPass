import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';
import 'native_messaging_service.dart';

/// EasyPass background daemon (2.0 architecture).
///
/// Runs as `easypass.exe --service`: a windowless process that owns the vault
/// database and serves the native messaging protocol over TCP localhost.
/// The browser never talks to the daemon directly; a small console bridge
/// (easypass_native_host.exe) forwards the browser's stdio pipe to this
/// daemon's TCP endpoint. This decouples the host from the browser's
/// cross-bitness handle-passing issues (e.g. 32-bit Edge) and lets the
/// extension work while the UI is closed.
///
/// Security: the server binds to loopback only, and every connection must
/// present the random token persisted in `%LOCALAPPDATA%\EasyPass\daemon.json`
/// (a directory only the current user can write to).
class EasypassDaemon {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  final File? _infoFile;

  ServerSocket? _server;
  String _token = '';

  EasypassDaemon(this._db, this._cryptoService, this._totpService,
      {this._infoFile});

  /// True when a daemon is already listening (reads [infoFile] -- daemon.json
  /// by default -- and probes the recorded loopback port). Used to avoid
  /// spawning a second daemon when one is already running (e.g. the UI
  /// starting while the bridge already launched the service).
  static Future<bool> isRunning({File? infoFile}) async {
    final file = infoFile ?? _defaultInfoFileStatic();
    try {
      final raw = await file.readAsString();
      final info = jsonDecode(raw) as Map<String, dynamic>;
      final port = info['port'] as int;
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(milliseconds: 800));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  static File _defaultInfoFileStatic() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return File('$localAppData\\EasyPass\\daemon.json');
  }

  /// Removes a stale daemon.json (left behind when a previous daemon exited
  /// or crashed). A stale file makes bridges try a dead port first, wait out
  /// their reconnect poll, and time out. Call when [isRunning] reports false
  /// but an info file exists.
  static Future<void> clearStaleInfo({File? infoFile}) async {
    final file = infoFile ?? _defaultInfoFileStatic();
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best effort; a fresh start() will overwrite it anyway.
    }
  }

  /// Bind the loopback listener, persist [port]/[token], and wait for bridge
  /// connections. Returns once the listener is up; the daemon then serves
  /// until the process exits (tray Exit or task end).
  Future<void> start() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _token = _generateToken();
      await _persistInfo(server.port, _token);
      server.listen(_onConnection, onError: (_) {});
    } catch (e) {
      rethrow;
    }
  }


  void stop() {
    _server?.close();
    _server = null;
  }

  Future<void> _onConnection(Socket socket) async {
    try {
      final iterator = StreamIterator(socket);

      // Handshake: the first frame must carry the token.
      final handshake = await NativeMessagingService.readMessage(iterator);
      if (handshake == null || handshake['token'] != _token) {
        socket.close();
        return;
      }

      // A fresh service instance per bridge connection: each carries its own
      // unlock state (memory-only session key), exactly like the browser host.
      final host = NativeMessagingService(_db, _cryptoService, _totpService);
      await host.serve(iterator, socket);
    } catch (_) {
      // Peer errors end the connection; the daemon keeps serving.
    } finally {
      socket.close();
    }
  }

  String _generateToken() {
    final rand = Random.secure();
    return List.generate(
        32, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> _persistInfo(int port, String token) async {
    final file = _infoFile ?? _defaultInfoFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'port': port, 'token': token}));
  }

  File _defaultInfoFile() {
    return _defaultInfoFileStatic();
  }
}
