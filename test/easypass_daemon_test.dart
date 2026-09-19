import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/features/browser_bridge/easypass_daemon.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';
import 'package:easypass/features/browser_bridge/vault_session.dart';

import 'fakes.dart';

/// Integration tests for the 2.0 background daemon: loopback TCP listener,
/// token handshake, and the reused native messaging protocol.
/// 另覆盖 C 方案：解锁会话跨连接保持（daemon 持有一个共享 [VaultSession]）。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const masterPassword = 'correct horse battery staple';

  Uint8List frameOf(Map<String, dynamic> message) {
    final json = utf8.encode(jsonEncode(message));
    final frame = Uint8List(4 + json.length);
    frame.buffer.asByteData().setUint32(0, json.length, Endian.little);
    frame.setAll(4, json);
    return frame;
  }

  /// 读响应帧。超时给得很宽松：`flutter test` 会并行跑多个测试文件，兄弟文件里
  /// 每次 PBKDF2（10 万轮、纯 Dart）都可能饿死本 isolate，5 秒会 flaky。
  /// 客户端侧同样用有状态 reader —— 服务端连续写出的响应也可能被合并进一个 chunk。
  Future<Map<String, dynamic>> readMessage(NativeMessageReader reader) async {
    final message =
        await reader.read().timeout(const Duration(seconds: 20));
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

  /// 配置主密码（salt + hash）。只有真正走协议 `unlock` 的用例才需要，
  /// 按需调用以省掉无谓的 100k 次 PBKDF2（测试套件里的大头开销）。
  Future<void> configureMasterPassword() async {
    final salt = crypto.generateSalt();
    await crypto.storeKeyMaterial(
        salt, crypto.hashMasterPassword(masterPassword, salt));
  }

  /// 建连并完成 token 握手，返回 socket 与"已跳过握手帧"的 reader。
  Future<(Socket, NativeMessageReader)> connect() async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(frameOf({'token': token}));
    await socket.flush();
    return (socket, NativeMessageReader(StreamIterator(socket)));
  }

  /// 在 [socket] 上发一个请求并读回响应。
  Future<Map<String, dynamic>> ask(Socket socket, NativeMessageReader reader,
      Map<String, dynamic> request) async {
    socket.add(frameOf(request));
    await socket.flush();
    return readMessage(reader);
  }

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
        .timeout(const Duration(seconds: 20));
    expect(closed, isTrue);
    await socket.close();
  });

  test('serves getStatus after a valid handshake', () async {
    final (socket, reader) = await connect();
    final response =
        await ask(socket, reader, {'requestId': 'd1', 'action': 'getStatus'});
    expect(response['requestId'], 'd1');
    expect((response['data'] as Map)['connected'], true);
    expect((response['data'] as Map)['locked'], true);
    await socket.close();
  });

  test('returns Vault is locked for credentials before unlock', () async {
    final (socket, reader) = await connect();
    final response = await ask(
        socket, reader, {'requestId': 'd2', 'action': 'getAllCredentials'});
    expect(response['requestId'], 'd2');
    expect(response['error'], contains('locked'));
    await socket.close();
  });

  test('serves two requests over one connection', () async {
    final (socket, reader) = await connect();
    expect((await ask(socket, reader, {'requestId': 'a', 'action': 'getStatus'}))[
        'requestId'], 'a');
    expect((await ask(socket, reader, {'requestId': 'b', 'action': 'getStatus'}))[
        'requestId'], 'b');
    await socket.close();
  });

  test('握手帧与首个请求写在同一次写入里也不会丢帧（合并 chunk 回归）', () async {
    // bridge 完全可能把两帧一起写进同一个 chunk（loopback TCP 也会合并），
    // 服务端一次 read 就能拿到两帧 —— 不能把第二帧连同 chunk 一起丢掉。
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add([
      ...frameOf({'token': token}),
      ...frameOf({'requestId': 'coalesced', 'action': 'getStatus'}),
    ]);
    await socket.flush();

    final reader = NativeMessageReader(StreamIterator(socket));
    final response = await readMessage(reader);
    expect(response['requestId'], 'coalesced');
    expect((response['data'] as Map)['connected'], true);
    await socket.close();
  });

  test('一次写入里连发两个请求也不会丢帧（扩展连发的真实场景）', () async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add([
      ...frameOf({'token': token}),
      ...frameOf({'requestId': 'p1', 'action': 'getStatus'}),
      ...frameOf({'requestId': 'p2', 'action': 'getStatus'}),
    ]);
    await socket.flush();

    final reader = NativeMessageReader(StreamIterator(socket));
    expect((await readMessage(reader))['requestId'], 'p1');
    expect((await readMessage(reader))['requestId'], 'p2');
    await socket.close();
  });

  // ─── C 方案：解锁态跨连接保持 ────────────────────────────

  test('daemon 构造时创建共享 session，也接受注入', () {
    expect(daemon.session, isA<VaultSession>());

    final injected = VaultSession();
    final custom =
        EasypassDaemon(db, crypto, TotpService(), session: injected);
    expect(custom.session, same(injected));
  });

  test('连接读的是 daemon 持有的那个 session（直接解锁 → 连接立即可见）', () async {
    expect(daemon.session.isUnlocked, isFalse);

    // 直接给共享会话装上密钥：走协议 unlock 的路径由下面两个用例覆盖，
    // 这里只验证"连接用的是同一个 session"。
    daemon.session.unlock(Uint8List.fromList(List<int>.filled(32, 7)));

    final (socket, reader) = await connect();
    final status = await ask(socket, reader,
        {'requestId': 's1', 'action': 'getStatus'});
    expect((status['data'] as Map)['locked'], false);
    await socket.close();
  });

  test('断开连接不清除解锁态：新连接仍然是解锁的（C 方案核心）', () async {
    await configureMasterPassword();

    final (first, firstReader) = await connect();
    final unlock = await ask(first, firstReader,
        {'requestId': 'u1', 'action': 'unlock', 'password': masterPassword});
    expect(unlock['error'], isNull);
    expect((unlock['data'] as Map)['success'], true);
    expect(daemon.session.isUnlocked, isTrue);
    await first.close();

    // 给服务端一点时间处理 EOF（连接断开本身不应触发锁定）
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final (second, secondReader) = await connect();
    final status = await ask(second, secondReader,
        {'requestId': 's1', 'action': 'getStatus'});
    expect((status['data'] as Map)['locked'], false);

    final creds = await ask(second, secondReader,
        {'requestId': 'c1', 'action': 'getAllCredentials'});
    expect(creds['error'], isNull);
    await second.close();
  });

  test('lock 动作清除共享解锁态：新连接回到锁定态', () async {
    daemon.session.unlock(Uint8List.fromList(List<int>.filled(32, 7)));

    final (first, firstReader) = await connect();
    expect(
        ((await ask(first, firstReader,
                {'requestId': 's0', 'action': 'getStatus'}))['data']
            as Map)['locked'],
        false);

    final lock = await ask(
        first, firstReader, {'requestId': 'l1', 'action': 'lock'});
    expect(lock['error'], isNull);
    expect(daemon.session.isUnlocked, isFalse);
    await first.close();

    final (second, secondReader) = await connect();
    final status = await ask(second, secondReader,
        {'requestId': 's1', 'action': 'getStatus'});
    expect((status['data'] as Map)['locked'], true);
    expect((status['data'] as Map)['autoLockRemainingSeconds'], isNull);
    await second.close();
  });

  test('错误的主密码不会解锁共享 session', () async {
    await configureMasterPassword();

    final (socket, reader) = await connect();
    final res = await ask(socket, reader,
        {'requestId': 'u1', 'action': 'unlock', 'password': 'wrong'});
    expect(res['error'], isNotNull);
    expect(daemon.session.isUnlocked, isFalse);
    await socket.close();
  });

  // ─── 协议版本化：陈旧 daemon 的判定与接管 ──────────────────
  //
  // 背景：升级后旧的 daemon 进程可能仍在服务扩展，它不认识新动作、只会回
  // `Unknown action: xxx`。daemon.json 现在带 protocolVersion/pid，启动时靠
  // probe() 判定"陈旧"并接管。

  group('probe / retire（陈旧 daemon 接管）', () {
    const fakeToken = 'deadbeefdeadbeef';

    late File probeFile;
    ServerSocket? fakeServer;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp
          .createTempSync('easypass_probe_${DateTime.now().microsecondsSinceEpoch}');
      probeFile = File('${tempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      try {
        await fakeServer?.close();
      } catch (_) {}
      fakeServer = null;
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// 起一个"伪旧 daemon"：说同样的帧协议、握手也认，但只有旧版行为 ——
    /// 默认不回报 protocolVersion（= 2.0.0 的 daemon），也可以指定一个旧版本号。
    Future<int> startFakeDaemon({int? protocolVersion}) async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      fakeServer = server;
      server.listen((socket) async {
        try {
          final reader = NativeMessageReader(StreamIterator(socket));
          final handshake = await reader.read();
          if (handshake == null || handshake['token'] != fakeToken) {
            socket.close();
            return;
          }
          while (true) {
            final request = await reader.read();
            if (request == null) break;
            final Map<String, dynamic> data = {
              'connected': true,
              'locked': true,
              'entryCount': 0,
            };
            if (protocolVersion != null) {
              data['protocolVersion'] = protocolVersion;
            }
            socket.add(NativeMessagingService.encodeMessage(
                {'requestId': request['requestId'], 'data': data}));
            await socket.flush();
          }
        } catch (_) {
          // 测试结束时 socket 被关掉是正常的
        }
      });
      return server.port;
    }

    void writeInfo({required int port, String token = fakeToken, int? pid, int? protocolVersion}) {
      probeFile.writeAsStringSync(jsonEncode({
        'port': port,
        'token': token,
        'pid': ?pid,
        'protocolVersion': ?protocolVersion,
      }));
    }

    test('start() 写入 port/token/protocolVersion/pid', () async {
      final info = jsonDecode(await infoFile.readAsString()) as Map<String, dynamic>;
      expect(info['port'], isA<int>());
      expect(info['token'], isA<String>());
      expect(info['protocolVersion'],
          AppConstants.bridgeProtocolVersion);
      expect(info['pid'], pid, reason: 'pid 必须是当前进程（UI 模式下 UI 与 daemon 同进程）');
    });

    test('probe：版本一致 → ready，并回报运行中的版本', () async {
      final result = await EasypassDaemon.probe(infoFile: infoFile);
      expect(result.status, DaemonProbeStatus.ready);
      expect(result.isUsable, isTrue);
      expect(result.liveProtocolVersion, AppConstants.bridgeProtocolVersion);
      expect(result.fileProtocolVersion, AppConstants.bridgeProtocolVersion);
    });

    test('probe：没有 daemon.json → absent', () async {
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.absent);
      expect(result.isUsable, isFalse);
      expect(result.needsCleanup, isFalse);
    });

    test('probe：JSON 损坏 → unreachable 且不抛异常', () async {
      probeFile.writeAsStringSync('{ not json at all');
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.needsCleanup, isTrue);
    });

    test('probe：缺 port/token → unreachable', () async {
      probeFile.writeAsStringSync(jsonEncode({'protocolVersion': 2}));
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.unreachable);
    });

    test('probe：端口无人应答（残留文件）→ unreachable', () async {
      // 先拿一个真实端口再关掉，保证这个端口上没人监听。
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      writeInfo(port: deadPort);
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.needsCleanup, isTrue);
    });

    test('probe：旧 daemon（getStatus 不回报 protocolVersion）→ stale', () async {
      final port = await startFakeDaemon();
      writeInfo(port: port);
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.stale);
      expect(result.liveProtocolVersion, isNull);
      expect(result.isUsable, isFalse);
      expect(result.needsCleanup, isTrue);
    });

    test('probe：版本号对不上（1）→ stale', () async {
      final port = await startFakeDaemon(protocolVersion: 1);
      writeInfo(port: port, protocolVersion: 1);
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.stale);
      expect(result.liveProtocolVersion, 1);
    });

    test('probe：文件缺字段但运行中的 daemon 版本正确 → 仍判 ready（以实时应答为准，避免误杀）',
        () async {
      // 文件是旧格式（没有 protocolVersion/pid），但端口上跑的就是本构建的 daemon。
      final info = jsonDecode(await infoFile.readAsString()) as Map<String, dynamic>;
      probeFile.writeAsStringSync(
          jsonEncode({'port': info['port'], 'token': info['token']}));
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.ready);
      expect(result.fileProtocolVersion, isNull);
    });

    test('isRunning 兼容层：真 daemon → true，旧 daemon → false', () async {
      expect(await EasypassDaemon.isRunning(infoFile: infoFile), isTrue);

      final port = await startFakeDaemon();
      writeInfo(port: port);
      expect(await EasypassDaemon.isRunning(infoFile: probeFile), isFalse);
    });

    test('retire：陈旧且无 pid → 清掉 daemon.json、不杀进程', () async {
      final port = await startFakeDaemon();
      writeInfo(port: port);
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.stale);

      final killed = await EasypassDaemon.retire(result, infoFile: probeFile);

      expect(killed, isFalse);
      expect(probeFile.existsSync(), isFalse, reason: '残留文件必须清掉，否则桥接会一直连旧端口');
    });

    test('retire 安全：pid 不是 easypass.exe 时绝不杀进程（并照样清文件）', () async {
      if (!Platform.isWindows) return; // tasklist 核对仅在 Windows 上
      // 起一个无害的长命进程，把它当作 daemon.json 里记录的 pid。
      final victim = await Process.start(
          'cmd', ['/c', 'ping', '-n', '60', '127.0.0.1']);
      addTearDown(() {
        try {
          victim.kill();
        } catch (_) {}
      });

      final port = await startFakeDaemon();
      writeInfo(port: port, pid: victim.pid);
      final result = await EasypassDaemon.probe(infoFile: probeFile);
      expect(result.status, DaemonProbeStatus.stale);
      expect(result.pid, victim.pid);

      final killed = await EasypassDaemon.retire(result, infoFile: probeFile);

      expect(killed, isFalse, reason: '映像名不是 easypass.exe，必须拒绝结束');
      expect(probeFile.existsSync(), isFalse);
      // 进程还活着：再等一小会儿，exitCode 不应有值。
      var exited = false;
      unawaited(victim.exitCode.then((_) => exited = true));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(exited, isFalse, reason: '非本产品进程必须原样活着');
    });
  });

  // ─── 空闲自退（`--service` 专用）：升级后旧 daemon 不会赖着不走 ─────────

  group('空闲自退', () {
    const idleTimeout = Duration(minutes: 10);

    late Directory tempDir;
    late File idleInfoFile;
    late DateTime now;
    late EasypassDaemon idleDaemon;
    var idleExitCalls = 0;
    var port = 0;
    var token = '';

    Future<void> startIdleDaemon({bool exitWhenIdle = true}) async {
      idleDaemon = EasypassDaemon(
        db,
        crypto,
        TotpService(),
        infoFile: idleInfoFile,
        exitWhenIdle: exitWhenIdle,
        idleExitTimeout: idleTimeout,
        clock: () => now,
        onIdleExit: () async => idleExitCalls++,
      );
      await idleDaemon.start();
      final info = jsonDecode(await idleInfoFile.readAsString()) as Map<String, dynamic>;
      port = info['port'] as int;
      token = info['token'] as String;
      addTearDown(idleDaemon.stop);
    }

    setUp(() async {
      now = DateTime(2026, 1, 1, 12, 0, 0);
      idleExitCalls = 0;
      tempDir = Directory.systemTemp
          .createTempSync('easypass_idle_${DateTime.now().microsecondsSinceEpoch}');
      idleInfoFile = File('${tempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Socket> openClient() async {
      final socket = await Socket.connect('127.0.0.1', port);
      socket.add(frameOf({'token': token}));
      await socket.flush();
      return socket;
    }

    test('UI 模式（开关关闭）永不判退，哪怕空闲很久', () async {
      await startIdleDaemon(exitWhenIdle: false);
      now = now.add(const Duration(hours: 5));
      expect(idleDaemon.shouldExitWhenIdle, isFalse);
      expect(await idleDaemon.maybeExitWhenIdle(), isFalse);
      expect(idleExitCalls, 0);
      expect(idleInfoFile.existsSync(), isTrue);
    });

    test('会话仍解锁时不判退（lock 之后才判退）', () async {
      await startIdleDaemon();
      idleDaemon.session.unlock(Uint8List.fromList(List<int>.filled(32, 7)));

      now = now.add(idleTimeout + const Duration(minutes: 1));
      expect(idleDaemon.shouldExitWhenIdle, isFalse, reason: '不能擅自丢掉用户刚解开的锁');
      expect(await idleDaemon.maybeExitWhenIdle(), isFalse);

      idleDaemon.session.lock();
      expect(idleDaemon.shouldExitWhenIdle, isTrue);
    });

    test('有活跃连接时不判退，连接关闭后才可能判退', () async {
      await startIdleDaemon();
      final socket = await openClient();
      // 等握手被服务端处理（_activeConnections 才会 +1）
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(idleDaemon.activeConnections, 1);

      now = now.add(idleTimeout + const Duration(minutes: 5));
      expect(idleDaemon.shouldExitWhenIdle, isFalse);
      expect(await idleDaemon.maybeExitWhenIdle(), isFalse);

      await socket.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(idleDaemon.activeConnections, 0);
      // 断开本身刷了一次活动时间，所以还得再空转一个窗口
      now = now.add(idleTimeout);
      expect(idleDaemon.shouldExitWhenIdle, isTrue);
    });

    test('空闲超时 + 已锁定 → 自退：删 daemon.json、停监听、回调一次', () async {
      await startIdleDaemon();
      now = now.add(idleTimeout);

      expect(await idleDaemon.maybeExitWhenIdle(), isTrue);

      expect(idleExitCalls, 1, reason: '退出动作由注入的回调执行（生产里是 exit(0)）');
      expect(idleInfoFile.existsSync(), isFalse,
          reason: '留下指向死端口的 daemon.json = 历史上的扩展超时');
      // 监听已停：新连接连不上
      await expectLater(
        Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 500)),
        throwsA(isA<SocketException>()),
      );
      // 再次调用是幂等的
      expect(await idleDaemon.maybeExitWhenIdle(), isFalse);
      expect(idleExitCalls, 1);
    });

    test('daemon.json 被别人接管后自退不删它（只删自己写的）', () async {
      await startIdleDaemon();
      // 模拟 UI 模式的 daemon 后来居上覆盖了注册信息
      idleInfoFile.writeAsStringSync(jsonEncode({
        'port': 1,
        'token': 'someone-else',
        'protocolVersion': AppConstants.bridgeProtocolVersion,
        'pid': pid + 1,
      }));

      now = now.add(idleTimeout);
      expect(await idleDaemon.maybeExitWhenIdle(), isTrue);

      expect(idleInfoFile.existsSync(), isTrue,
          reason: '不能把别的 daemon 的注册信息一起删掉');
      final still = jsonDecode(idleInfoFile.readAsStringSync()) as Map<String, dynamic>;
      expect(still['pid'], pid + 1);
    });
  });
}
