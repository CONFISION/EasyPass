import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../core/constants/app_constants.dart';
import '../../core/crypto/crypto_service.dart';
import '../../core/crypto/totp_service.dart';
import '../../data/database/database.dart';
import 'native_messaging_service.dart';
import 'vault_session.dart';

/// `daemon.json` 探测结果的状态（见 [EasypassDaemon.probe]）。
enum DaemonProbeStatus {
  /// 没有 info 文件：daemon 从未启动，或已被清理。
  absent,

  /// 文件在，但它指向的 daemon 用不了：端口无人应答、token 不匹配、
  /// JSON 损坏……都属于"残留文件"，清理掉即可。
  unreachable,

  /// 连上了、也是本产品的 daemon，但**协议版本不一致**。
  /// 典型场景：升级后旧的 daemon 进程仍在服务扩展 —— 它不认识新动作，
  /// 只会回 `Unknown action: xxx`，扩展侧表现为"无法连接/未知操作"。
  stale,

  /// 协议版本一致且能应答，可以复用。
  ready,
}

/// [EasypassDaemon.probe] 的结果快照。
///
/// 只携带诊断用的非敏感信息 —— **绝不包含 token**。
class DaemonProbeResult {
  final DaemonProbeStatus status;

  /// `daemon.json` 里记录的字段（文件不存在/损坏时为 null）。
  final int? port;
  final int? pid;
  final int? fileProtocolVersion;

  /// 运行中的 daemon 在 `getStatus` 里自报的版本；没连上时为 null。
  final int? liveProtocolVersion;

  /// 供日志排查的简短说明（不含任何凭据）。
  final String? detail;

  const DaemonProbeResult(
    this.status, {
    this.port,
    this.pid,
    this.fileProtocolVersion,
    this.liveProtocolVersion,
    this.detail,
  });

  /// 可以直接复用这个 daemon（版本一致、能应答）。
  bool get isUsable => status == DaemonProbeStatus.ready;

  /// 需要清理 `daemon.json`（陈旧或残留）。
  bool get needsCleanup =>
      status == DaemonProbeStatus.stale ||
      status == DaemonProbeStatus.unreachable;

  @override
  String toString() => 'DaemonProbeResult(${status.name}'
      '${port == null ? '' : ', port=$port'}'
      '${pid == null ? '' : ', pid=$pid'}'
      '${fileProtocolVersion == null ? '' : ', fileVersion=$fileProtocolVersion'}'
      '${liveProtocolVersion == null ? '' : ', liveVersion=$liveProtocolVersion'}'
      '${detail == null ? '' : ', $detail'})';
}

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
///
/// Unlock state (C 方案): the daemon owns a single [VaultSession] created at
/// construction time and hands it to every connection, so unlocking once in
/// the extension keeps the vault usable across bridge reconnects (the MV3
/// service worker is torn down after ~30s of inactivity, which used to force
/// a master-password prompt each time). The session is cleared only by the
/// `lock` action, by the 5-minute idle timeout, or when the process exits.
///
/// Idle self-exit (`--service` only, see [exitWhenIdle]): a bridge-launched
/// service process used to live until reboot, so after an upgrade the **old**
/// daemon kept serving the extension forever and answered every new action with
/// `Unknown action: xxx`. The idle exit is the counterpart of the protocol
/// version check: [probe]/[retire] heal the "user launched the new UI" case,
/// idle exit heals the "browser only, nobody opens the app" case.
class EasypassDaemon {
  final AppDatabase _db;
  final CryptoService _cryptoService;
  final TotpService _totpService;
  final File? _infoFile;

  /// 跨连接共享的解锁会话（C 方案）。构造时创建，测试可注入。
  final VaultSession session;

  /// 是否允许空闲自退。**只有 `--service` 模式（[runDaemon]）传 true**：
  /// UI 模式下 daemon 与 UI 同进程，退出等于把用户踢出应用，绝对不允许。
  final bool exitWhenIdle;

  /// 空闲多久后自退。默认 10 分钟，取值理由：
  /// - 必须大于会话空闲超时（默认 5 分钟，用户可设到 60 分钟）——否则正在
  ///   使用的会话会被掐断；会话仍解锁时**不**自退（见 [shouldExitWhenIdle]）；
  /// - 又要足够短，让"升级后的旧 daemon"在没人开应用时也能自己让位；
  /// - 桥接会在需要时按需重新拉起（冷启动约 1–2 秒），代价可接受。
  final Duration idleExitTimeout;

  /// 可注入时钟（测试用）。
  final DateTime Function() _clock;

  /// 判定该退时调用（由 `main.dart` 注入 `exit(0)`）。测试里注入假实现，
  /// 这样"是否该退"与"真的退出进程"可以分开验证。
  final Future<void> Function()? onIdleExit;

  ServerSocket? _server;
  String _token = '';

  /// 当前打开的连接数（握手成功后的连接；连接建立/断开都会刷新活动时间）。
  int _activeConnections = 0;

  /// 最后一次"有活动"的时间：连接建立、连接断开、处理完一个请求。
  DateTime _lastActivityAt;

  Timer? _idleTimer;

  /// 已经执行过自退（幂等保护：定时器可能在被取消前再触发一次）。
  bool _idleExitDone = false;

  /// 空闲检查间隔（`--service` 模式下生效）。
  static const Duration idleCheckInterval = Duration(seconds: 30);

  EasypassDaemon(this._db, this._cryptoService, this._totpService,
      {this._infoFile,
      VaultSession? session,
      this.exitWhenIdle = false,
      this.idleExitTimeout = const Duration(minutes: 10),
      DateTime Function()? clock,
      this.onIdleExit})
      : session = session ?? VaultSession(),
        _clock = clock ?? DateTime.now,
        _lastActivityAt = (clock ?? DateTime.now)();

  /// 活跃连接数（诊断/测试用）。
  int get activeConnections => _activeConnections;

  /// 最后一次活动时间（诊断/测试用）。
  DateTime get lastActivityAt => _lastActivityAt;

  /// 是否满足"空闲自退"条件：开关打开 + 没有活跃连接 + 会话已锁定/过期 +
  /// 空闲超过 [idleExitTimeout]。纯判断，无副作用，便于单测。
  bool get shouldExitWhenIdle {
    if (!exitWhenIdle) return false;
    // 没有"退出动作"就绝不半退出：只停监听、不结束进程 = daemon 静默失联，
    // 比不退出更糟（桥接还会一直连这个不再应答的端口）。
    if (onIdleExit == null) return false;
    if (_activeConnections > 0) return false;
    // 会话还解锁着就绝不自退：那等于擅自丢掉用户刚解开的锁。
    if (session.isUnlocked) return false;
    return _clock().difference(_lastActivityAt) >= idleExitTimeout;
  }

  /// 检查并按需执行自退：删掉**自己写的** `daemon.json`、停掉监听、回调退出。
  ///
  /// 返回是否触发了退出。定时器每 [idleCheckInterval] 调一次；测试直接调它，
  /// 配合注入的时钟就能在毫秒级验证整条路径。
  ///
  /// 幂等：一个进程只会自退一次（定时器可能在被取消前又触发一次）。
  ///
  /// 先删文件的顺序很重要：留下指向死端口的 daemon.json 正是历史上"扩展
  /// 超时"的经典原因（桥接会先连旧端口，等到超时才重试）。
  Future<bool> maybeExitWhenIdle() async {
    if (_idleExitDone) return false;
    if (!shouldExitWhenIdle) return false;
    _idleExitDone = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    await _removeInfoIfOurs();
    stop();
    await onIdleExit?.call();
    return true;
  }

  /// 探测 `daemon.json` 指向的 daemon 是否**真的可用**。
  ///
  /// 与旧版"TCP 连得上就算在跑"的区别：必须完成 token 握手并真的问一次
  /// `getStatus`，拿回它自报的 [AppConstants.bridgeProtocolVersion]；只有版本
  /// 一致才算可用。这样才认得出"升级后仍在运行的旧 daemon"—— 端口连得上、
  /// 握手也过，但它不认识新动作，只会回 `Unknown action: xxx`，扩展侧表现为
  /// "无法连接"。
  ///
  /// 纯探测：**不删文件、不杀进程**（清理与接管见 [retire]）。任何异常
  /// （连接超时、拒绝连接、JSON 损坏、token 不匹配、握手后立刻断开）都被归类为
  /// [DaemonProbeStatus.unreachable]，**绝不向启动流程抛异常**。
  static Future<DaemonProbeResult> probe({
    File? infoFile,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final file = infoFile ?? _defaultInfoFileStatic();

    final Map<String, dynamic> info;
    try {
      if (!await file.exists()) {
        return const DaemonProbeResult(DaemonProbeStatus.absent);
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const DaemonProbeResult(DaemonProbeStatus.unreachable,
            detail: 'daemon.json 不是 JSON 对象');
      }
      info = decoded;
    } catch (e) {
      return DaemonProbeResult(DaemonProbeStatus.unreachable,
          detail: 'daemon.json 读取失败（${e.runtimeType}）');
    }

    final port = info[AppConstants.daemonInfoPortKey];
    final token = info[AppConstants.daemonInfoTokenKey];
    final rawPid = info[AppConstants.daemonInfoPidKey];
    final rawVersion = info[AppConstants.daemonInfoProtocolVersionKey];
    final filePid = rawPid is int ? rawPid : null;
    final fileVersion = rawVersion is int ? rawVersion : null;

    if (port is! int || token is! String || token.isEmpty) {
      return DaemonProbeResult(DaemonProbeStatus.unreachable,
          port: port is int ? port : null,
          pid: filePid,
          fileProtocolVersion: fileVersion,
          detail: 'daemon.json 缺少 port/token');
    }

    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: timeout);
      final reader = NativeMessageReader(StreamIterator(socket));

      // 握手帧：token 不对时 daemon 直接关闭连接（read() 返回 null）。
      socket.add(NativeMessagingService.encodeMessage(
          {AppConstants.daemonInfoTokenKey: token}));
      await socket.flush();
      socket.add(NativeMessagingService.encodeMessage(
          {'requestId': 'probe', 'action': 'getStatus'}));
      await socket.flush();

      final response = await reader.read().timeout(timeout);
      if (response == null) {
        return DaemonProbeResult(DaemonProbeStatus.unreachable,
            port: port,
            pid: filePid,
            fileProtocolVersion: fileVersion,
            detail: '握手后连接被关闭（token 不匹配或对端不是 EasyPass）');
      }

      final data = response['data'];
      final liveVersion = (data is Map &&
              data[AppConstants.daemonInfoProtocolVersionKey] is int)
          ? data[AppConstants.daemonInfoProtocolVersionKey] as int
          : null;

      if (liveVersion == AppConstants.bridgeProtocolVersion) {
        return DaemonProbeResult(DaemonProbeStatus.ready,
            port: port,
            pid: filePid,
            fileProtocolVersion: fileVersion,
            liveProtocolVersion: liveVersion);
      }
      return DaemonProbeResult(DaemonProbeStatus.stale,
          port: port,
          pid: filePid,
          fileProtocolVersion: fileVersion,
          liveProtocolVersion: liveVersion,
          detail: liveVersion == null
              ? '运行中的 daemon 未回报 protocolVersion（旧版本构建）'
              : '运行中的 daemon 协议版本 $liveVersion，期望 '
                  '${AppConstants.bridgeProtocolVersion}');
    } catch (e) {
      return DaemonProbeResult(DaemonProbeStatus.unreachable,
          port: port,
          pid: filePid,
          fileProtocolVersion: fileVersion,
          detail: '探测失败（${e.runtimeType}）');
    } finally {
      socket?.destroy();
    }
  }

  /// 处理探测结果：陈旧 → 尽力结束旧进程；陈旧或残留 → 删除 daemon.json。
  ///
  /// **删文件才是关键一步**：桥接读不到 daemon.json 就会拉起新的
  /// `easypass.exe --service`，所以即使旧进程杀不掉（旧文件没有 pid、或核对
  /// 进程名不通过），扩展也会在下一次请求时切到新 daemon。
  ///
  /// 返回是否真的结束了一个旧进程（仅供日志/诊断；调用方无需依赖）。
  static Future<bool> retire(DaemonProbeResult result, {File? infoFile}) async {
    var terminated = false;
    final target = result.pid;
    if (result.status == DaemonProbeStatus.stale &&
        target != null &&
        target != pid) {
      terminated = await _terminateIfOurs(target);
    }
    if (result.needsCleanup) {
      await clearStaleInfo(infoFile: infoFile);
    }
    return terminated;
  }

  /// 只在能确认目标进程确实是本产品（`easypass.exe`）时才结束它。
  ///
  /// 为什么这么谨慎：旧版 `daemon.json` 没有 pid；即使有，pid 也可能被系统
  /// 复用给别的进程。Windows 上用 tasklist 核对映像名，任何一步失败都静默
  /// 返回 false（宁可让用户手动退出旧版，也不能杀错进程）。
  ///
  /// 注意：旧 daemon 可能就住在旧版 UI 进程里（UI 模式和 daemon 同进程），
  /// 所以这里结束的可能是"还开着的旧版 EasyPass"。这是刻意的：只有旧进程
  /// 退出，新构建才能接管那个端口。
  static Future<bool> _terminateIfOurs(int target) async {
    if (!Platform.isWindows) return false;
    if (target == pid) return false; // 绝不杀自己
    try {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'PID eq $target', '/FO', 'CSV', '/NH'],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(const Duration(milliseconds: 1500));
      final output = '${result.stdout}'.toLowerCase();
      if (!output.contains('easypass.exe')) return false;
      return Process.killPid(target);
    } catch (_) {
      return false;
    }
  }

  /// 是否已有一个**可用**的 daemon（协议版本一致且能应答）。
  ///
  /// 兼容旧调用点保留；新代码请用 [probe] / [retire]，它们能区分
  /// "陈旧"与"残留"，从而决定要不要接管。
  static Future<bool> isRunning({File? infoFile}) async =>
      (await probe(infoFile: infoFile)).isUsable;

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
  /// until the process exits (tray Exit, task end, or -- for `--service` --
  /// the idle self-exit below).
  Future<void> start() async {
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      _token = _generateToken();
      _lastActivityAt = _clock();
      await _persistInfo(server.port, _token);
      server.listen(_onConnection, onError: (_) {});
      // 只有 `--service` 进程才会空闲自退（UI 同进程模式下会踢掉用户）。
      if (exitWhenIdle && _idleTimer == null) {
        _idleTimer = Timer.periodic(idleCheckInterval, (_) {
          // 定时器回调不能 await，失败也不该冒泡（它会变成未捕获异常）。
          maybeExitWhenIdle().catchError((_) => false);
        });
      }
    } catch (e) {
      rethrow;
    }
  }


  void stop() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _server?.close();
    _server = null;
  }

  /// 删除 `daemon.json`——但**仅当它仍指向本进程**（端口 + pid 都对得上）。
  ///
  /// 防的是这种竞态：UI 模式下的 daemon 后来居上覆盖了文件，此时老的
  /// `--service` 进程空闲自退，若直接删文件就会把 UI 那个可用 daemon 的
  /// 注册信息一起删掉。
  Future<void> _removeInfoIfOurs() async {
    final file = _infoFile ?? _defaultInfoFile();
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;
      final recordedPort = decoded[AppConstants.daemonInfoPortKey];
      final recordedPid = decoded[AppConstants.daemonInfoPidKey];
      final ours = recordedPort == _server?.port && recordedPid == pid;
      if (!ours) return;
      await file.delete();
    } catch (_) {
      // 尽力而为：删不掉也不影响退出（新 daemon 启动时会覆盖）。
    }
  }

  void _touch() {
    _lastActivityAt = _clock();
  }

  Future<void> _onConnection(Socket socket) async {
    var counted = false;
    try {
      // 握手帧和后续请求共用一个**有状态** reader：bridge 可能把两帧写在同一个
      // chunk 里，逐帧新建缓冲的读法会把首个请求一起丢掉。
      final reader = NativeMessageReader(StreamIterator(socket));

      // Handshake: the first frame must carry the token.
      final handshake = await reader.read();
      if (handshake == null || handshake['token'] != _token) {
        socket.close();
        return;
      }

      // 握手成功才算活跃连接；连上就断的探测（probe/桥接探测）不占用
      // "有连接就不自退"的保护。
      counted = true;
      _activeConnections++;
      _touch();

      // A fresh service instance per bridge connection, but the **same**
      // [session]: the unlock state deliberately survives a disconnect
      // (C 方案) so the extension does not have to re-prompt the master
      // password every time the MV3 service worker restarts.
      // onActivity 让每个请求都刷新空闲计时（只报事件，不带内容）。
      final host = NativeMessagingService(_db, _cryptoService, _totpService,
          session: session, onActivity: _touch);
      await host.serve(reader, socket);
    } catch (_) {
      // Peer errors end the connection; the daemon keeps serving.
    } finally {
      if (counted) _activeConnections--;
      _touch();
      socket.close();
    }
  }

  String _generateToken() {
    final rand = Random.secure();
    return List.generate(
        32, (_) => rand.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 写入 `daemon.json`。
  ///
  /// 字段与读取方（务必一起改）：
  /// - `port` / `token`：桥接（C++）与扩展探针读取，用于连接与握手；
  /// - `protocolVersion`：本构建的 [AppConstants.bridgeProtocolVersion]，
  ///   UI 启动时用它判定"跑的是不是旧 daemon"；`probe_daemon.mjs` 会打印；
  /// - `pid`：写这个文件的进程号（UI 模式下就是 UI 进程，daemon 与 UI 同进程），
  ///   陈旧时用于尝试结束旧进程；**缺 `protocolVersion` 或 `pid` 的旧文件
  ///   一律按陈旧处理**（见 [probe] / [retire]）。
  Future<void> _persistInfo(int port, String token) async {
    final file = _infoFile ?? _defaultInfoFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      AppConstants.daemonInfoPortKey: port,
      AppConstants.daemonInfoTokenKey: token,
      AppConstants.daemonInfoProtocolVersionKey:
          AppConstants.bridgeProtocolVersion,
      AppConstants.daemonInfoPidKey: pid,
    }));
  }

  File _defaultInfoFile() {
    return _defaultInfoFileStatic();
  }
}
