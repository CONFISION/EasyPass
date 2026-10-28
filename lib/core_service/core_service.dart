// 命名参数映射到私有字段（与 core_actions.dart 同款），刻意不用 initializing formal。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/crypto/agent_key_material.dart';
import 'package:easypass/core/crypto/crypto_service.dart';
import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core/storage/secret_store.dart';
import 'package:easypass/core/storage/vault_meta_secret_store.dart';
import 'package:easypass/data/database/database.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/data/services/export_import_service.dart';
import 'package:easypass/data/services/master_password_rotation.dart';
import 'package:easypass/core_service/native_messaging_service.dart';
import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/mcp/mcp_http_server.dart';
import 'package:easypass/protocol/protocol.dart';

import 'agent_access_store.dart';
import 'agent_actions.dart';
import 'agent_pairing_store.dart';
import 'core_actions.dart';
import 'core_info.dart';
import 'core_singleton.dart';
import 'session_domains.dart';

/// 已有核心在跑：`--serve` 用它作为退出码 2 的理由（拉起方据此改连已有核心）。
class CoreAlreadyRunning implements Exception {
  CoreAlreadyRunning(this.info);

  final CoreInfo? info;

  @override
  String toString() => '已有核心在运行：${info ?? '（端口被占用）'}';
}

/// 核心服务：**唯一**持有密码库与密钥的进程。
///
/// 生命周期：`start()` → 常驻 → 只有 [shutdown]（`shutdownCore` 动作 /
/// `--shutdown` CLI）才退出。**没有空闲自退** —— 那是 v2.4 用来让旧 daemon
/// 让位的机制，现在由"客户端做版本判定 + 主动退休"取代。
class CoreService {
  CoreService._({
    required AppDatabase db,
    required SessionDomains sessions,
    required CoreActions actions,
    required NativeMessagingService bridgeService,
    required McpHttpServer mcpServer,
    required AgentAccessStore agentAccess,
    required VaultRepository agentRepository,
    required ServerSocket socket,
  })  : _db = db,
        _sessions = sessions,
        _actions = actions,
        _bridgeService = bridgeService,
        _mcpServer = mcpServer,
        _agentAccess = agentAccess,
        _agentRepository = agentRepository,
        _socket = socket;

  final AppDatabase _db;
  final SessionDomains _sessions;
  final CoreActions _actions;
  final NativeMessagingService _bridgeService;
  final McpHttpServer _mcpServer;
  final AgentAccessStore _agentAccess;
  final VaultRepository _agentRepository;
  final ServerSocket _socket;

  final List<_CoreConnection> _connections = [];
  final Completer<void> _stopped = Completer<void>();
  CoreInfo? _info;
  int _revision = 0;
  bool _shuttingDown = false;

  /// MCP 端点真实状态（不是 DB 里的开关标记）。
  String? _mcpError;

  /// 总开关切换的串行队列：快速关→开/并发 enable-disable 必须按顺序落，
  /// 否则会出现"DB 说开着、端口没监听"或孤儿监听器。
  Future<bool> _agentTransition = Future<bool>.value(true);

  /// 核心退出时完成 —— CLI 靠它把进程挂住。
  Future<void> get stopped => _stopped.future;

  int get port => _socket.port;

  CoreInfo? get info => _info;

  /// 组装并启动核心。
  ///
  /// 抛 [CoreAlreadyRunning] 表示已有核心在跑（调用方应改连它）。
  static Future<CoreService> start() async {
    final singleton = await CoreSingleton.bind();
    if (!singleton.usedFixedPort &&
        await CoreSingleton.isAnotherCoreListening()) {
      await singleton.close();
      // daemon.json 可能损坏（新异常类型）：此时"已有核心"仍成立（端口被占），
      // 只是拿不到可读的发现信息 —— 不要把这条常见路径变成未捕获崩溃。
      CoreInfo? existing;
      try {
        existing = await CoreDiscovery.read();
      } on CoreDiscoveryException {
        existing = null;
      }
      throw CoreAlreadyRunning(existing);
    }

    final db = AppDatabase();
    // 密钥材料写进库文件（D1）。注册到进程级，让既有的 `CryptoService()`
    // 构造点（导出服务、测试）拿到同一份存储。
    final store = VaultMetaSecretStore(db);
    SecretStoreRegistry.register(store);
    final cryptoService = CryptoService(secureStorage: store);

    var idleMinutes = AppConstants.autoLockTimeoutMinutes;
    try {
      idleMinutes = await cryptoService.getAutoLockMinutes();
    } catch (_) {
      // 存储读不出来时用默认值：核心不该因为一个设置读失败就起不来。
    }
    final sessions = SessionDomains(
      idleTimeout: Duration(minutes: idleMinutes.clamp(1, 60)),
    );

    final uiRepository = VaultRepository(
      db: db,
      cryptoService: cryptoService,
      keyReader: () => sessions.ui.key,
    );
    final bridgeRepository = VaultRepository(
      db: db,
      cryptoService: cryptoService,
      keyReader: () => sessions.bridge.key,
    );
    final rotation = MasterPasswordRotation(
      db: db,
      cryptoService: cryptoService,
      repository: uiRepository,
    );
    final exporter = ExportImportService(
      db,
      () => sessions.ui.key ?? (throw Exception('Vault is locked')),
      repository: uiRepository,
      cryptoService: cryptoService,
    );
    final bridgeService = NativeMessagingService(
      db,
      cryptoService,
      TotpService(),
      session: sessions.bridge,
      repository: bridgeRepository,
    );

    // 智能体域：**第三个仓储实例**，只读 `sessions.agent.key`
    // （绝不借用 ui/bridge 的会话；三域各自一份密钥副本）。
    final agentRepository = VaultRepository(
      db: db,
      cryptoService: cryptoService,
      keyReader: () => sessions.agent.key,
    );
    final pairingStore = AgentPairingStore(db);
    final agentAccess = AgentAccessStore(db);
    // 长跑进程里审计表必须边写边裁：启动时 prune 只收拾历史，运行期不裁会
    // 无限增长，"保留最近 1000 条"就成了一句空话（DDL 注释与文档都这么承诺）。
    var auditWritesSincePrune = 0;
    final agentActions = AgentActions(
      repository: agentRepository,
      sessions: sessions,
      pairingStore: pairingStore,
      agentAccess: agentAccess,
      totpService: TotpService(),
      // 审计落库：方式 2 承诺"每次访问都留日志"，内存环形缓冲重启即丢。
      auditSink: (entry) async {
        await db.insertAgentAudit(
          at: entry.at,
          pairingId: entry.pairingId,
          nickname: entry.nickname,
          mode: entry.mode,
          tool: entry.tool,
          op: entry.op,
          entryId: entry.entryId,
          entryName: entry.entryName,
          decision: entry.decision,
        );
        auditWritesSincePrune++;
        if (auditWritesSincePrune >= 100) {
          auditWritesSincePrune = 0;
          unawaited(db.pruneAgentAudit().catchError((Object _) {}));
        }
      },
    );
    final mcpServer = McpHttpServer(
      handler: McpHandler(
        authenticate: agentActions.authenticate,
        callTool: agentActions.callTool,
        // 版本只有一处来源：核心版本常量（原来这里是第 5 处硬编码）。
        serverVersion: AppConstants.coreVersion,
        // HTTP 层拒绝（Origin/Host/方法/认证）也要进审计：未认证的探测
        // 同样应该留痕，而不是只记"成功进到工具层"的调用。
        onRejected: (status, reason) {
          agentActions.recordHttpRejection('HTTP $status $reason');
        },
      ),
    );

    late final CoreService service;
    final actions = CoreActions(
      db: db,
      cryptoService: cryptoService,
      repository: uiRepository,
      rotation: rotation,
      exporter: exporter,
      totpService: TotpService(),
      sessions: sessions,
      pairingStore: pairingStore,
      agentAccess: agentAccess,
      onAgentAccessChanged: (enabled) => service._setAgentAccessEnabled(enabled),
      onAgentMcpStatus: () => service._agentAccessRuntime(),
      onIsStandingRead: agentActions.isStandingRead,
      onClearStandingRead: agentActions.clearStandingRead,
      onClearAllStandingRead: agentActions.clearAllStandingRead,
      onCancelPendingApprovals: () => agentActions.cancelPendingApprovals(),
      onDataChanged: (topics) => service._broadcastChanged(topics),
    );

    service = CoreService._(
      db: db,
      sessions: sessions,
      actions: actions,
      bridgeService: bridgeService,
      mcpServer: mcpServer,
      agentAccess: agentAccess,
      agentRepository: agentRepository,
      socket: singleton.socket,
    );

    // 方式 1 的接线：智能体发起审批 → 核心广播给 UI；UI 回应 → 解除挂起。
    agentActions.onApprovalRequested =
        (request) => service._broadcast({
              'event': Events.agentApprovalRequested,
              ...request,
            });
    // 审批结束（响应/超时/取消）也要通知 UI：否则已经失效的弹窗会一直
    // 留在屏幕上可点，用户以为还能"同意"，实际核心早已拒绝。
    agentActions.onApprovalResolved = (approvalId, decision) =>
        service._broadcast({
          'event': Events.agentApprovalResolved,
          'approvalId': approvalId,
          'decision': decision,
        });
    // 智能体写库后必须广播变更主题，否则 UI 列表不会重取（真机反馈：
    // 智能体建/删条目后界面不刷新）。
    agentActions.onDataChanged = (topics) => service._broadcastChanged(topics);
    // 每写一条审计就广播一次：审计页据此实时刷新。
    agentActions.onAuditRecorded = () =>
        service._broadcastChanged({Topics.agentAudit});
    actions.onAgentApprovalResponse = (approvalId, allow, allowStanding) =>
        agentActions.respondApproval(
          approvalId,
          allow,
          allowStandingRead: allowStanding,
        );

    await actions.refreshAuthMaterial();
    await service._listen();
    // 审计表自愈是**旁路维护**：放到监听启动之后、后台执行。
    // 之前在 _listen 之前 await：500k 行实测 prune ≈570ms，会直接推迟
    // daemon.json 写出 —— UI 等核心就绪的时间被它拖长。晚几秒裁剪没有副作用。
    unawaited(_pruneAgentAuditInBackground(db));
    return service;
  }

  /// 审计表自愈（旁路）：只保留最近 [keep] 条。
  ///
  /// 必须保持"后台、失败静默"：审计是事后可查，不是核心功能的前提；
  /// 也不能挡在 `_listen()` 之前（否则大表会拖慢 UI 就绪）。
  static Future<void> _pruneAgentAuditInBackground(AppDatabase db) async {
    try {
      await db.pruneAgentAudit();
    } catch (_) {
      // 老库还没迁移完 / 只读介质：忽略。
    }
  }

  Future<void> _listen() async {
    // 智能体接口（MCP）：**只有总开关打开、且专属密钥能解出来时才启动**。
    // 开关默认关；关着的时候端口不会被监听（不是"起来再拒绝"，是压根没开）。
    // 启动失败不阻塞核心——核心的主业是保险库；失败时 daemon.json 里没有
    // mcpPort，客户端据此知道"这个核心不支持 MCP"。
    int? mcpPort;
    if (await _agentAccess.isEnabled()) {
      if (await _autoUnsealAgent()) {
        mcpPort = await _startMcpListener();
        if (mcpPort == null) {
          stderr.writeln(
            'easypass_core: 智能体访问已开启，但 MCP 端点启动失败'
            '（${_mcpError ?? '未知原因'}）；MCP 未启动',
          );
        }
      } else {
        stderr.writeln(
          'easypass_core: 智能体访问已开启，但专属密钥不可用'
          '（换过 Windows 账户/机器，或文件损坏）；MCP 未启动',
        );
      }
    }
    _info = CoreInfo(
      port: _socket.port,
      token: _generateToken(),
      pid: pid,
      protocolVersion: coreProtocolVersion,
      coreVersion: AppConstants.coreVersion,
      exe: Platform.resolvedExecutable,
      mcpPort: mcpPort,
    );
    await CoreDiscovery.write(_info!);

    _sessions.onStateChanged = (domain, unlocked) {
      _broadcast({
        'event': unlocked ? Events.sessionUnlocked : Events.sessionLocked,
        'domain': domain.name,
      });
    };
    _sessions.start();

    _socket.listen(
      _onConnection,
      onError: (Object _) {
        // 单个 accept 失败不该让核心倒下。
      },
    );

    stderr.writeln(
      'easypass_core: serving on 127.0.0.1:${_socket.port} '
      '(pid=$pid, protocol=$coreProtocolVersion, version=${AppConstants.coreVersion})',
    );
  }

  /// 启动 MCP 监听：**只绑固定端口 47821，失败即不启动**。
  ///
  /// 为什么不退化为临时端口：MCP 客户端把端点写死在自己的配置里，端口一变
  /// 客户端必然连不上；更糟的是，若 47821 被本机其他进程占用，客户端会把
  /// `Authorization: Bearer <配对密钥>` 发给那个占用者 —— 等于把凭据投递出去。
  /// 因此这里必须 fail closed，并由 UI 把"端口被占用/启动失败"明确告诉用户。
  ///
  /// 返回 null 表示启动失败（不影响核心其它功能）。
  Future<int?> _startMcpListener() async {
    if (_mcpServer.isRunning) return _mcpServer.port;
    try {
      final port = await _mcpServer.start(port: AppConstants.coreMcpFixedPort);
      _mcpError = null;
      return port;
    } catch (error) {
      _mcpError = 'MCP 固定端口 ${AppConstants.coreMcpFixedPort} 不可用：$error';
      stderr.writeln('easypass_core: $_mcpError');
      return null;
    }
  }

  /// 总开关变化：串行执行，返回 **MCP 端点是否真的在运行**。
  ///
  /// 旧实现是 fire-and-forget 的 `void` 回调：快速关→开或并发 enable/disable
  /// 会落成"DB 说开着、端口没监听"或孤儿监听器。这里用 Future 链把状态转换
  /// 串行化，并把真实结果回给 CoreActions（失败时它负责回滚开关）。
  Future<bool> _setAgentAccessEnabled(bool enabled) {
    final next = _agentTransition.then((_) => _applyAgentAccess(enabled));
    // 链上保留一个吞异常的占位，避免一次失败让后续转换全部短路。
    _agentTransition = next.then((_) => true, onError: (Object _) => false);
    return next;
  }

  Future<bool> _applyAgentAccess(bool enabled) async {
    if (enabled) {
      final port = await _startMcpListener();
      await _persistMcpPort(port);
      return port != null;
    }
    await _mcpServer.stop();
    _mcpError = null;
    await _persistMcpPort(null);
    return true;
  }

  /// 供 `getAgentAccessState` 查询的 MCP 真实运行态（不是 DB 开关标记）。
  Map<String, Object?> _agentAccessRuntime() => {
        'mcpRunning': _mcpServer.isRunning,
        'mcpPort': _mcpServer.isRunning ? _mcpServer.port : null,
        if (_mcpError != null) 'mcpError': _mcpError,
      };

  Future<void> _persistMcpPort(int? mcpPort) async {
    final info = _info;
    if (info == null) return; // 还没开始监听：_listen 会带着新值写。
    _info = CoreInfo(
      port: info.port,
      token: info.token,
      pid: info.pid,
      protocolVersion: info.protocolVersion,
      coreVersion: info.coreVersion,
      exe: info.exe,
      mcpPort: mcpPort,
    );
    try {
      await CoreDiscovery.write(_info!);
    } catch (error) {
      // 运行时写发现文件失败不该崩掉核心：端口状态仍以内存为准，
      // 下一次成功写入会自愈（stderr 留痕便于排查）。
      stderr.writeln('easypass_core: 写入 daemon.json 失败：$error');
    }
  }

  /// 核心启动时自动解封智能体域（**零介入**）。
  ///
  /// 链路：DPAPI 读出专属密钥 → 用它解包 `vault_meta` 里的 wrapped vaultKey
  /// → **校验这把钥匙确实属于当前库** → 解锁 agent 域。
  ///
  /// 为什么必须校验：改密是"整库重加密 + 重包裹"两步，若在两者之间崩溃/断电，
  /// DB 里可能留着**旧钥匙**的包裹。只验 DPAPI/MAC 的话旧钥匙会照常解封、
  /// MCP 照常启动，agent 用旧钥匙写入的数据将永久解不开（两个密码都解不开）。
  /// 校验不通过时 fail closed：不启动 MCP，也不 wipe（用户可用"重置智能体
  /// 密钥"恢复）。绝不回退到弱存储。
  Future<bool> _autoUnsealAgent() async {
    try {
      final wrapped = await _agentAccess.readWrap();
      final agentKey = await _agentAccess.loadAgentKey();
      if (wrapped == null || agentKey == null) return false;
      final vaultKey =
          AgentKeyMaterial.unwrap(blob: wrapped, agentKey: agentKey);
      try {
        final expectedKeyId = await _db.getMeta('vault.keyId');
        if (expectedKeyId != null && expectedKeyId.isNotEmpty) {
          final actualKeyId = AgentKeyMaterial.keyId(vaultKey);
          if (actualKeyId != expectedKeyId) {
            stderr.writeln(
              'easypass_core: 智能体包裹的密钥与当前库不匹配'
              '（疑似改密中断）；MCP 未启动，请在设置里重置智能体密钥',
            );
            return false;
          }
        } else {
          // 旧库没有 keyId：用一次真实解密探测。空库无法证明，按 fail closed
          // 处理（用户重新开关一次智能体访问即可写入 keyId）。
          final rows = await _db.getAllEntries();
          if (rows.isEmpty) {
            stderr.writeln(
              'easypass_core: 缺少 vault.keyId 且库为空，无法验证智能体密钥；'
              'MCP 未启动，请重新开关智能体访问',
            );
            return false;
          }
          final probe = Uint8List.fromList(vaultKey);
          try {
            // 用**严格**探测：没有 keyId 的旧库只能靠"至少一行真能解开"来
            // 证明包裹里的钥匙属于当前库。宽容版 encryptionProbeWorks 在
            // "一行都解不开"时返回 true，会把旧钥匙放进来（评审 V-1）。
            final works =
                await _agentRepository.encryptionProbeWorksStrict(probe);
            if (!works) {
              stderr.writeln(
                'easypass_core: 智能体包裹的密钥无法验证/解开当前库；'
                'MCP 未启动，请在设置里重置智能体密钥或重新开关智能体访问',
              );
              return false;
            }
          } finally {
            probe.fillRange(0, probe.length, 0);
          }
        }
        _sessions.agent.unlock(Uint8List.fromList(vaultKey));
      } finally {
        vaultKey.fillRange(0, vaultKey.length, 0);
        agentKey.fillRange(0, agentKey.length, 0);
      }
      return true;
    } catch (error) {
      stderr.writeln('easypass_core: 智能体密钥解封失败：$error');
      return false;
    }
  }

  String _generateToken() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _onConnection(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final reader = NativeMessageReader(StreamIterator<List<int>>(socket.cast<List<int>>()));
    _CoreConnection? connection;
    try {
      // ─── 协议 5 的四步握手（令牌永不上线）───────────────
      final step1 = await reader.read();
      if (step1 == null) {
        socket.destroy();
        return;
      }
      final info = _info!;
      final clientNonce = step1['clientNonce'] as String?;

      // ── v4 明文 token 握手：**只允许 bridge 角色** ──
      //
      // 为什么保留：Windows 的 x86 桥是 C++ 纯字节转发器（32 位浏览器的
      // stdio 句柄限制决定了它必须是 32 位控制台程序），在里面实现 AES/HMAC
      // 不划算。桥↔核心之间仍是本机回环 + 令牌认证，属于另一个信任边界。
      //
      // **UI 角色永远走不到这里**：显式传 ui/agent 一律拒绝 —— 这就是
      // "核心与 UI 之间禁止明文传输"的强制点（见 tool/probe_channel_security.dart）。
      if (step1.containsKey('token') && clientNonce == null) {
        final requestedRole = (step1['role'] as String?) ?? 'bridge';
        // **不对 protocolVersion 设门槛**：C++ x86 桥发的就是 `{"token":"..."}`，
        // 不带版本（它只是字节转发器，不理解协议内容），而它承载的动作形状
        // 自协议 3 起就冻结了。版本谈判是**客户端**的职责，不是桥的。
        if (requestedRole != 'bridge' || step1['token'] != info.token) {
          socket.add(encodeMessage({
            'ok': false,
            'error': requestedRole != 'bridge'
                ? ErrorCodes.unsupported
                : ErrorCodes.unauthorized,
            'coreVersion': AppConstants.coreVersion,
            'protocolVersion': coreProtocolVersion,
            'hint': 'role "$requestedRole" must use the encrypted handshake',
          }));
          await socket.flush();
          socket.destroy();
          return;
        }
        connection = _CoreConnection(
          socket: socket,
          reader: reader,
          role: 'bridge',
          channel: null,
        );
        _connections.add(connection);
        socket.add(encodeMessage({
          'ok': true,
          'coreVersion': AppConstants.coreVersion,
          'protocolVersion': coreProtocolVersion,
          'role': 'bridge',
          'encrypted': false,
          'capabilities': CoreCapabilities.all,
        }));
        await socket.flush();
        while (!_shuttingDown) {
          final message = await reader.read();
          if (message == null) break;
          final response = await _dispatch(connection, message);
          if (response != null) {
            socket.add(encodeMessage(response));
            await socket.flush();
          }
        }
        return;
      }

      // 不是 v5 客户端（旧桥 / 垃圾帧）：明确拒绝，让对端升级，绝不降级成明文。
      if (step1['hello'] != 'easypass' || clientNonce == null) {
        socket.add(encodeMessage({
          'ok': false,
          'error': ErrorCodes.unsupported,
          'coreVersion': AppConstants.coreVersion,
          'protocolVersion': coreProtocolVersion,
        }));
        await socket.flush();
        socket.destroy();
        return;
      }

      final role = (step1['role'] as String?) ?? 'bridge';
      // 角色必须在白名单里，且判定只有一个来源（`Actions.allowedFor`）。
      // 不能等 `_dispatch` 才拒绝：那会把"未知角色继承 bridge 权限"的窗口
      // 留到握手之后 —— 能连上就等于已经有权限了。
      if (!Actions.isKnownRole(role)) {
        socket.add(encodeMessage({
          'ok': false,
          'error': ErrorCodes.unsupported,
          'coreVersion': AppConstants.coreVersion,
          'protocolVersion': coreProtocolVersion,
          'hint': 'unknown role "$role"',
        }));
        await socket.flush();
        socket.destroy();
        return;
      }
      final clientProtocol = (step1['protocolVersion'] as num?)?.toInt() ?? 0;
      if (clientProtocol < coreProtocolVersion) {
        socket.add(encodeMessage({
          'ok': false,
          'error': ErrorCodes.unsupported,
          'coreVersion': AppConstants.coreVersion,
          'protocolVersion': coreProtocolVersion,
        }));
        await socket.flush();
        socket.destroy();
        return;
      }

      // 第 2 步：出 serverNonce + 证明自己知道令牌。
      final serverNonce = SecureChannelCrypto.randomNonce();
      socket.add(encodeMessage({
        'serverNonce': serverNonce,
        'serverProof': SecureChannelCrypto.serverProof(
          token: info.token,
          clientNonce: clientNonce,
          serverNonce: serverNonce,
        ),
        'coreVersion': AppConstants.coreVersion,
        'protocolVersion': coreProtocolVersion,
      }));
      await socket.flush();

      // 第 3 步：验客户端证明（没有令牌的进程到不了这里）。
      final step3 = await reader.read();
      final clientProof = step3?['clientProof'] as String?;
      if (clientProof == null) {
        socket.destroy();
        return;
      }
      final expectedProof = SecureChannelCrypto.clientProof(
        token: info.token,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      );
      if (!SecureChannelCrypto.proofsMatch(clientProof, expectedProof)) {
        socket.add(encodeMessage({'ok': false, 'error': ErrorCodes.unauthorized}));
        await socket.flush();
        socket.destroy();
        return;
      }

      // 第 4 步：握手完成，之后全程加密。
      final channel = SecureChannel(SecureChannelCrypto.deriveKeys(
        token: info.token,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
      ));
      connection = _CoreConnection(
        socket: socket,
        reader: reader,
        role: role,
        channel: channel,
      );
      _connections.add(connection);
      // 第 4 步**也是密文**：握手之后的第一帧就用派生密钥加密，明文里只剩
      // nonce 与 HMAC 证明（不含令牌、不含能力表、不含任何业务字段）。
      socket.add(encodePayload(channel.seal({
        'ok': true,
        'coreVersion': AppConstants.coreVersion,
        'protocolVersion': coreProtocolVersion,
        'role': role,
        'capabilities': CoreCapabilities.all,
      }, fromClient: false)));
      await socket.flush();

      while (!_shuttingDown) {
        final frame = await reader.readBytes();
        if (frame == null) break;
        final message = channel.open(frame, fromClient: true);
        final response = await _dispatch(connection, message);
        if (response != null) {
          socket.add(encodePayload(channel.seal(response, fromClient: false)));
          await socket.flush();
        }
      }
    } catch (_) {
      // 对端断开 / 认证失败 / 协议错误：结束这条连接，核心继续服务。
    } finally {
      if (connection != null) _connections.remove(connection);
      try {
        socket.destroy();
      } catch (_) {
        // 已经断开。
      }
    }
  }

  Future<Map<String, dynamic>?> _dispatch(
    _CoreConnection connection,
    Map<String, dynamic> message,
  ) async {
    final requestId = message['requestId'];
    final action = message['action'] as String?;
    if (action == null) {
      return {
        'requestId': requestId,
        'error': ErrorMessages.invalidRequest,
        'errorCode': ErrorCodes.invalidRequest,
      };
    }

    // 三分支：ui / bridge / agent 各自一份白名单，**未知角色一律拒绝**。
    // 旧的二分支写法（`ui` 否则 `bridge`）会让任何新角色默认继承 bridge 的
    // 全部权限，包括 `unlock` / `getTotp` / `shutdownCore`。
    final allowed = Actions.allowedFor(connection.role);
    if (allowed == null) {
      return {
        'requestId': requestId,
        'error': 'Unknown role: ${connection.role}',
        'errorCode': ErrorCodes.unsupported,
      };
    }
    if (!allowed.contains(action)) {
      return {
        'requestId': requestId,
        'error': 'Unsupported action for role ${connection.role}: $action',
        'errorCode': ErrorCodes.unsupported,
      };
    }

    if (action == Actions.shutdownCore) {
      unawaited(Future<void>.delayed(
        const Duration(milliseconds: 50),
        shutdown,
      ));
      return {
        'requestId': requestId,
        'data': {'ok': true},
      };
    }

    try {
      if (connection.role == 'ui') {
        final params = _flattenParams(message);
        final data = await _actions.handle(action, params);
        return {'requestId': requestId, 'data': data};
      }
      // bridge 域：沿用既有实现（形状冻结、有既有测试网）。
      return await _bridgeService.handleRequest(message);
    } on CoreActionException catch (error) {
      return {
        'requestId': requestId,
        'error': error.message,
        'errorCode': error.code,
      };
    } catch (error) {
      return {
        'requestId': requestId,
        'error': error.toString(),
        'errorCode': ErrorCodes.internal,
      };
    }
  }

  /// 参数既支持平铺（`{action, id}`，与桥接协议一致）也支持 `params` 包裹。
  Map<String, dynamic> _flattenParams(Map<String, dynamic> message) {
    final rawParams = message['params'];
    if (rawParams is Map) {
      return {...message, ...Map<String, dynamic>.from(rawParams)};
    }
    return message;
  }

  void _broadcastChanged(Set<String> topics) {
    for (final topic in topics) {
      _broadcast({
        'event': Events.changed,
        'topic': topic,
        'revision': ++_revision,
      });
    }
  }

  void _broadcast(Map<String, dynamic> event) {
    if (_connections.isEmpty) return;
    // 每条连接用自己的方向密钥加密 —— 不能复用同一份密文。
    for (final connection in List<_CoreConnection>.from(_connections)) {
      final channel = connection.channel;
      if (channel == null) continue; // 明文桥不订阅事件
      try {
        connection.socket.add(
          encodePayload(channel.seal(event, fromClient: false)),
        );
      } catch (_) {
        // 连接正在断开：忽略，由它自己的循环收尾。
      }
    }
  }

  /// 停机：广播 → 关连接 → 关监听 → 删发现文件 → 关库。
  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _broadcast({'event': Events.coreShuttingDown});
    _sessions.stop();
    // 先关智能体端点：它的 handler 会用到仓储与会话，必须在关库之前停。
    await _mcpServer.stop();
    for (final connection in List<_CoreConnection>.from(_connections)) {
      try {
        connection.socket.destroy();
      } catch (_) {
        // 已经断开。
      }
    }
    _connections.clear();
    try {
      await _socket.close();
    } catch (_) {
      // 已经关闭。
    }
    final info = _info;
    if (info != null) await CoreDiscovery.removeIfOurs(info);
    try {
      await _db.close();
    } catch (_) {
      // 已经关闭。
    }
    stderr.writeln('easypass_core: stopped (pid=$pid)');
    if (!_stopped.isCompleted) _stopped.complete();
  }
}

class _CoreConnection {
  _CoreConnection({
    required this.socket,
    required this.reader,
    required this.role,
    required this.channel,
  });

  final Socket socket;
  final NativeMessageReader reader;
  final String role;

  /// 每条连接各自的加密信道（nonce 不同 ⇒ 密钥不同）。
  final SecureChannel? channel;
}
