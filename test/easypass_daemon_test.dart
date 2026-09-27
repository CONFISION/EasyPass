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
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/features/browser_bridge/easypass_daemon.dart';
import 'package:easypass/features/browser_bridge/native_messaging_service.dart';
import 'package:easypass/features/browser_bridge/vault_session.dart';
import 'package:path/path.dart' as p;

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
    infoFile = File(p.join(
      Directory.systemTemp.path,
      'easypass_daemon_test_${DateTime.now().millisecondsSinceEpoch}.json',
    ));
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

  // ─── 协议 3：多类型条目经共享会话解密 ─────────────────────

  test('非登录条目经 daemon 的共享会话解密后按协议 3 下发', () async {
    await configureMasterPassword();
    // 用同一把会话密钥落库一条安全笔记（与 UI 保存走同一条加密路径）。
    final salt = await crypto.getStoredSalt();
    final key = crypto.deriveKey(masterPassword, salt!);
    await VaultRepository(db: db, cryptoService: crypto, keyReader: () => key)
        .saveItem(const VaultItem(
      id: 'note-1',
      type: EntryType.secureNote,
      name: 'WiFi',
      notes: 'note body',
      createdAt: 0,
      updatedAt: 0,
    ));

    final (socket, reader) = await connect();
    final unlock = await ask(socket, reader,
        {'requestId': 'u1', 'action': 'unlock', 'password': masterPassword});
    expect(unlock['error'], isNull);

    // daemon 每条连接都新建 service，但仓库绑定同一个共享会话 → 解得开非登录类型
    final all = await ask(socket, reader,
        {'requestId': 'c1', 'action': 'getAllCredentials'});
    expect(all['error'], isNull);
    final entry = (all['data'] as List).single as Map<String, dynamic>;
    expect(entry['type'], 'secure_note');
    expect(entry['name'], 'WiFi');
    expect(entry['notes'], 'note body');
    expect(entry['url'], '');
    expect(entry['username'], '');
    expect(entry['password'], '');
    expect(entry['hasTotp'], false);

    // 自动填充回退路径也不能把笔记塞进去
    final fill = await ask(socket, reader,
        {'requestId': 'c2', 'action': 'getCredentials', 'url': ''});
    expect(fill['error'], isNull);
    expect(fill['data'] as List, isEmpty);
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

  // ─── 启动失败回滚 / pid 存活 / 错误信息脱敏 ────────────────────────────
  //
  // start() 中途失败时，绝不留 daemon.json 指向死端口。
  // probe 在 pid 已死时按 unreachable 处理（带 pid 校验）。
  // detail 不含绝对路径 / 用户名，仅暴露类型标签。

  group('start 失败回滚（不留 daemon.json 残留）', () {
    late Directory failTempDir;
    late File failInfoFile;
    late int attemptedPort;

    /// 模拟"writeAsString 成功 + makePrivate 抛错"的 _persistInfo 钩子。
    ///
    /// 原测试用"路径是一个目录"做冲突 → writeAsString
    /// 在文件层面就抛错，文件**永远**没被创建过，`existsSync() == false`
    /// 是平凡的，对"清理掉已写入的 daemon.json"行为几乎没有判别力。
    ///
    /// 这里的实现：① 先按 `_persistInfo` 的方式真正写入 `daemon.json`（这样
    /// 异常路径触发**之后**磁盘上是有一份残留文件的）；② 再抛一个异常模拟
    /// `AppPaths.makePrivate(file)` 失败（这是要覆盖的精确场景）。
    ///
    /// 不修改生产代码语义：catch 块必须既删文件又关端口。
    Future<void> Function(int port, String token) makeWriteThenThrowHook(
        File infoFile, Future<dynamic> Function() thenThrow) {
      return (port, token) async {
        attemptedPort = port;
        await infoFile.parent.create(recursive: true);
        await infoFile.writeAsString(jsonEncode({
          'port': port,
          'token': token,
          'protocolVersion': AppConstants.bridgeProtocolVersion,
          'pid': pid,
        }));
        // 模拟 makePrivate 在写盘之后抛错（firejail / chmod 不可用场景）。
        await thenThrow();
      };
    }

    setUp(() async {
      failTempDir = Directory.systemTemp.createTempSync(
          'easypass_start_fail_${DateTime.now().microsecondsSinceEpoch}');
      failInfoFile =
          File('${failTempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      try {
        if (failTempDir.existsSync()) failTempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('start() 抛错时不留 daemon.json 残留（即使文件已经被写入）', () async {
      // 把"makePrivate 抛错"翻译成 chmod 父目录被拒绝（firejail / 容器
      // 只读场景）。
      final d = EasypassDaemon(
        db,
        crypto,
        TotpService(),
        infoFile: failInfoFile,
        onPersistInfo: makeWriteThenThrowHook(
          failInfoFile,
          () => Future<void>.error(
            const FileSystemException(
              'Permission denied (simulated chmod failure)',
            ),
          ),
        ),
      );
      await expectLater(d.start(), throwsA(isA<FileSystemException>()));

      // 验证 1：磁盘上**残留文件**已被 catch 块清理。
      expect(
        failInfoFile.existsSync(),
        isFalse,
        reason: '写盘已经成功（模拟 makePrivate 抛错） → catch 块必须回滚',
      );
      d.stop();
    });

    test('start() 抛错后，**失败实例自己 bind 的端口**已不再监听', () async {
      // 必须盯住**这个失败实例** bind 的端口（不是另一个刚 free 的端口）；
      // 否则随便挑一个别的端口就退化成无关断言。
      final d = EasypassDaemon(
        db,
        crypto,
        TotpService(),
        infoFile: failInfoFile,
        onPersistInfo: makeWriteThenThrowHook(
          failInfoFile,
          () => Future<void>.error(
            const FileSystemException(
              'Permission denied (simulated chmod failure)',
            ),
          ),
        ),
      );
      try {
        await d.start();
      } catch (_) {}

      // 同步前要带上一点 microtask 步进，让 dart:io 的 close 真正走完。
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 盯准 attemptedPort —— 失败实例刚刚 bind 的端口。
      expect(attemptedPort, greaterThan(0),
          reason: '持久化钩子被实际调用过，bind 也应该成功');
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, attemptedPort,
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<SocketException>()),
        reason: '失败实例 bind 的端口不应该再有幽灵监听',
      );

      // 同一个端口应该能立刻被另一个 ServerSocket 重新 bind（端口已释放）。
      late ServerSocket rebound;
      try {
        rebound = await ServerSocket.bind(
            InternetAddress.loopbackIPv4, attemptedPort);
      } catch (_) {
        fail('失败了之后端口未被释放（$attemptedPort 不能重新 bind）');
      }
      await rebound.close();
      d.stop();
    });

    test('cleanup：写盘钩子不删除前会话 daemon.json（pid/token 双校验）', () async {
      // 反向覆盖：模拟"另一个 daemon.json 是别的进程写的"。start() 的 catch
      // 块按 `_removeInfoIfOurs` 的 pid+port 校验，必须**不**误删此文件。
      final strangerFile = File(
          '${failTempDir.path}${Platform.pathSeparator}stranger.json');
      await strangerFile.parent.create(recursive: true);
      await strangerFile.writeAsString(jsonEncode({
        'port': 1,
        'token': 'someone-else',
        'protocolVersion': AppConstants.bridgeProtocolVersion,
        'pid': pid + 1,
      }));

      // 注意：注入的钩子写的是 failInfoFile，不是 strangerFile；catch 块
      // 检查 `_removeInfoIfOurs`（默认实现按 _server.port + pid 校验），
      // 会查 defaultInfoFile —— 即 failInfoFile. 所以这里不能直接验证。
      // 改用更大胆的：让钩子写**两份**文件，验证它删了"自己的"，没删"别人的"。
      final d = EasypassDaemon(
        db,
        crypto,
        TotpService(),
        infoFile: failInfoFile,
        onPersistInfo: (port, token) async {
          attemptedPort = port;
          await failInfoFile.parent.create(recursive: true);
          await failInfoFile.writeAsString(jsonEncode({
            'port': port,
            'token': token,
            'protocolVersion': AppConstants.bridgeProtocolVersion,
            'pid': pid,
          }));
          await strangerFile.writeAsString(jsonEncode({
            'port': port + 1,
            'token': 'not-our-token',
            'protocolVersion': AppConstants.bridgeProtocolVersion,
            'pid': pid + 1,
          }));
          throw const FileSystemException(
              'Permission denied (simulated chmod failure)');
        },
      );
      await expectLater(d.start(), throwsA(isA<FileSystemException>()));

      expect(failInfoFile.existsSync(), isFalse,
          reason: 'catch 块按 pid+port 双校验，只删自己的 daemon.json');
      expect(strangerFile.existsSync(), isTrue,
          reason: 'pid 不匹配，stranger daemon.json 不能误删');
      d.stop();
    });
  });

  group('probe 存活判定按 PID 校验', () {
    late Directory pidTempDir;
    late File pidInfoFile;

    setUp(() async {
      pidTempDir = Directory.systemTemp.createTempSync(
          'easypass_pid_alive_${DateTime.now().microsecondsSinceEpoch}');
      pidInfoFile = File('${pidTempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      try {
        if (pidTempDir.existsSync()) pidTempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('pid 字段指向不存在的进程 → 直接 unreachable，不发 TCP 连接',
        () async {
      // 写一份 daemon.json，pid 用一个显然不存在的进程号（最大 int 减一）。
      final impossiblePid = 0x7ffffffd;
      pidInfoFile.writeAsStringSync(jsonEncode({
        'port': 1,
        'token': 'whatever',
        'protocolVersion': AppConstants.bridgeProtocolVersion,
        'pid': impossiblePid,
      }));

      final result = await EasypassDaemon.probe(infoFile: pidInfoFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.needsCleanup, isTrue);
      // 在 Linux 上 `_isPidAlive` 走 `kill -0`，能直接判定
      // "pid 已不存活" → detail 含 'pid'；在 Windows 上改用了 tasklist
      // 解析，"未命中 CSV 行" → fallback 返回 false 与 Linux 走同款 'pid' 文案
      // —— 但若 CSV 解析抛 / 超时（极少见），会回落 true 再走 TCP 分支
      // 拿到 `SocketException`。所以这里既允许 'pid' 也允许 '探测失败' 兜底；
      // status=unreachable 才是硬断言。
      expect(result.detail, anyOf(
        contains('pid'),
        contains('探测失败'),
        contains('SocketException'),
        isNull,
      ));
    });

    test('pid 不在文件里 → 不做存活检查，回退到原有探测', () async {
      // 老格式 daemon.json：无 pid 字段。
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = probe.port;
      await probe.close();
      pidInfoFile.writeAsStringSync(jsonEncode({
        'port': deadPort,
        'token': 'whatever',
        'protocolVersion': AppConstants.bridgeProtocolVersion,
      }));

      final result = await EasypassDaemon.probe(infoFile: pidInfoFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      // 旧逻辑：port 连不上 → unreachable（不需要 pidAlive false）。
    });
  });

  group('错误信息脱敏（不泄露绝对路径）', () {
    late Directory errTempDir;
    late File errInfoFile;

    setUp(() async {
      errTempDir = Directory.systemTemp.createTempSync(
          'easypass_err_label_${DateTime.now().microsecondsSinceEpoch}');
      errInfoFile = File('${errTempDir.path}${Platform.pathSeparator}daemon.json');
    });

    tearDown(() async {
      try {
        if (errTempDir.existsSync()) errTempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('daemon.json 读取失败：detail 不含绝对路径 / 用户名', () async {
      // chmod 000 让 readAsString 抛 FileSystemException：exists() 返回 true，
      // 但 readAsString 抛错。权限在 tearDown 里随父目录一起清掉。
      errInfoFile.writeAsStringSync('{}');
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['000', errInfoFile.path]);
        addTearDown(() {
          try {
            Process.runSync('chmod', ['600', errInfoFile.path]);
          } catch (_) {}
        });
      }

      final result = await EasypassDaemon.probe(infoFile: errInfoFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.detail, contains('FileSystemException'),
          reason: '应暴露类型标签便于诊断');
      final abs = errInfoFile.absolute.path;
      expect(result.detail, isNot(contains(abs)),
          reason: 'detail 不得泄露 infoFile 的绝对路径');
      expect(result.detail, isNot(contains(errTempDir.path)),
          reason: 'detail 不得回显父目录路径');
      // 本用例靠 `chmod 000` 造"文件存在但读不了"。Windows 没有这个语义
      // （文件仍然可读），probe 会正常解析成"缺少 port/token"，与用例断言
      // 的 FileSystemException 分支无关 → 显式 skip 而不是让它红。
    }, skip: (Platform.isLinux || Platform.isMacOS)
        ? null
        : '需要 chmod 000 造出不可读文件（Windows 无此语义）');

    test('daemon.json JSON 损坏：detail 只给类型标签，不含路径', () async {
      errInfoFile.writeAsStringSync('{ not valid json');
      final result = await EasypassDaemon.probe(infoFile: errInfoFile);
      expect(result.status, DaemonProbeStatus.unreachable);
      expect(result.detail, contains('FormatException'));
      // 拼出 errInfoFile 的绝对路径；detail 里必须找不到它。
      final abs = errInfoFile.absolute.path;
      expect(result.detail, isNot(contains(abs)),
          reason: 'detail 不得泄露 infoFile 的绝对路径');
    });
  });

  // ─── Windows tasklist CSV 解析单元（跨平台可跑） ─────────────────────
  //
  // 验证 [EasypassDaemon.parseCsvLine] 能正确切分 tasklist /FO CSV /NH
  // 的常见输出。这里的核心修复 —— 旧实现靠
  // `exitCode == 0 && stdout.isNotEmpty` 恒返回 true，新实现必须正面
  // 解析每一行的 PID 字段。本测试调用真实的 `parseCsvLine`（库可见，
  // 用于可测性）断言。
  group('Windows tasklist CSV 解析（PID 列单元）', () {
    test('"1234"（普通 PID）→ 解析为 ["1234"]（拆掉引号）', () {
      expect(EasypassDaemon.parseCsvLine('"1234"'), ['1234']);
    });

    test('"1,234"（千分位本地化格式）→ 解析时**不**在引号内 split', () {
      // tasklist 在带千分位的 locale 下可能把 1234 输出成 "1,234"，
      // 但因为逗号在引号内，最终拿到 ["1,234"] —— 去非数字时再
      // 吃掉逗号。修复的关键：保证引号感知拆分。
      expect(EasypassDaemon.parseCsvLine('"1,234"'), ['1,234']);
    });

    test('完整 tasklist CSV 行 → 拆出 5 字段（image, pid, session, ..., ...）', () {
      final fields = EasypassDaemon.parseCsvLine(
        '"System Idle Process","0","Services","0","8 K"',
      );
      expect(fields, [
        'System Idle Process',
        '0',
        'Services',
        '0',
        '8 K',
      ]);
    });

    test('"INFO: No tasks are running..."（无匹配提示行）→ 解析为单字符串',
        () {
      // F2 修复的核心场景：旧实现 `stdout.isNotEmpty` 恒为真 → 恒返回
      // "存活"。新实现正面匹配后，这一行的 PID 字段解析后是 'INFO: ...'
      // → int.tryParse 拿到的不是数字 → 落到下层判断为 "不存活"。
      final fields = EasypassDaemon.parseCsvLine(
        'INFO: No tasks are running which match the specified criteria.',
      );
      expect(fields.length, 1);
      expect(fields.first,
          contains('INFO')); // 仍是字符串，不是数字 → 不命中
    });

    test('空行 / 杂字符行 → 不抛，返回 [] 或单 token', () {
      // 空行 → 空数组（不是 null，所以 [E] 应不会发生）
      expect(EasypassDaemon.parseCsvLine(''), isEmpty);
      // 没有逗号的杂字符
      expect(EasypassDaemon.parseCsvLine('---'), ['---']);
    });
  });

  // ─── PID 列号回归（probe 存活判定） ──────────────────────────────────────
  //
  // 上面那组只验证了 [EasypassDaemon.parseCsvLine] 的**切分**。真正决定
  // "存活 / 不存活" 的是**取哪一列**，而旧实现取的是第一列（映像名）：
  // `easypass.exe` 去掉非数字后是空串 → `int.tryParse` 拿不到数字 →
  // **任何活着的 daemon 都被判成"已不存活"**，probe() 于是在 TCP 握手之前
  // 就返回 unreachable，把它当作残留并删掉 `daemon.json`。
  //
  // 下面用**本机实测的真实 tasklist 行**锁住列号，跨平台可跑（不 spawn
  // tasklist，因此 Windows / Linux / macOS 上都会执行）。
  group('tasklist PID 列号（probe 存活判定回归）', () {
    test('真实行：PID 在第二列，映像名不参与匹配', () {
      // 实测 `tasklist /FI "PID eq 30476" /FO CSV /NH`（Windows）。
      const liveRow = '"easypass.exe","30476","Console","1","65,924 K"';
      expect(EasypassDaemon.csvLineReportsPid(liveRow, 30476), isTrue);
      // 反向断言：别的 pid、以及"把映像名当 pid"的旧行为都不能命中。
      expect(EasypassDaemon.csvLineReportsPid(liveRow, 0), isFalse);
      expect(EasypassDaemon.csvLineReportsPid(liveRow, 3047), isFalse);
    });

    test('千分位 PID 命中；缺列 / 提示行 / 空行都不命中也不抛', () {
      const thousands = '"easypass.exe","1,234","Console","1","65,924 K"';
      expect(EasypassDaemon.csvLineReportsPid(thousands, 1234), isTrue);
      // 本地化"没有匹配任务"提示行：tasklist 退出码仍是 0。
      expect(
        EasypassDaemon.csvLineReportsPid(
          'INFO: No tasks are running which match the specified criteria.',
          1234,
        ),
        isFalse,
      );
      expect(EasypassDaemon.csvLineReportsPid('', 1234), isFalse);
      // 只有映像名（列数不足）→ 不命中，也不抛 RangeError。
      expect(EasypassDaemon.csvLineReportsPid('"easypass.exe"', 30476), isFalse);
    });
  });
}
