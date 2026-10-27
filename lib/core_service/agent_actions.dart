// 命名参数用可读的公开名映射到私有字段（与 core_actions.dart / core_service.dart
// 同款），刻意不用 initializing formal。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core/platform/system_clipboard.dart';
import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/core_service/core_actions.dart' show generatePassword;
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/models/entry_fields.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/protocol/codecs.dart';
import 'package:easypass/protocol/events.dart';
import 'package:uuid/uuid.dart';

/// 一次显式操作窗口（批量操作"提前沟通"的载体）。
class AgentWindow {
  const AgentWindow({
    required this.id,
    required this.purpose,
    required this.startedAt,
    required this.expiresAt,
  });

  final String id;
  final String purpose;
  final int startedAt;
  final int expiresAt;

  bool isActiveAt(int now) => now < expiresAt;

  Map<String, Object?> toJson(int now) => {
        'purpose': purpose,
        'remainingSeconds': ((expiresAt - now) / 1000).ceil().clamp(0, 1 << 30),
      };
}

/// 一条审计记录。**只记昵称**，不记密钥、不记真实标识、不记明文参数（I-10）。
class AgentAuditEntry {
  const AgentAuditEntry({
    required this.at,
    required this.pairingId,
    required this.nickname,
    required this.mode,
    required this.tool,
    required this.op,
    this.entryId,
    this.entryName,
    required this.decision,
  });

  final int at;

  /// 配对的内部 id。**只进库、不进模型上下文**（模型只看昵称）。
  final String pairingId;
  final String nickname;
  final String mode;
  final String tool;
  final String op;
  final String? entryId;
  final String? entryName;

  /// `allowed` / `allowed_standing` / `denied` / `timeout` / `error`。
  final String decision;

  Map<String, Object?> toJson() => {
        'at': at,
        'nickname': nickname,
        'mode': mode,
        'tool': tool,
        'op': op,
        if (entryId != null) 'entryId': entryId,
        if (entryName != null) 'entryName': entryName,
        'decision': decision,
      };
}

/// 智能体工具面的实现：**认证 + 授权 + 执行**的唯一入口。
///
/// 两条原则：
/// 1. 授权判定只有一个实现（[AgentAccessPolicy]），本类只负责"把事实算好"；
/// 2. 智能体只经 `sessions.agent` 的密钥解密（第三个仓储实例），**绝不借用 ui 域**。
///
/// 阶段 1 的限制（诚实记录）：方式 1（逐次审批）的审批 UI 在下一阶段才落地，
/// 所以本阶段方式 1 的配对只能拿到 `notApproved`；能真正读出数据的是方式 2
/// （可信直通）。这不是漏洞，是 fail closed。
class AgentActions {
  AgentActions({
    required VaultRepository repository,
    required SessionDomains sessions,
    required AgentPairingStore pairingStore,
    required AgentAccessStore agentAccess,
    required TotpService totpService,
    Future<bool> Function(String text)? clipboardWriter,
    Future<void> Function(AgentAuditEntry entry)? auditSink,
    DateTime Function()? clock,
    int auditCapacity = 200,
  })  : _repository = repository,
        _sessions = sessions,
        _pairingStore = pairingStore,
        _agentAccess = agentAccess,
        _totpService = totpService,
        _clipboardWriter = clipboardWriter ?? SystemClipboard.writeText,
        _auditSink = auditSink,
        _clock = clock ?? DateTime.now,
        _auditCapacity = auditCapacity;

  final VaultRepository _repository;
  final SessionDomains _sessions;
  final AgentPairingStore _pairingStore;
  final AgentAccessStore _agentAccess;
  final TotpService _totpService;

  /// 剪贴板写入（可注入：单测不要真的动系统剪贴板，否则并行用例会互相抢）。
  final Future<bool> Function(String text) _clipboardWriter;

  /// 审计落库回调（生产环境由核心接到 `agent_audit` 表；测试可注入假实现）。
  ///
  /// 为什么要有它：方式 2 对用户的承诺是"每次访问都留日志"，内存环形缓冲
  /// 重启即丢，等于没兑现。落库失败**不能**让工具调用失败（审计是旁路），
  /// 因此这里吞掉异常，只在内存里保底。
  final Future<void> Function(AgentAuditEntry entry)? _auditSink;
  final DateTime Function() _clock;
  final int _auditCapacity;

  /// 窗口 TTL 边界（§6.7）。
  static const int windowTtlDefaultSeconds = 300;
  static const int windowTtlMaxSeconds = 1800;
  static const int windowTtlMinSeconds = 30;

  /// 单次 `list_entries` 的条数上限。
  static const int listDefaultLimit = 50;
  static const int listMaxLimit = 200;

  AgentWindow? _window;

  /// 方式 1 的"本会话内允许读取"（按配对 id）。仅对**普通读**生效，
  /// 敏感读（明文/验证码/剪贴板）与写删一律每次都要同意。
  final Set<String> _standingRead = <String>{};

  /// 待用户回应的审批请求（`approvalId` → 结果）。
  final Map<String, Completer<bool>> _pendingApprovals = {};

  /// 审批请求归属的配对与"是否允许勾选本会话免询问"。
  final Map<String, String> _pendingPairing = {};
  final Map<String, bool> _pendingAllowStanding = {};

  /// 当前正在执行的工具名（诊断/审计用；审批请求由各工具显式传 tool）。
  String _currentTool = '';

  String get currentTool => _currentTool;

  /// 本次 `tools/call` 是否已经写过审计行。
  ///
  /// 用途只有一个：失败落 `error` 之前先看它 —— 拒绝 / 超时 / 成功路径都各自
  /// 写过审计，不能因为异常再补一行重复记录（审计的准则是"一次调用一行"）。
  bool _auditedThisCall = false;

  /// 失败审计用的条目上下文：工具在拿到条目之后立刻更新，
  /// 于是 `notFound` / `denied` / 写入失败都能在审计里指出"动的是哪一条"。
  String? _errorEntryId;
  String? _errorEntryName;

  static const Uuid _uuid = Uuid();

  /// 审批超时：必须短于客户端自己的 `tools/call` 超时（DSH 默认 60s），
  /// 否则客户端先超时、用户随后点"同意"就成了对没人等待的调用授权。
  static const Duration approvalTimeout = Duration(seconds: 45);

  /// 向 UI 广播审批请求的钩子（核心把它接到 `_broadcast`）。
  void Function(Map<String, Object?> request)? onApprovalRequested;

  /// 写操作成功后的**变更广播**钩子（核心接到 `_broadcastChanged`）。
  ///
  /// 没有它会有真机可见的 bug：智能体新建/修改/删除/恢复条目后，UI 的
  /// `coreSnapshotStream` 收不到主题、列表不重取 —— 用户看到的还是旧列表。
  void Function(Set<String> topics)? onDataChanged;

  /// 每写入一条审计后触发（设置/侧边栏的"智能体活动"页据此实时刷新）。
  void Function()? onAuditRecorded;

  void _notifyDataChanged() => onDataChanged?.call({
        Topics.items,
        Topics.item,
        Topics.folders,
        Topics.search,
      });

  /// UI 的回应入口（`CoreActions.respondAgentApproval` 调它）。
  ///
  /// [allowStandingRead] 只在"本次是普通读、且该请求允许免询问"时才生效 ——
  /// 核心侧再判一次，不信任 UI 传来的标志。
  bool respondApproval(
    String approvalId,
    bool allow, {
    bool allowStandingRead = false,
  }) {
    final completer = _pendingApprovals.remove(approvalId);
    if (completer == null || completer.isCompleted) {
      _pendingPairing.remove(approvalId);
      _pendingAllowStanding.remove(approvalId);
      return false;
    }
    final pairingId = _pendingPairing.remove(approvalId);
    final standingAllowed = _pendingAllowStanding.remove(approvalId) ?? false;
    if (allow && allowStandingRead && standingAllowed && pairingId != null) {
      _standingRead.add(pairingId);
    }
    completer.complete(allow);
    return true;
  }

  /// 某配对是否已获得"本会话内免询问读取"（UI 用它显示可撤销指示）。
  bool isStandingRead(String pairingId) => _standingRead.contains(pairingId);

  /// 撤销"本会话内免询问读取"。
  void clearStandingRead(String pairingId) => _standingRead.remove(pairingId);

  /// 清空所有免询问状态（锁定 / 关总开关 / 换方式时调用）。
  void clearAllStandingRead() => _standingRead.clear();

  /// 发一次审批并等待；超时按**拒绝**处理（fail closed）。
  Future<bool> _requestApproval(
    AgentPairing pairing, {
    required AgentOp op,
    required String toolName,
    required bool allowStandingOption,
    String? entryId,
    String? entryName,
    String? detail,
  }) async {
    final sink = onApprovalRequested;
    // 没有 UI 可问（例如核心以无 UI 方式运行）⇒ 直接拒绝，绝不放行。
    if (sink == null) return false;

    final approvalId =
        'a_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}'
        '_${_pendingApprovals.length}';
    final completer = Completer<bool>();
    _pendingApprovals[approvalId] = completer;
    _pendingPairing[approvalId] = pairing.id;
    _pendingAllowStanding[approvalId] = allowStandingOption;

    sink({
      'approvalId': approvalId,
      'nickname': _nicknameOf(pairing),
      'tool': toolName,
      'op': _opLabel(op),
      'entryId': entryId,
      'entryName': entryName,
      'allowStanding': allowStandingOption,
      // 写/删的"详细"：**只列字段名与动作**，绝不含值 —— 弹窗必须说清
      // "要做什么"，但没理由把待写入的密码送到屏幕上（§10 的落地口径）。
      'detail': ?detail,
    });

    bool allowed;
    try {
      allowed = await completer.future.timeout(approvalTimeout);
    } on TimeoutException {
      allowed = false;
      _auditAdd(
        principal: McpPrincipal(
          pairingId: pairing.id,
          nickname: _nicknameOf(pairing),
        ),
        mode: pairing.mode,
        tool: toolName,
        op: _opLabel(op),
        decision: 'timeout',
        entryId: entryId,
        entryName: entryName,
      );
    } finally {
      _pendingApprovals.remove(approvalId);
      _pendingPairing.remove(approvalId);
      _pendingAllowStanding.remove(approvalId);
    }
    return allowed;
  }

  static String _opLabel(AgentOp op) => switch (op) {
        AgentOp.read => 'read',
        AgentOp.sensitiveRead => 'sensitiveRead',
        AgentOp.write => 'write',
        AgentOp.delete => 'delete',
      };

  String _nicknameOf(AgentPairing pairing) =>
      pairing.nickname.trim().isEmpty ? '未命名智能体' : pairing.nickname;

  final Queue<AgentAuditEntry> _audit = Queue<AgentAuditEntry>();

  AgentWindow? get window => _window;

  List<AgentAuditEntry> get recentAudit => List.unmodifiable(_audit);

  int get _now => _clock().millisecondsSinceEpoch;

  /// 供 `McpHandler` 用：按明文密钥认证，返回最小身份（只有昵称对外）。
  Future<McpPrincipal?> authenticate(String key) async {
    final pairing = await _pairingStore.findByKey(key);
    if (pairing == null) return null;
    if (pairing.isRevoked) return null;
    if (pairing.isExpiredAt(_now)) return null;
    return McpPrincipal(
      pairingId: pairing.id,
      nickname: pairing.nickname.trim().isEmpty ? '未命名智能体' : pairing.nickname,
    );
  }

  /// 供 `McpHandler` 用：工具执行入口。
  Future<Map<String, Object?>> callTool(
    McpPrincipal principal,
    String tool,
    Map<String, Object?> args,
  ) async {
    final pairing = await _pairingStore.findById(principal.pairingId);
    if (pairing == null || pairing.isRevoked) {
      throw McpToolException('unauthorized', '配对不存在或已撤销');
    }
    _currentTool = tool;
    // 每次调用重置审计上下文：一次调用最多一行审计（见 _auditErrorIfNeeded）。
    _auditedThisCall = false;
    _errorEntryId = (args['id'] as String?)?.trim();
    if (_errorEntryId != null && _errorEntryId!.isEmpty) _errorEntryId = null;
    _errorEntryName = null;

    try {
      switch (tool) {
        case 'status':
          return await _status(pairing, principal);
        case 'begin_session':
          return await _beginSession(pairing, principal, args);
        case 'end_session':
          return await _endSession(pairing, principal);
        case 'list_entries':
          return await _listEntries(pairing, principal, args);
        case 'get_entry':
          return await _getEntry(pairing, principal, args);
        case 'copy_to_clipboard':
          return await _copyToClipboard(pairing, principal, args);
        case 'create_entry':
          return await _createEntry(pairing, principal, args);
        case 'update_entry':
          return await _updateEntry(pairing, principal, args);
        case 'delete_entry':
          return await _deleteEntry(pairing, principal, args);
        case 'list_trash':
          return await _listTrash(pairing, principal);
        case 'restore_entry':
          return await _restoreEntry(pairing, principal, args);
        default:
          throw McpToolException('invalidRequest', '未知工具：$tool');
      }
    } on McpToolException {
      _auditErrorIfNeeded(principal, pairing, tool);
      rethrow;
    } catch (_) {
      _auditErrorIfNeeded(principal, pairing, tool);
      rethrow;
    } finally {
      // 方式 1 借来的钥匙只活这一次调用：无论成功失败都锁回去。
      _releaseBorrowedKeyIfAny();
    }
  }

  // ─── 工具 ──────────────────────────────────────────────

  Future<Map<String, Object?>> _status(
    AgentPairing pairing,
    McpPrincipal principal,
  ) async {
    final unlocked = _sessions.agent.isUnlocked;
    // **不是**"此刻能读几条"，而是"开放了几条"：
    // 方式 1 下 status 本身不走审批（否则每个客户端一上来都要用户点一次
    // "允许查询状态"），所以这里必须用"假设已获同意"的口径来数 ——
    // 早先用 _visibleItems 数出来恒为 0，对客户端就像"库是空的"。
    final visible = unlocked ? await _openItemCount(pairing) : 0;
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'status',
      op: 'read',
      decision: 'allowed',
    );
    return {
      'nickname': principal.nickname,
      'mode': pairing.mode.name,
      'locked': !unlocked,
      'entryCount': visible,
      'window': _window?.toJson(_now),
      'serverTime': _now,
    };
  }

  /// 当前配对"开放且在其 scope 内"的条目数。
  ///
  /// 判定口径 = 假设本次已获用户同意（`approvedThisCall: true`）：
  /// - 方式 1：条目开关 + scope 即可（审批是每次调用的事，不影响"开放了几条"）；
  /// - 方式 2：仍然要求配对是 `trusted`，未认证的配对看到 0。
  Future<int> _openItemCount(AgentPairing pairing) async {
    if (pairing.isRevoked || pairing.isExpiredAt(_now)) return 0;
    if (!_sessions.agent.isUnlocked) return 0;
    final items = await _repository.getItems();
    var count = 0;
    for (final item in items) {
      final result = AgentAccessPolicy.evaluate(AgentAccessRequest(
        op: AgentOp.read,
        entryOpen: item.agentOpen,
        revoked: false,
        expired: false,
        sessionUnlocked: true,
        inScope: _inScope(pairing, item),
        mode: pairing.mode,
        trusted: pairing.trusted,
        approvedThisCall: true,
        standingRead: true,
      ));
      if (result.allowed) count++;
    }
    return count;
  }

  Future<Map<String, Object?>> _beginSession(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final purpose = (args['purpose'] as String? ?? '').trim();
    if (purpose.isEmpty) {
      throw McpToolException('invalidRequest', 'purpose 必填');
    }
    final rawTtl = (args['ttlSeconds'] as num?)?.toInt() ?? windowTtlDefaultSeconds;
    final ttl = rawTtl.clamp(windowTtlMinSeconds, windowTtlMaxSeconds);
    await _gate(pairing, principal, tool: 'begin_session');

    final now = _now;
    _window = AgentWindow(
      id: 'w_${now.toRadixString(16)}',
      purpose: purpose,
      startedAt: now,
      expiresAt: now + ttl * 1000,
    );
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'begin_session',
      op: 'read',
      decision: _allowedDecision,
    );
    return {'windowId': _window!.id, 'expiresAt': _window!.expiresAt};
  }

  Future<Map<String, Object?>> _endSession(
    AgentPairing pairing,
    McpPrincipal principal,
  ) async {
    // `end_session` 只结束**批量窗口**，不锁 agent 域。
    //
    // 为什么（真机实测踩过）：总开关打开的语义是"用户零介入、永久允许"。
    // 早先这里无条件 `_sessions.agent.lock()`，于是 agent 调一次 end_session
    // 就把自己永久锁死 —— 而自动解封只发生在核心启动/打开开关时，
    // 之后再也解不开，直到用户重启核心。那不是"会话结束"，那是自断经脉。
    //
    // 真正的锁时机只有三个：关掉总开关 / 用户在界面点"锁定智能体会话" / 核心退出。
    // 这里只在总开关已关闭时兜底锁一下（防御性，正常走不到）。
    if (!await _isAccessEnabled()) {
      _sessions.agent.lock();
    }
    _window = null;
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'end_session',
      op: 'read',
      decision: 'allowed',
    );
    return {'ok': true};
  }

  Future<Map<String, Object?>> _listEntries(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    await _gate(pairing, principal, tool: 'list_entries');
    final query = (args['query'] as String? ?? '').trim();
    final folders = await _folderNames();
    // **不传 type 就是"全部类型"**：`EntryType.fromWire(null)` 会回退成 login，
    // 直接用它会把"没筛选"当成"只看登录条目"（真机实测：status 数到 2 条，
    // list_entries 只回 1 条）。folder 同理：空串等于不筛。
    final rawType = (args['type'] as String?)?.trim();
    final rawFolder = (args['folder'] as String?)?.trim();
    final type =
        (rawType == null || rawType.isEmpty) ? null : EntryType.fromWire(rawType);
    final folderId = (rawFolder == null || rawFolder.isEmpty) ? null : rawFolder;
    final items = await _visibleItems(
      pairing,
      type: type,
      folderId: folderId,
      query: query,
    );

    final offset = int.tryParse(args['cursor'] as String? ?? '') ?? 0;
    final limit = ((args['limit'] as num?)?.toInt() ?? listDefaultLimit)
        .clamp(1, listMaxLimit);
    final page = items.skip(offset).take(limit).toList(growable: false);
    final next = offset + page.length < items.length ? '${offset + page.length}' : null;

    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'list_entries',
      op: 'read',
      decision: _allowedDecision,
    );
    return {
      'entries': [
        for (final item in page) entryToAgentJson(item, folderName: folders[item.folderId]),
      ],
      'nextCursor': ?next,
      'total': items.length,
    };
  }

  Future<Map<String, Object?>> _getEntry(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');
    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(item);
    // 审批弹窗要展示"哪个条目"，所以先取条目再闸门。
    await _gate(
      pairing,
      principal,
      tool: 'get_entry',
      entryId: item.id,
      entryName: item.name,
    );

    final result = AgentAccessPolicy.evaluate(_requestFor(pairing, item));
    if (!result.allowed) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: 'get_entry',
        op: 'read',
        entryId: item.id,
        entryName: item.name,
        decision: 'denied',
      );
      throw McpToolException('denied', '条目未开放给智能体');
    }

    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'get_entry',
      op: 'read',
      entryId: item.id,
      entryName: item.name,
      decision: _allowedDecision,
    );
    final folders = await _folderNames();
    return entryToAgentJson(item, folderName: folders[item.folderId]);
  }

  // ─── 写 / 删 / 回收站（3.1.0 阶段 2）────────────────────
  //
  // 授权口径与读一致：**策略只有一份**（AgentAccessPolicy）+ **闸门只有一处**
  // （_gate）。写/删/恢复永远逐次审批（不享受「本会话内允许读取」），
  // 而且仍然受条目「永久拒绝」硬闸约束 —— 对智能体关闭的条目，它连删都删不掉。
  //
  // 最重要的两条安全设计：
  // 1. 智能体**不能给自己开权限**：它建出来的条目 `agentOpen` 恒为 false；
  // 2. 智能体**不能彻底删除**：`delete_entry` 只做软删（进回收站），
  //    "彻底删除 / 清空回收站"只存在于 UI 动作面。

  static const int _maxNameLength = 200;
  static const int _maxNotesLength = 100000;
  static const int _maxFieldLength = 5000;
  static const int _maxCustomFields = 50;

  void _setAuditTarget(VaultItem item) {
    _errorEntryId = item.id;
    _errorEntryName = item.name;
  }

  static String _requiredId(Map<String, Object?> args) {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');
    return id;
  }

  static String _requiredText(
    Map<String, Object?> args,
    String key, {
    required int maxLength,
  }) {
    final value = (args[key] as String? ?? '').trim();
    if (value.isEmpty) throw McpToolException('invalidRequest', '$key 必填');
    if (value.length > maxLength) {
      throw McpToolException('invalidRequest', '$key 太长（上限 $maxLength 字符）');
    }
    return value;
  }

  static String? _optionalText(
    Map<String, Object?> args,
    String key, {
    required int maxLength,
  }) {
    final raw = args[key];
    if (raw == null) return null;
    if (raw is! String) {
      throw McpToolException('invalidRequest', '$key 必须是字符串');
    }
    if (raw.length > maxLength) {
      throw McpToolException('invalidRequest', '$key 太长（上限 $maxLength 字符）');
    }
    return raw;
  }

  /// `password` 参数：字符串（明文由智能体提供）或 `{"generate": true, ...}`
  /// （核心生成并**直接加密入库**，明文不回传）。
  static String? _passwordArg(Map<String, Object?> args) {
    final raw = args['password'];
    if (raw == null) return null;
    if (raw is String) {
      if (raw.length > _maxFieldLength) {
        throw McpToolException('invalidRequest', 'password 太长');
      }
      return raw;
    }
    if (raw is Map) {
      if (raw['generate'] != true) {
        throw McpToolException(
          'invalidRequest',
          'password 对象只接受 {"generate": true, "length"?: int, "useSymbols"?: bool}',
        );
      }
      final length = ((raw['length'] as num?)?.toInt() ?? 20).clamp(8, 128);
      final password = generatePassword(<String, dynamic>{
        'length': length,
        'useUpper': raw['useUpper'] ?? true,
        'useLower': raw['useLower'] ?? true,
        'useNumbers': raw['useNumbers'] ?? true,
        'useSymbols': raw['useSymbols'] ?? true,
      });
      if (password.isEmpty) {
        throw McpToolException('invalidRequest', '密码生成参数无效（字符集为空）');
      }
      return password;
    }
    throw McpToolException('invalidRequest', 'password 类型不对');
  }

  /// 可写的条目类型：只开放 login / secure_note。
  ///
  /// identity / ssh_key 的字段太多（证件号、地址、私钥、口令…），让智能体
  /// 逐字段拼 JSON 既容易写错、也让审批弹窗难以说清"到底改了什么"。
  /// 这不是安全限制，是可用性取舍；文档里已写明。
  static EntryType _writableType(Object? raw) {
    final value = (raw as String?)?.trim().toLowerCase();
    switch (value) {
      case null || '' || 'login':
        return EntryType.login;
      case 'secure_note' || 'note' || 'notes':
        return EntryType.secureNote;
      case 'identity' || 'ssh_key' || 'ssh':
        throw McpToolException(
          'invalidRequest',
          '暂不支持通过 MCP 写 identity / ssh_key 条目（字段太多），请在 EasyPass 界面里创建或编辑',
        );
      default:
        throw McpToolException('invalidRequest', '未知类型：$value');
    }
  }

  /// `folder` 参数（新建用）：缺省/空串 = 不归类；给了就必须是真实 id。
  Future<String?> _folderArg(Map<String, Object?> args) async {
    final raw = args['folder'];
    if (raw == null) return null;
    if (raw is! String) {
      throw McpToolException('invalidRequest', 'folder 必须是文件夹 id');
    }
    final id = raw.trim();
    if (id.isEmpty) return null;
    await _requireFolderExists(id);
    return id;
  }

  /// `folder` 参数（更新用）：区分"没传"（不改）与"显式 null/空串"（移出文件夹）。
  Future<({bool changed, String? value})> _folderUpdate(
    Map<String, Object?> args,
  ) async {
    if (!args.containsKey('folder')) return (changed: false, value: null);
    final raw = args['folder'];
    if (raw == null) return (changed: true, value: null);
    if (raw is! String) {
      throw McpToolException('invalidRequest', 'folder 必须是文件夹 id 或 null');
    }
    final id = raw.trim();
    if (id.isEmpty) return (changed: true, value: null);
    await _requireFolderExists(id);
    return (changed: true, value: id);
  }

  Future<void> _requireFolderExists(String id) async {
    final folders = await _repository.getFolders();
    if (!folders.any((folder) => folder.id == id)) {
      throw McpToolException('invalidRequest', '文件夹不存在：$id');
    }
  }

  static List<CustomField> _customFieldsArg(Map<String, Object?> args) {
    final raw = args['customFields'];
    if (raw == null) return const [];
    if (raw is! List) {
      throw McpToolException('invalidRequest', 'customFields 必须是数组');
    }
    if (raw.length > _maxCustomFields) {
      throw McpToolException(
        'invalidRequest',
        '自定义字段太多（上限 $_maxCustomFields 个）',
      );
    }
    final fields = <CustomField>[];
    for (final entry in raw) {
      if (entry is! Map) {
        throw McpToolException('invalidRequest', 'customFields 的每一项必须是对象');
      }
      final label = (entry['label'] as String? ?? '').trim();
      if (label.isEmpty) {
        throw McpToolException('invalidRequest', '自定义字段的 label 必填');
      }
      final value = (entry['value'] as String? ?? '');
      if (value.length > _maxFieldLength) {
        throw McpToolException('invalidRequest', '自定义字段的值太长');
      }
      final typeRaw = (entry['type'] as String? ?? 'text').trim();
      fields.add(CustomField(
        label: label,
        value: value,
        type: CustomFieldType.fromWire(typeRaw),
      ));
    }
    return fields;
  }

  /// `create_entry`：新建条目（默认对智能体**永久拒绝**，需用户在 UI 打开）。
  Future<Map<String, Object?>> _createEntry(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final name = _requiredText(args, 'name', maxLength: _maxNameLength);
    _errorEntryName = name;
    final type = _writableType(args['type']);
    final folderId = await _folderArg(args);
    final notes = _optionalText(args, 'notes', maxLength: _maxNotesLength) ?? '';
    final customFields = _customFieldsArg(args);

    final LoginData? login;
    if (type == EntryType.login) {
      login = LoginData(
        url: _optionalText(args, 'url', maxLength: _maxFieldLength) ?? '',
        username:
            _optionalText(args, 'username', maxLength: _maxFieldLength) ?? '',
        password: _passwordArg(args) ?? '',
      );
    } else {
      login = null;
    }

    await _gate(
      pairing,
      principal,
      tool: 'create_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryName: name,
      detail: '新建「$name」（${type.wireName}）'
          '${(login?.password.isNotEmpty ?? false) ? '，含密码' : ''}',
    );

    final now = _now;
    final item = VaultItem(
      id: _uuid.v4(),
      folderId: folderId,
      type: type,
      name: name,
      notes: notes,
      // **产品决定（用户 2026-10-28 明确要求）**：智能体自己新建的条目默认
      // 对智能体**开放** —— 否则它建完就读不到/改不了/删不掉，等于建了个自己
      // 够不着的东西。用户仍可在条目里随时改成「永久拒绝」收回。
      agentOpen: true,
      login: login,
      customFields: customFields,
      createdAt: now,
      updatedAt: now,
    );
    await _repository.saveItem(item);
    _notifyDataChanged();

    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'create_entry',
      op: 'write',
      entryId: item.id,
      entryName: item.name,
      decision: 'allowed',
    );
    return {
      'id': item.id,
      'name': item.name,
      'type': item.type.wireName,
      'note': '已创建。该条目默认对智能体开放（可在 EasyPass 的条目里改成'
          '「永久拒绝」收回）。',
    };
  }

  /// `update_entry`：按字段局部更新（未传的字段不动）。
  Future<Map<String, Object?>> _updateEntry(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(item);
    if (item.deletedAt != null) {
      throw McpToolException(
        'invalidRequest',
        '该条目在回收站里：请先调用 restore_entry 恢复，再修改',
      );
    }

    // 先算出"要改成什么"（只做校验，不落库），审批弹窗才能列出字段名。
    final plan = await _planUpdate(item, args);

    await _gate(
      pairing,
      principal,
      tool: 'update_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: '修改字段：${plan.fields.join('、')}',
    );

    final result = AgentAccessPolicy.evaluate(
      _requestFor(pairing, item, op: AgentOp.write),
    );
    if (!result.allowed) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: 'update_entry',
        op: 'write',
        entryId: item.id,
        entryName: item.name,
        decision: 'denied',
      );
      throw McpToolException('denied', '条目未开放给智能体（${result.reason!.name}）');
    }

    await _repository.saveItem(plan.item);
    _notifyDataChanged();
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'update_entry',
      op: 'write',
      entryId: item.id,
      entryName: item.name,
      decision: 'allowed',
    );
    return {'ok': true, 'id': item.id, 'updatedFields': plan.fields};
  }

  /// 计算更新后的条目（纯校验 + 组装，不落库）。
  Future<({VaultItem item, List<String> fields})> _planUpdate(
    VaultItem item,
    Map<String, Object?> args,
  ) async {
    final fields = <String>[];

    final name = args.containsKey('name')
        ? _requiredText(args, 'name', maxLength: _maxNameLength)
        : item.name;
    if (args.containsKey('name')) fields.add('name');

    final notes = args.containsKey('notes')
        ? (_optionalText(args, 'notes', maxLength: _maxNotesLength) ?? '')
        : item.notes;
    if (args.containsKey('notes')) fields.add('notes');

    final folderChange = await _folderUpdate(args);
    if (folderChange.changed) fields.add('folder');

    var login = item.login;
    final touchesLogin = args.containsKey('url') ||
        args.containsKey('username') ||
        args.containsKey('password');
    if (touchesLogin) {
      if (item.type != EntryType.login) {
        throw McpToolException(
          'invalidRequest',
          '只有 login 条目才有 url / username / password 字段',
        );
      }
      final base = login ?? LoginData.empty;
      if (args.containsKey('url')) {
        fields.add('url');
        login = base.copyWith(
          url: _optionalText(args, 'url', maxLength: _maxFieldLength) ?? '',
        );
      }
      if (args.containsKey('username')) {
        fields.add('username');
        login = (login ?? base).copyWith(
          username:
              _optionalText(args, 'username', maxLength: _maxFieldLength) ?? '',
        );
      }
      if (args.containsKey('password')) {
        final password = _passwordArg(args) ?? '';
        if (password.isEmpty) {
          throw McpToolException(
            'invalidRequest',
            'password 不能为空字符串（要生成请传 {"generate": true}）',
          );
        }
        fields.add('password');
        login = (login ?? base).copyWith(password: password);
      }
    }

    final customFields = args.containsKey('customFields')
        ? _customFieldsArg(args)
        : item.customFields;
    if (args.containsKey('customFields')) fields.add('customFields');

    final isFavorite = args.containsKey('isFavorite')
        ? args['isFavorite'] == true
        : item.isFavorite;
    if (args.containsKey('isFavorite')) fields.add('isFavorite');

    if (fields.isEmpty) {
      throw McpToolException('invalidRequest', '没有可修改的字段');
    }

    return (
      item: item.copyWith(
        name: name,
        notes: notes,
        folderId: folderChange.changed ? folderChange.value : item.folderId,
        login: login,
        customFields: customFields,
        isFavorite: isFavorite,
      ),
      fields: fields,
    );
  }

  /// `delete_entry`：**只做软删**（移到回收站）。彻底删除只存在于 UI。
  Future<Map<String, Object?>> _deleteEntry(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(item);
    if (item.deletedAt != null) {
      throw McpToolException('invalidRequest', '该条目已经在回收站里');
    }

    await _gate(
      pairing,
      principal,
      tool: 'delete_entry',
      op: AgentOp.delete,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: '移到回收站（可恢复，不会彻底删除）',
    );

    final result = AgentAccessPolicy.evaluate(
      _requestFor(pairing, item, op: AgentOp.delete),
    );
    if (!result.allowed) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: 'delete_entry',
        op: 'delete',
        entryId: item.id,
        entryName: item.name,
        decision: 'denied',
      );
      throw McpToolException('denied', '条目未开放给智能体（${result.reason!.name}）');
    }

    final trashed = await _repository.deleteItem(item.id);
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'delete_entry',
      op: 'delete',
      entryId: item.id,
      entryName: item.name,
      decision: trashed ? 'allowed' : 'error',
    );
    if (!trashed) throw McpToolException('internal', '删除失败');
    _notifyDataChanged();
    return {
      'ok': true,
      'trashed': true,
      'note': '已移到回收站，可由用户恢复。',
    };
  }

  /// `list_trash`：列出回收站里**对智能体开放**的条目元数据。
  Future<Map<String, Object?>> _listTrash(
    AgentPairing pairing,
    McpPrincipal principal,
  ) async {
    await _gate(pairing, principal, tool: 'list_trash');
    final items = await _repository.getTrashedItems();
    final folders = await _folderNames();
    final visible = [
      for (final item in items)
        if (AgentAccessPolicy.evaluate(_requestFor(pairing, item)).allowed) item,
    ];
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'list_trash',
      op: 'read',
      decision: _allowedDecision,
    );
    return {
      'entries': [
        for (final item in visible)
          entryToAgentJson(
            item,
            folderName: folders[item.folderId],
            deletedAt: item.deletedAt,
          ),
      ],
      'total': visible.length,
    };
  }

  /// `restore_entry`：从回收站恢复（写操作，逐次审批）。
  Future<Map<String, Object?>> _restoreEntry(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(item);
    if (item.deletedAt == null) {
      throw McpToolException('invalidRequest', '该条目不在回收站里');
    }

    await _gate(
      pairing,
      principal,
      tool: 'restore_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: '从回收站恢复「${item.name}」',
    );

    final result = AgentAccessPolicy.evaluate(
      _requestFor(pairing, item, op: AgentOp.write),
    );
    if (!result.allowed) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: 'restore_entry',
        op: 'write',
        entryId: item.id,
        entryName: item.name,
        decision: 'denied',
      );
      throw McpToolException('denied', '条目未开放给智能体（${result.reason!.name}）');
    }

    final restored = await _repository.restoreItem(item.id);
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'restore_entry',
      op: 'write',
      entryId: item.id,
      entryName: item.name,
      decision: restored ? 'allowed' : 'error',
    );
    if (!restored) throw McpToolException('internal', '恢复失败');
    _notifyDataChanged();
    return {'ok': true, 'restored': true};
  }

  // ─── 内部 ──────────────────────────────────────────────

  /// 复制某字段到系统剪贴板：**只回 ok，不回明文**。
  ///
  /// 这是"密码不需要让智能体知道"的落点：明文只在本机进程之间传递
  /// （核心 → 剪贴板），智能体拿到的是"已复制"这个事实，然后自己去目标窗口粘贴。
  /// 安全纪律：
  /// - 按**敏感读**判定（不享受"本会话免询问"）；
  /// - 条目必须是"开放"；
  /// - 审计只记条目与字段名，绝不记值。
  Future<Map<String, Object?>> _copyToClipboard(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');

    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(item);
    // 敏感读：**不享受**本会话免询问，每次都要用户同意。
    await _gate(
      pairing,
      principal,
      tool: 'copy_to_clipboard',
      op: AgentOp.sensitiveRead,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
    );

    final result = AgentAccessPolicy.evaluate(
      _requestFor(pairing, item, op: AgentOp.sensitiveRead),
    );
    if (!result.allowed) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: 'copy_to_clipboard',
        op: 'clipboard',
        entryId: item.id,
        entryName: item.name,
        decision: 'denied',
      );
      throw McpToolException('denied', '条目未开放给智能体（${result.reason!.name}）');
    }

    final field = (args['field'] as String? ?? 'password').trim();
    final value = _fieldValue(item, field, args['customLabel'] as String?);
    if (value == null) {
      throw McpToolException('invalidRequest', '未知字段：$field');
    }
    if (value.isEmpty) {
      throw McpToolException('notFound', '该条目的这个字段是空的');
    }

    final ok = await _clipboardWriter(value);
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: 'copy_to_clipboard',
      op: 'clipboard',
      entryId: item.id,
      entryName: item.name,
      decision: ok ? 'allowed' : 'error',
    );
    if (!ok) {
      throw McpToolException('internal', '剪贴板被占用或不可用，请重试');
    }
    // **绝不回传 value**：只回事实。
    return {
      'ok': true,
      'entryId': item.id,
      'field': field,
      'length': value.length,
      'note': '已复制到剪贴板；内容不会返回给模型，请直接在目标窗口粘贴。',
    };
  }

  String? _fieldValue(VaultItem item, String field, String? customLabel) {
    switch (field) {
      case 'password':
        return item.loginOrEmpty.password;
      case 'totp':
        final secret = item.loginOrEmpty.totpSecret;
        if (secret.isEmpty) return '';
        return _totpService.generateTotp(secret);
      case 'notes':
        return item.notes;
      case 'private_key':
        return item.sshKeyOrEmpty.privateKey;
      case 'passphrase':
        return item.sshKeyOrEmpty.passphrase;
      case 'custom':
        final label = (customLabel ?? '').trim();
        if (label.isEmpty) return null;
        for (final custom in item.customFields) {
          if (custom.label.trim() == label) return custom.value;
        }
        return '';
      default:
        return null;
    }
  }

  Future<List<VaultItem>> _visibleItems(
    AgentPairing pairing, {
    EntryType? type,
    String? folderId,
    String query = '',
  }) async {
    final List<VaultItem> candidates;
    if (query.isNotEmpty) {
      candidates = await _repository.searchItems(query);
    } else {
      candidates = await _repository.getItems(type: type, folderId: folderId);
    }
    return [
      for (final item in candidates)
        if (AgentAccessPolicy.evaluate(_requestFor(pairing, item)).allowed) item,
    ];
  }

  AgentAccessRequest _requestFor(
    AgentPairing pairing,
    VaultItem item, {
    AgentOp op = AgentOp.read,
  }) {
    return AgentAccessRequest(
      op: op,
      entryOpen: item.agentOpen,
      revoked: pairing.isRevoked,
      expired: pairing.isExpiredAt(_now),
      sessionUnlocked: _sessions.agent.isUnlocked,
      inScope: _inScope(pairing, item),
      mode: pairing.mode,
      trusted: pairing.trusted,
      // 由统一的 [_gate] 在读取条目之前决定（方式 1 的同意 / 免询问）。
      approvedThisCall: _callApproved,
      standingRead: _callStanding,
    );
  }

  bool _inScope(AgentPairing pairing, VaultItem item) {
    final folders = pairing.scopeFolders;
    final types = pairing.scopeTypes;
    if (folders.isEmpty && types.isEmpty) return true;
    if (item.folderId != null && folders.contains(item.folderId)) return true;
    return types.contains(item.type.wireName);
  }

  Future<Map<String?, String>> _folderNames() async {
    final folders = await _repository.getFolders();
    return {for (final folder in folders) folder.id: folder.name};
  }

  /// 总开关是否打开（`end_session` 与状态判断用）。
  Future<bool> _isAccessEnabled() => _agentAccess.isEnabled();

  void _requireAllowed(AgentPairing pairing, AgentAccessRequest request) {
    final result = AgentAccessPolicy.evaluate(request);
    if (!result.allowed) {
      throw McpToolException('denied', '访问被拒绝（${result.reason!.name}）');
    }
  }

  /// 一次工具调用是否已获"本次同意" / 是否靠"本会话免询问"放行。
  /// 由 [_gate] 在读取条目之前设置，[_requestFor] 读取它做逐条判定。
  bool _callApproved = false;
  bool _callStanding = false;

  /// 本次调用是否为了"方式 1 的一次性访问"临时解锁了 agent 域。
  /// 调用结束必须锁回去 —— 逐次审批的语义就是"借一次钥匙"。
  bool _unlockedForCall = false;

  /// 方式 1 的一次性钥匙：从 **ui 域**复制一份给 agent 域。
  ///
  /// 为什么必须复制：`VaultSession._wipe()` 是原地清零，共享同一个 `Uint8List`
  /// 会让"锁 agent 域"顺手把 ui 的密钥清零（反之亦然）。
  /// 为什么从 ui 取：审批是用户当面点的，说明 ui 域此刻是可信且已解锁的。
  void _borrowKeyFromUiForThisCall() {
    if (_sessions.agent.isUnlocked) return;
    final uiKey = _sessions.ui.key;
    if (uiKey == null) {
      throw McpToolException(
        'locked',
        '保险库已锁定：请在 EasyPass 里解锁后再批准智能体访问',
      );
    }
    _sessions.agent.unlock(Uint8List.fromList(uiKey));
    _unlockedForCall = true;
  }

  void _releaseBorrowedKeyIfAny() {
    if (!_unlockedForCall) return;
    _unlockedForCall = false;
    _sessions.agent.lock();
  }

  /// 请求级闸门：**在读任何条目之前**决定这次调用有没有资格继续。
  ///
  /// - 方式 2（可信直通）：直接按策略校验，不需要同意；
  /// - 方式 1：先看"本会话免询问"（仅普通读、且仅该配对），否则向 UI 发审批并等待。
  ///   用户拒绝 / 超时 ⇒ 抛 `denied`（fail closed），绝不静默返回空列表。
  Future<void> _gate(
    AgentPairing pairing,
    McpPrincipal principal, {
    required String tool,
    AgentOp op = AgentOp.read,
    bool allowStanding = true,
    String? entryId,
    String? entryName,
    String? detail,
  }) async {
    _callApproved = false;
    _callStanding = false;

    if (pairing.mode == AgentMode.trusted) {
      if (!_sessions.agent.isUnlocked) {
        throw McpToolException(
          'locked',
          '智能体会话未解锁：请确认“智能体访问”开关是开启的',
        );
      }
      _assertRequestAllowed(pairing, approvedThisCall: false, op: op);
      return;
    }

    // 方式 1：本会话已放行读（仅普通读）。
    if (allowStanding &&
        op == AgentOp.read &&
        _standingRead.contains(pairing.id)) {
      _callStanding = true;
      _borrowKeyFromUiForThisCall();
      _assertRequestAllowed(pairing, approvedThisCall: false, op: op);
      return;
    }

    final approved = await _requestApproval(
      pairing,
      op: op,
      toolName: tool,
      allowStandingOption: allowStanding && op == AgentOp.read,
      entryId: entryId,
      entryName: entryName,
      detail: detail,
    );
    if (!approved) {
      _auditAdd(
        principal: principal,
        mode: pairing.mode,
        tool: tool,
        op: _opLabel(op),
        decision: 'denied',
        entryId: entryId,
        entryName: entryName,
      );
      throw McpToolException('denied', '用户未同意本次操作');
    }
    _callApproved = true;
    // 用户当面同意之后才借钥匙；未解锁 ui 则借不到（fail closed）。
    _borrowKeyFromUiForThisCall();
    _assertRequestAllowed(pairing, approvedThisCall: true, op: op);
  }

  void _assertRequestAllowed(
    AgentPairing pairing, {
    required bool approvedThisCall,
    AgentOp op = AgentOp.read,
  }) {
    _requireAllowed(
      pairing,
      AgentAccessRequest(
        op: op,
        entryOpen: true,
        revoked: pairing.isRevoked,
        expired: pairing.isExpiredAt(_now),
        sessionUnlocked: _sessions.agent.isUnlocked,
        mode: pairing.mode,
        trusted: pairing.trusted,
        approvedThisCall: approvedThisCall,
        standingRead: _callStanding,
      ),
    );
  }

  void _auditAdd({
    required McpPrincipal principal,
    required AgentMode mode,
    required String tool,
    required String op,
    required String decision,
    String? entryId,
    String? entryName,
  }) {
    // 一次调用只允许一行审计：后续的失败兜底看到这个标志就闭嘴。
    _auditedThisCall = true;
    _audit.addLast(AgentAuditEntry(
      at: _now,
      pairingId: principal.pairingId,
      nickname: principal.nickname,
      mode: mode.name,
      tool: tool,
      op: op,
      entryId: entryId,
      entryName: entryName,
      decision: decision,
    ));
    while (_audit.length > _auditCapacity) {
      _audit.removeFirst();
    }

    // 落库（旁路）：失败只记 stderr，绝不让工具调用因此失败 ——
    // 审计是"事后可查"，不是"通过的前提"。
    final sink = _auditSink;
    if (sink != null) {
      final entry = _audit.last;
      unawaited(Future<void>.sync(() => sink(entry)).catchError((Object _) {}));
    }
    // UI 的"智能体活动"页据此实时刷新（读操作没有数据变更主题，只能靠它）。
    onAuditRecorded?.call();
  }

  /// 本次调用放行时该记的 decision。
  ///
  /// 靠「本会话内允许读取」放行的读，必须记成 `allowed_standing`：
  /// 否则审计里"用户这次点了同意"和"被免询问绕过"完全不可区分 —— 那正是
  /// 事后追查最需要看到的差别（3.1.0 补的 decision）。
  String get _allowedDecision => _callStanding ? 'allowed_standing' : 'allowed';

  /// 失败兜底：只有这次调用**还没有**写过审计行时才补一条 `error`。
  ///
  /// 兜底覆盖 `notFound` / 参数不对 / 意外异常；拒绝与超时已经各自记过
  /// `denied` / `timeout`，这里不重复。
  void _auditErrorIfNeeded(
    McpPrincipal principal,
    AgentPairing pairing,
    String tool,
  ) {
    if (_auditedThisCall) return;
    _auditAdd(
      principal: principal,
      mode: pairing.mode,
      tool: tool,
      op: _opLabelForTool(tool),
      decision: 'error',
      entryId: _errorEntryId,
      entryName: _errorEntryName,
    );
  }

  /// 工具 → 操作类型（失败审计与状态展示用；具体工具会自己传准确 op）。
  static AgentOp _opForTool(String tool) => switch (tool) {
        'create_entry' || 'update_entry' || 'restore_entry' => AgentOp.write,
        'delete_entry' => AgentOp.delete,
        'copy_to_clipboard' => AgentOp.sensitiveRead,
        _ => AgentOp.read,
      };

  static String _opLabelForTool(String tool) => _opLabel(_opForTool(tool));
}