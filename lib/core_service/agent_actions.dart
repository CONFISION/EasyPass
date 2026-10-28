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

/// 一次审批请求的结局。
enum _ApprovalVerdict {
  allowed,
  denied,
  timeout,

  /// 被 `cancelPendingApprovals()` 取消（锁域 / 切方式 / 关开关 / 改密等边界）。
  cancelled,

  /// 超过 pending 上限，请求没有发给用户（M2 限流）。
  rateLimited,
}

/// 一次工具调用的可变状态。
///
/// **必须是 per-call 的**：MCP 的 HTTP 层对每个请求并发执行 handler，实例字段
/// 会让并发调用互相污染（审计漏行/错标、借来的钥匙被另一调用提前锁回）。
/// 这里把"本次调用"的全部状态收进一个对象，随调用链显式传递。
class _AgentCall {
  _AgentCall({required this.tool, required this.op});

  final String tool;
  final AgentOp op;

  /// 审计 `op` 的覆盖值（`copy_to_clipboard` 记 `clipboard:<field>`）。
  String? auditOp;

  /// 本次调用是否已经写过审计（一次调用一行）。
  bool audited = false;

  /// 失败审计用的条目上下文。
  String? errorEntryId;
  String? errorEntryName;

  /// 本次调用是否已获用户同意 / 是否靠「本会话内允许读取」放行。
  bool approved = false;
  bool standing = false;

  /// 本次调用是否正在使用 agent 会话钥匙（用于借钥匙的并发计数）。
  bool keyUser = false;
}

/// 智能体工具面的实现：**认证 + 授权 + 执行**的唯一入口。
///
/// 两条原则：
/// 1. 授权判定只有一个实现（[AgentAccessPolicy]），本类只负责"把事实算好"；
/// 2. 智能体只经 `sessions.agent` 的密钥解密（第三个仓储实例），**绝不借用 ui 域**
///    （方式 1 的"借钥匙"是用户点击后复制一份、调用结束立刻锁回）。
///
/// 审批与重校验（评审 H1/H3）：
/// - 单条目工具在 agent 域锁定时必须返回明确的 `locked`，不做"先查库后过闸"；
/// - 审批通过后**重新读取** pairing / item / 总开关，重跑 precheck + evaluate
///   才执行；update 用 `updated_at` CAS，delete/restore 用条件更新并区分状态。
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
    Duration approvalTimeout = defaultApprovalTimeout,
  })  : _repository = repository,
        _sessions = sessions,
        _pairingStore = pairingStore,
        _agentAccess = agentAccess,
        _totpService = totpService,
        _clipboardWriter = clipboardWriter ?? SystemClipboard.writeText,
        _auditSink = auditSink,
        _clock = clock ?? DateTime.now,
        _auditCapacity = auditCapacity,
        _approvalTimeout = approvalTimeout;

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
  final Duration _approvalTimeout;

  /// 窗口 TTL 边界（§6.7）。
  static const int windowTtlDefaultSeconds = 300;
  static const int windowTtlMaxSeconds = 1800;
  static const int windowTtlMinSeconds = 30;

  /// 单次 `list_entries` 的条数上限。
  static const int listDefaultLimit = 50;
  static const int listMaxLimit = 200;

  /// 审批并发上限（M2）：防止已配对但不可信的智能体用审批洪水顶死 UI。
  /// 超限的调用**立即拒绝、不弹窗、不落 pending**，只写一行 denied 审计。
  static const int maxPendingApprovalsPerPairing = 3;
  static const int maxPendingApprovalsGlobal = 8;

  /// 审批超时：必须短于客户端自己的 `tools/call` 超时（DSH 默认 60s），
  /// 否则客户端先超时、用户随后点"同意"就成了对没人等待的调用授权。
  ///
  /// 默认值即产品口径；构造参数允许单测注入更短的超时来覆盖"超时按拒绝 +
  /// 只写一行 timeout 审计"的关闭路径。
  static const Duration defaultApprovalTimeout = Duration(seconds: 45);

  /// 字段长度上限（与写工具的输入校验一致）。
  static const int _maxNameLength = 200;
  static const int _maxNotesLength = 100000;
  static const int _maxFieldLength = 5000;
  static const int _maxCustomFields = 50;
  static const int _maxPurposeLength = 500;
  static const int _maxAuditTextLength = 200;

  /// 审批「详细」里单个值展示的上限。
  ///
  /// 只对**非秘密**字段展示 old→new（H9：用户必须能判断"要改成什么"，
  /// 例如 URL 投毒）。超长值显式标"已截断"而不是静默省略 —— 静默截断
  /// 会给"前缀无害、真正目标在后面"的构造留空间。
  static const int _maxDetailValueLength = 400;

  /// `copy_to_clipboard` 允许读取的字段（H5：identity/SSH 专属字段不在其中）。
  static const Set<String> _clipboardFields = {'password', 'totp', 'notes', 'custom'};

  /// 方式 1 的"本会话内允许读取"（按配对 id）。仅对**普通读**生效，
  /// 敏感读（明文/验证码/剪贴板）与写删一律每次都要同意。
  ///
  /// 生命周期由用户授权边界决定：切方式 / 关开总开关 / 改密 / 显式锁 agent 域
  /// / 撤销配对时由 CoreActions 调用 [clearAllStandingRead]/[clearStandingRead]。
  final Set<String> _standingRead = <String>{};

  AgentWindow? _window;

  /// 待用户回应的审批请求（`approvalId` → 结局）。
  ///
  /// **实例级共享**：approvalId 全局唯一，跨调用不会串台；每个调用只等待
  /// 自己的那个 Completer，所以"审批只作用于发起它的那次调用"。
  final Map<String, Completer<_ApprovalVerdict>> _pendingApprovals = {};

  /// 审批请求归属的配对与"是否允许勾选本会话免询问"。
  final Map<String, String> _pendingPairing = {};
  final Map<String, bool> _pendingAllowStanding = {};

  /// 正在使用 agent 会话钥匙的并发调用数 + 当前钥匙是否由"借用 ui"而来。
  ///
  /// 借钥匙必须计数：两个并发调用里 A 借到钥匙后 B 也在用，A 结束就锁回
  /// 会让 B 中途读空。只有最后一个使用者离开时才锁。
  int _keyUsers = 0;
  bool _borrowedKey = false;

  /// 向 UI 广播审批请求的钩子（核心把它接到 `_broadcast`）。
  void Function(Map<String, Object?> request)? onApprovalRequested;

  /// 审批结束（响应 / 超时 / 取消）时触发：UI 据此关闭陈旧弹窗。
  void Function(String approvalId, String decision)? onApprovalResolved;

  /// 写操作成功后的**变更广播**钩子（核心接到 `_broadcastChanged`）。
  void Function(Set<String> topics)? onDataChanged;

  /// 每写入一条审计后触发（设置/侧边栏的"智能体活动"页据此实时刷新）。
  void Function()? onAuditRecorded;

  void _notifyDataChanged() => onDataChanged?.call({
        Topics.items,
        Topics.item,
        Topics.folders,
        Topics.search,
      });

  final Queue<AgentAuditEntry> _auditQueue = Queue<AgentAuditEntry>();

  AgentWindow? get window => _window;

  List<AgentAuditEntry> get recentAudit => List.unmodifiable(_auditQueue);

  int get _now => _clock().millisecondsSinceEpoch;

  static const Uuid _uuid = Uuid();

  // ─── UI 侧接口（审批 / 免询问）──────────────────────────

  /// 某配对是否已获得"本会话内免询问读取"（UI 用它显示可撤销指示）。
  bool isStandingRead(String pairingId) => _standingRead.contains(pairingId);

  /// 撤销"本会话内免询问读取"。
  void clearStandingRead(String pairingId) => _standingRead.remove(pairingId);

  /// 清空所有免询问状态（锁定 / 关总开关 / 换方式 / 改密 / 撤销配对时调用）。
  void clearAllStandingRead() => _standingRead.clear();

  /// UI 的回应入口（`CoreActions.respondAgentApproval` 调它）。
  ///
  /// [allowStandingRead] 只在"本次是普通读、且该请求允许免询问"时才生效 ——
  /// 核心侧再判一次，不信任 UI 传来的标志。
  bool respondApproval(
    String approvalId,
    bool allow, {
    bool allowStandingRead = false,
  }) {
    final completer = _pendingApprovals[approvalId];
    if (completer == null || completer.isCompleted) {
      _pendingPairing.remove(approvalId);
      _pendingAllowStanding.remove(approvalId);
      return false;
    }
    final pairingId = _pendingPairing.remove(approvalId);
    final standingAllowed = _pendingAllowStanding.remove(approvalId) ?? false;
    _pendingApprovals.remove(approvalId);
    if (allow && allowStandingRead && standingAllowed && pairingId != null) {
      _standingRead.add(pairingId);
    }
    completer.complete(allow ? _ApprovalVerdict.allowed : _ApprovalVerdict.denied);
    onApprovalResolved?.call(approvalId, allow ? 'allowed' : 'denied');
    return true;
  }

  /// 取消所有挂起审批（锁域 / 切方式 / 关开关 / 改密 / 撤销配对时调用）。
  ///
  /// 被取消的调用由它自己的 `_gate` 写唯一一行 `denied` 审计；这里只负责
  /// 解除等待并广播 `agentApprovalResolved`（UI 关掉陈旧弹窗）。
  void cancelPendingApprovals({String decision = 'cancelled'}) {
    if (_pendingApprovals.isEmpty) return;
    final ids = _pendingApprovals.keys.toList(growable: false);
    for (final id in ids) {
      final completer = _pendingApprovals.remove(id);
      _pendingPairing.remove(id);
      _pendingAllowStanding.remove(id);
      if (completer == null || completer.isCompleted) continue;
      completer.complete(_ApprovalVerdict.cancelled);
      onApprovalResolved?.call(id, decision);
    }
  }

  /// 记一条"HTTP 层拒绝"审计（未认证 / Origin / Host / 超时 / 体积超限）。
  ///
  /// 这类请求进不到工具层，但"有人在本机探测端点"同样值得留痕。审计字段
  /// 按契约固定：pairingId=''、nickname='未认证'、mode='unknown'、tool='http'、
  /// op='read'、decision='denied'；`reason` 放 entryName（截断）。
  void recordHttpRejection(String reason) {
    final text = reason.length > _maxAuditTextLength
        ? '${reason.substring(0, _maxAuditTextLength)}…'
        : reason;
    _emitAudit(
      pairingId: '',
      nickname: '未认证',
      mode: 'unknown',
      tool: 'http',
      op: 'read',
      decision: 'denied',
      entryName: text,
    );
  }

  // ─── 认证 / 调用入口 ───────────────────────────────────

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
    // 每次调用一个独立状态对象：并发请求互不污染（M7）。
    final call = _AgentCall(tool: tool, op: _opForTool(tool));
    try {
      switch (tool) {
        case 'status':
          return await _status(call, pairing, principal);
        case 'begin_session':
          return await _beginSession(call, pairing, principal, args);
        case 'end_session':
          return await _endSession(call, pairing, principal);
        case 'list_entries':
          return await _listEntries(call, pairing, principal, args);
        case 'get_entry':
          return await _getEntry(call, pairing, principal, args);
        case 'copy_to_clipboard':
          return await _copyToClipboard(call, pairing, principal, args);
        case 'create_entry':
          return await _createEntry(call, pairing, principal, args);
        case 'update_entry':
          return await _updateEntry(call, pairing, principal, args);
        case 'delete_entry':
          return await _deleteEntry(call, pairing, principal, args);
        case 'list_trash':
          return await _listTrash(call, pairing, principal);
        case 'restore_entry':
          return await _restoreEntry(call, pairing, principal, args);
        default:
          throw McpToolException('invalidRequest', '未知工具：$tool');
      }
    } on McpToolException {
      _auditErrorIfNeeded(call, principal, pairing);
      rethrow;
    } catch (_) {
      _auditErrorIfNeeded(call, principal, pairing);
      rethrow;
    } finally {
      // 方式 1 借来的钥匙只活到本次调用结束：引用计数归零才锁回（并发安全）。
      _leaveKeyUse(call);
    }
  }

  // ─── 工具 ──────────────────────────────────────────────

  Future<Map<String, Object?>> _status(
    _AgentCall call,
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
      call,
      principal,
      mode: pairing.mode,
      tool: 'status',
      op: AgentOp.read,
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

  /// 当前配对"开放、类型暴露且在其 scope 内"的条目数。
  ///
  /// 判定口径 = 假设本次已获用户同意（`approvedThisCall: true`）：
  /// - 方式 1：条目开关 + 类型 + scope 即可（审批是每次调用的事）；
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
        typeExposed: _isExposedType(item.type),
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
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final purpose = _optionalText(args, 'purpose', maxLength: _maxPurposeLength)?.trim() ?? '';
    if (purpose.isEmpty) {
      throw McpToolException('invalidRequest', 'purpose 必填');
    }
    final rawTtl = args['ttlSeconds'];
    if (rawTtl != null && rawTtl is! num) {
      throw McpToolException('invalidRequest', 'ttlSeconds 必须是数字');
    }
    final rawTtlSeconds = (rawTtl as num?)?.toInt() ?? windowTtlDefaultSeconds;
    // 越界**显式拒绝**而不是静默 clamp：静默改小/改大会让智能体以为窗口
    // 长度是它请求的值，排障时也看不出被改过（spec §6.7 要求明确报错）。
    if (rawTtlSeconds < windowTtlMinSeconds ||
        rawTtlSeconds > windowTtlMaxSeconds) {
      throw McpToolException(
        'invalidRequest',
        'ttlSeconds 超出范围（$windowTtlMinSeconds–$windowTtlMaxSeconds 秒）',
      );
    }
    final ttl = rawTtlSeconds;
    // 审批「详细」必须让用户看懂这次要开多久、做什么（H9）。
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'begin_session',
      detail: '开窗：${_clipDetail(purpose, 120)}（TTL $ttl 秒）',
    );

    final now = _now;
    _window = AgentWindow(
      id: 'w_${now.toRadixString(16)}',
      purpose: purpose,
      startedAt: now,
      expiresAt: now + ttl * 1000,
    );
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'begin_session',
      op: AgentOp.read,
      decision: _allowedDecision(call),
    );
    return {'windowId': _window!.id, 'expiresAt': _window!.expiresAt};
  }

  Future<Map<String, Object?>> _endSession(
    _AgentCall call,
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
    // 注：工具描述里"立即锁定智能体会话域"是旧口径，已随 D11 改为"不锁定"。
    if (!await _isAccessEnabled()) {
      _sessions.agent.lock();
    }
    _window = null;
    _auditAdd(
      call,
      principal,
      mode: pairing.mode,
      tool: 'end_session',
      op: AgentOp.read,
      decision: 'allowed',
    );
    return {'ok': true};
  }

  Future<Map<String, Object?>> _listEntries(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    // 参数在任何审批之前解析/校验：无效请求不该打扰用户（审批疲劳）。
    final rawType = _optionalString(args, 'type');
    final rawFolder = _optionalString(args, 'folder');
    final query = (_optionalString(args, 'query') ?? '').trim();
    final type = (rawType == null || rawType.trim().isEmpty)
        ? null
        : EntryType.fromWire(rawType.trim());
    final folderId = (rawFolder == null || rawFolder.trim().isEmpty)
        ? null
        : rawFolder.trim();
    final rawLimit = args['limit'];
    final int limit;
    if (rawLimit == null) {
      limit = listDefaultLimit;
    } else if (rawLimit is num) {
      limit = rawLimit.toInt().clamp(1, listMaxLimit);
    } else {
      throw McpToolException('invalidRequest', 'limit 必须是数字');
    }
    final cursor = _optionalString(args, 'cursor');
    var offset = cursor == null ? 0 : (int.tryParse(cursor) ?? 0);
    if (offset < 0) offset = 0;

    final folders = await _folderNames();
    final detailParts = <String>[];
    if (type != null) detailParts.add('类型=${type.wireName}');
    if (folderId != null) detailParts.add('文件夹=${folders[folderId] ?? folderId}');
    if (query.isNotEmpty) detailParts.add('搜索「${_clipDetail(query, 120)}」');
    detailParts.add('最多 $limit 条');
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'list_entries',
      detail: '列出条目：${detailParts.join('，')}',
    );

    final items = await _visibleItems(
      call,
      fresh,
      type: type,
      folderId: folderId,
      query: query,
    );
    final page = items.skip(offset).take(limit).toList(growable: false);
    final next = offset + page.length < items.length ? '${offset + page.length}' : null;

    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'list_entries',
      op: AgentOp.read,
      decision: _allowedDecision(call),
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
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    call.errorEntryId = id;
    // H3：agent 域锁定时**明确报 locked**，不要"先查库后过闸"报 notFound。
    _requireEntryToolsUnlocked(call, principal, pairing, op: AgentOp.read);

    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(call, item);
    _precheckOrDeny(call, principal, pairing, item, op: AgentOp.read);
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'get_entry',
      entryId: item.id,
      entryName: item.name,
    );

    // H1：审批窗口内条目可能被关闭/删除/改类型 —— 用**新鲜**事实重判。
    final latest = await _repository.getItem(id);
    if (latest == null) {
      _deny(call, principal, fresh,
          tool: 'get_entry',
          op: AgentOp.read,
          code: 'notFound',
          message: '找不到该条目',
          entryId: id);
    }
    _precheckOrDeny(call, principal, fresh, latest, op: AgentOp.read);
    _evaluateOrDeny(call, principal, fresh, latest, op: AgentOp.read);

    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'get_entry',
      op: AgentOp.read,
      decision: _allowedDecision(call),
      entryId: latest.id,
      entryName: latest.name,
    );
    final folders = await _folderNames();
    return entryToAgentJson(latest, folderName: folders[latest.folderId]);
  }

  // ─── 写 / 删 / 回收站 ──────────────────────────────────
  //
  // 授权口径与读一致：**策略只有一份**（AgentAccessPolicy）+ **闸门只有一处**
  // （_gate）。写/删/恢复永远逐次审批（不享受「本会话内允许读取」），
  // 而且仍然受条目「永久拒绝」与类型硬闸约束 —— 对智能体关闭的条目，
  // 它连删都删不掉。
  //
  // 最重要的两条安全设计：
  // 1. 智能体**不能改权限开关**：它建的条目默认开放（用户决定），
  //    但 `agentOpen` 的**修改**只存在于 UI —— 它永远不能把被拒绝的条目重新打开；
  // 2. 智能体**不能彻底删除**：`delete_entry` 只做软删（进回收站），
  //    "彻底删除 / 清空回收站"只存在于 UI 动作面。

  /// `create_entry`：新建条目（默认对智能体**开放**，需用户在 UI 才能收回）。
  Future<Map<String, Object?>> _createEntry(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final name = _requiredText(args, 'name', maxLength: _maxNameLength);
    call.errorEntryName = name;
    final type = _writableType(args['type']);
    // secure_note 没有登录字段：**显式拒绝**而不是静默忽略。
    // 静默忽略会让调用方以为"密码存进去了"，实际什么都没发生。
    if (type != EntryType.login) {
      for (final key in const ['url', 'username', 'password']) {
        if (args.containsKey(key)) {
          throw McpToolException(
            'invalidRequest',
            '$key 只属于 login 条目；${type.wireName} 没有这个字段',
          );
        }
      }
    }
    final folderId = await _folderArg(args);
    final notes = _optionalText(args, 'notes', maxLength: _maxNotesLength) ?? '';
    final customFields = _customFieldsArg(args);

    final LoginData? login;
    if (type == EntryType.login) {
      login = LoginData(
        url: _optionalText(args, 'url', maxLength: _maxFieldLength) ?? '',
        username: _optionalText(args, 'username', maxLength: _maxFieldLength) ?? '',
        password: _passwordArg(args) ?? '',
      );
    } else {
      login = null;
    }

    // H9：弹窗必须能让用户判断"要写进去什么"（URL 投毒尤其危险）；
    // 秘密值（密码）只显示"已设置"。
    final folders = folderId == null ? null : await _folderNames();
    final detailParts = <String>['新建「${_clipDetail(name)}」（${type.wireName}）'];
    if (folderId != null) {
      detailParts.add('文件夹=${folders?[folderId] ?? folderId}');
    }
    if (login != null) {
      if (login.url.isNotEmpty) detailParts.add('URL=${_clipDetail(login.url)}');
      if (login.username.isNotEmpty) {
        detailParts.add('用户名=${_clipDetail(login.username)}');
      }
      detailParts.add(login.password.isEmpty ? '无密码' : '含密码（值不显示）');
    }
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'create_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryName: name,
      detail: detailParts.join('；'),
    );

    final now = _now;
    final item = VaultItem(
      id: _uuid.v4(),
      folderId: folderId,
      type: type,
      name: name,
      notes: notes,
      // **产品决定（用户明确要求）**：智能体自己新建的条目默认对智能体
      // **开放** —— 否则它建完就读不到/改不了/删不掉，等于建了个自己
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
      call,
      principal,
      mode: fresh.mode,
      tool: 'create_entry',
      op: AgentOp.write,
      decision: 'allowed',
      entryId: item.id,
      entryName: item.name,
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
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    call.errorEntryId = id;
    _requireEntryToolsUnlocked(call, principal, pairing, op: AgentOp.write);

    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(call, item);
    if (item.deletedAt != null) {
      throw McpToolException(
        'invalidRequest',
        '该条目在回收站里：请先调用 restore_entry 恢复，再修改',
      );
    }

    _precheckOrDeny(call, principal, pairing, item, op: AgentOp.write);
    // 审批前先算一遍"要改成什么"（只为弹窗展示；不落库）。
    final plan = await _planUpdate(item, args);
    final folders = await _folderNames();
    final detail = _updateApprovalDetail(item, plan.item, plan.fields, folders);
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'update_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: detail,
    );

    // H1：审批窗口内条目可能被改/删/关开关 —— 重读 + 重判。
    final latest = await _repository.getItem(id, includeDeleted: true);
    if (latest == null) {
      _deny(call, principal, fresh,
          tool: 'update_entry',
          op: AgentOp.write,
          code: 'notFound',
          message: '找不到该条目',
          entryId: id);
    }
    if (latest.deletedAt != null) {
      _deny(call, principal, fresh,
          tool: 'update_entry',
          op: AgentOp.write,
          code: 'invalidRequest',
          message: '该条目已被移入回收站，本次修改未执行',
          entryId: id);
    }
    _precheckOrDeny(call, principal, fresh, latest, op: AgentOp.write);
    _evaluateOrDeny(call, principal, fresh, latest, op: AgentOp.write);

    // 基于**最新快照**重算要写的内容；再用 updated_at CAS 落库。
    // 不做这两步会：把审批期间的用户编辑（如刚改的密码）覆盖回旧值（H1）。
    final latestPlan = await _planUpdate(latest, args);
    final saved = await _repository.updateItemIfUnchanged(
      latestPlan.item,
      expectedUpdatedAt: latest.updatedAt,
    );
    if (!saved) {
      throw McpToolException('conflict', '条目已被修改，请重试');
    }
    _notifyDataChanged();
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'update_entry',
      op: AgentOp.write,
      decision: 'allowed',
      entryId: latest.id,
      entryName: latest.name,
    );
    return {'ok': true, 'id': latest.id, 'updatedFields': latestPlan.fields};
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
          username: _optionalText(args, 'username', maxLength: _maxFieldLength) ?? '',
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

  /// update_entry 的审批「详细」：非秘密字段 old → new，秘密字段只说"已修改"。
  ///
  /// 为什么必须在审批弹窗里给出新值（H9）：智能体可以把 `url` 改成攻击者域名，
  /// 而浏览器扩展按 URL 匹配自动填充 —— 用户只看到"修改字段：url"时无法判断
  /// 这是不是一次凭据投毒。
  String _updateApprovalDetail(
    VaultItem before,
    VaultItem after,
    List<String> fields,
    Map<String, String> folders,
  ) {
    String folderLabel(String? id) => id == null ? '未归类' : (folders[id] ?? id);
    final parts = <String>[];
    for (final field in fields) {
      switch (field) {
        case 'name':
          parts.add('标题「${_clipDetail(before.name)}」→「${_clipDetail(after.name)}」');
          break;
        case 'url':
          parts.add('URL「${_clipDetail(before.loginOrEmpty.url)}」'
              '→「${_clipDetail(after.loginOrEmpty.url)}」');
          break;
        case 'username':
          parts.add('用户名「${_clipDetail(before.loginOrEmpty.username)}」'
              '→「${_clipDetail(after.loginOrEmpty.username)}」');
          break;
        case 'password':
          parts.add('密码：已修改（值不显示）');
          break;
        case 'notes':
          parts.add('备注：已修改（值不显示）');
          break;
        case 'folder':
          parts.add('文件夹「${folderLabel(before.folderId)}」'
              '→「${folderLabel(after.folderId)}」');
          break;
        case 'isFavorite':
          parts.add('收藏：${before.isFavorite ? '是' : '否'} → '
              '${after.isFavorite ? '是' : '否'}');
          break;
        case 'customFields':
          final labels = after.customFields.map((f) => f.label).join('、');
          parts.add('自定义字段已修改（仅显示标签：$labels；值不显示）');
          break;
      }
    }
    return '修改字段：${parts.join('；')}';
  }

  /// `delete_entry`：**只做软删**（移到回收站）。彻底删除只存在于 UI。
  Future<Map<String, Object?>> _deleteEntry(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    call.errorEntryId = id;
    _requireEntryToolsUnlocked(call, principal, pairing, op: AgentOp.delete);

    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(call, item);
    if (item.deletedAt != null) {
      throw McpToolException('invalidRequest', '该条目已经在回收站里');
    }

    _precheckOrDeny(call, principal, pairing, item, op: AgentOp.delete);
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'delete_entry',
      op: AgentOp.delete,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: '移到回收站（可恢复，不会彻底删除）',
    );

    // H1：审批期间用户可能已删除/恢复/关闭 —— 重读后按当前状态决定。
    final latest = await _repository.getItem(id, includeDeleted: true);
    if (latest == null) {
      _deny(call, principal, fresh,
          tool: 'delete_entry',
          op: AgentOp.delete,
          code: 'notFound',
          message: '找不到该条目',
          entryId: id);
    }
    if (latest.deletedAt != null) {
      _deny(call, principal, fresh,
          tool: 'delete_entry',
          op: AgentOp.delete,
          code: 'invalidRequest',
          message: '该条目已经在回收站里',
          entryId: id);
    }
    _precheckOrDeny(call, principal, fresh, latest, op: AgentOp.delete);
    _evaluateOrDeny(call, principal, fresh, latest, op: AgentOp.delete);

    // 条件软删：`trashEntry` 自身带 `deleted_at IS NULL` 条件，天然防并发。
    final trashed = await _repository.deleteItem(id);
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'delete_entry',
      op: AgentOp.delete,
      decision: trashed ? 'allowed' : 'error',
      entryId: latest.id,
      entryName: latest.name,
    );
    if (!trashed) {
      throw McpToolException('internal', '删除失败（条目状态已变化，请重试）');
    }
    _notifyDataChanged();
    return {
      'ok': true,
      'trashed': true,
      'note': '已移到回收站，可由用户恢复。',
    };
  }

  /// `list_trash`：列出回收站里**对智能体开放**的条目元数据。
  Future<Map<String, Object?>> _listTrash(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
  ) async {
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'list_trash',
      detail: '查看回收站中开放的条目（只读元数据）',
    );
    final items = await _repository.getTrashedItems();
    final folders = await _folderNames();
    final visible = [
      for (final item in items)
        if (AgentAccessPolicy.evaluate(_requestFor(call, fresh, item)).allowed) item,
    ];
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'list_trash',
      op: AgentOp.read,
      decision: _allowedDecision(call),
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
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    call.errorEntryId = id;
    _requireEntryToolsUnlocked(call, principal, pairing, op: AgentOp.write);

    final item = await _repository.getItem(id, includeDeleted: true);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(call, item);
    if (item.deletedAt == null) {
      throw McpToolException('invalidRequest', '该条目不在回收站里');
    }

    _precheckOrDeny(call, principal, pairing, item, op: AgentOp.write);
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'restore_entry',
      op: AgentOp.write,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: '从回收站恢复「${_clipDetail(item.name)}」',
    );

    // H1：审批期间可能被彻底删除、恢复或关闭开关 —— 重读后按当前状态决定。
    final latest = await _repository.getItem(id, includeDeleted: true);
    if (latest == null) {
      _deny(call, principal, fresh,
          tool: 'restore_entry',
          op: AgentOp.write,
          code: 'notFound',
          message: '找不到该条目',
          entryId: id);
    }
    if (latest.deletedAt == null) {
      _deny(call, principal, fresh,
          tool: 'restore_entry',
          op: AgentOp.write,
          code: 'invalidRequest',
          message: '该条目已不在回收站里',
          entryId: id);
    }
    _precheckOrDeny(call, principal, fresh, latest, op: AgentOp.write);
    _evaluateOrDeny(call, principal, fresh, latest, op: AgentOp.write);

    // 条件恢复：`restoreEntry` 自身带 `deleted_at IS NOT NULL` 条件。
    final restored = await _repository.restoreItem(id);
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'restore_entry',
      op: AgentOp.write,
      decision: restored ? 'allowed' : 'error',
      entryId: latest.id,
      entryName: latest.name,
    );
    if (!restored) {
      throw McpToolException('internal', '恢复失败（条目状态已变化，请重试）');
    }
    _notifyDataChanged();
    return {'ok': true, 'restored': true};
  }

  // ─── 敏感读：剪贴板 ────────────────────────────────────

  /// 复制某字段到系统剪贴板：**只回 ok，不回明文**。
  ///
  /// 这是"密码不需要让智能体知道"的落点：明文只在本机进程之间传递
  /// （核心 → 剪贴板），智能体拿到的是"已复制"这个事实，然后自己去目标窗口粘贴。
  /// 安全纪律：
  /// - 按**敏感读**判定（不享受"本会话免询问"）；
  /// - 条目必须是"开放"、类型必须暴露（H5：identity/SSH 的专属字段已从工具面移除）；
  /// - 字段/自定义标签在审批**之前**校验（无效请求不弹窗）；
  /// - 审计只记条目与字段名（`op=clipboard:<field>`），绝不记值。
  Future<Map<String, Object?>> _copyToClipboard(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    final id = _requiredId(args);
    call.errorEntryId = id;
    final rawField = args['field'];
    if (rawField != null && rawField is! String) {
      throw McpToolException('invalidRequest', 'field 必须是字符串');
    }
    final field = ((rawField as String?) ?? 'password').trim();
    final resolvedField = field.isEmpty ? 'password' : field;
    if (!_clipboardFields.contains(resolvedField)) {
      throw McpToolException('invalidRequest', '不支持复制该字段');
    }
    final rawLabel = args['customLabel'];
    if (rawLabel != null && rawLabel is! String) {
      throw McpToolException('invalidRequest', 'customLabel 必须是字符串');
    }
    final customLabel = (rawLabel as String?)?.trim() ?? '';
    if (resolvedField == 'custom' && customLabel.isEmpty) {
      throw McpToolException('invalidRequest', 'field=custom 时 customLabel 必填');
    }
    // 审计 op 带上字段名（M4：SECURITY 承诺"按条目与字段名审计"）。
    call.auditOp = 'clipboard:$resolvedField';

    _requireEntryToolsUnlocked(call, principal, pairing, op: AgentOp.sensitiveRead);
    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
    _setAuditTarget(call, item);
    _ensureClipboardFieldApplicable(item, resolvedField, customLabel);
    _precheckOrDeny(call, principal, pairing, item, op: AgentOp.sensitiveRead);

    final detail = resolvedField == 'custom'
        ? '复制字段：custom（$customLabel）'
        : '复制字段：$resolvedField';
    final fresh = await _gate(
      call,
      pairing,
      principal,
      tool: 'copy_to_clipboard',
      op: AgentOp.sensitiveRead,
      allowStanding: false,
      entryId: item.id,
      entryName: item.name,
      detail: detail,
    );

    // H1：审批窗口内可能被关闭/删除/改类型。
    final latest = await _repository.getItem(id);
    if (latest == null) {
      _deny(call, principal, fresh,
          tool: 'copy_to_clipboard',
          op: AgentOp.sensitiveRead,
          code: 'notFound',
          message: '找不到该条目',
          entryId: id);
    }
    _ensureClipboardFieldApplicable(latest, resolvedField, customLabel);
    _precheckOrDeny(call, principal, fresh, latest, op: AgentOp.sensitiveRead);
    _evaluateOrDeny(call, principal, fresh, latest, op: AgentOp.sensitiveRead);

    final value = _fieldValue(latest, resolvedField, customLabel);
    if (value == null) throw McpToolException('invalidRequest', '未知字段：$resolvedField');
    if (value.isEmpty) throw McpToolException('notFound', '该条目的这个字段是空的');

    final ok = await _clipboardWriter(value);
    _auditAdd(
      call,
      principal,
      mode: fresh.mode,
      tool: 'copy_to_clipboard',
      op: AgentOp.sensitiveRead,
      decision: ok ? 'allowed' : 'error',
      entryId: latest.id,
      entryName: latest.name,
    );
    if (!ok) {
      throw McpToolException('internal', '剪贴板被占用或不可用，请重试');
    }
    // **绝不回传 value**：只回事实。长度也不回（D10：少一处可被用来猜密码的旁路）。
    return {
      'ok': true,
      'entryId': latest.id,
      'field': resolvedField,
      'note': '已复制到剪贴板；内容不会返回给模型，请直接在目标窗口粘贴。',
    };
  }

  void _ensureClipboardFieldApplicable(
    VaultItem item,
    String field,
    String customLabel,
  ) {
    switch (field) {
      case 'password':
      case 'totp':
        if (item.type != EntryType.login) {
          throw McpToolException('invalidRequest', '该字段只属于 login 条目');
        }
        break;
      case 'custom':
        final exists = item.customFields.any((f) => f.label.trim() == customLabel);
        if (!exists) {
          throw McpToolException('invalidRequest', '该条目没有这个自定义字段');
        }
        break;
      case 'notes':
        break;
      default:
        throw McpToolException('invalidRequest', '不支持复制该字段');
    }
  }

  /// 取字段值。identity/SSH 专属字段已从工具面移除（H5），
  /// 这里保留实现只为兼容旧数据/内部调用；正常调用不可达。
  String? _fieldValue(VaultItem item, String field, String customLabel) {
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
        for (final custom in item.customFields) {
          if (custom.label.trim() == customLabel) return custom.value;
        }
        return '';
      default:
        return null;
    }
  }

  // ─── 内部：授权闸门 ────────────────────────────────────

  /// 单条目工具的前置条件：agent 会话域必须已解锁。
  ///
  /// 旧实现"先查库后过闸"：agent 域锁定时仓储 keyReader 为 null → 返回 null →
  /// 工具直接报 `notFound`，审批弹窗根本不出现（H3）。现在明确报 `locked`，
  /// 且**不弹审批**（锁定态下弹窗也无法借到钥匙，只会制造无意义审批）。
  void _requireEntryToolsUnlocked(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing pairing, {
    required AgentOp op,
  }) {
    if (_sessions.agent.isUnlocked) return;
    _deny(
      call,
      principal,
      pairing,
      tool: call.tool,
      op: op,
      code: 'locked',
      message: '智能体会话未解锁：请在 EasyPass 中解锁或重新开启智能体访问',
    );
  }

  /// 请求级闸门：决定"这次调用有没有资格继续"。
  ///
  /// - 方式 2（可信直通）：重读 pairing / 总开关后按策略校验，不需要同意；
  /// - 方式 1：先看"本会话免询问"（仅普通读、且仅该配对），否则向 UI 发审批
  ///   并等待。用户拒绝 / 超时 / 取消 ⇒ 抛 `denied`（fail closed），绝不静默执行。
  /// - 审批通过后**重新读取配对与总开关**，再复核策略（H1：审批窗口内撤销/切方式
  ///   必须生效）。
  ///
  /// 返回值是**新鲜**的 pairing，调用方必须用它做后续判定。
  Future<AgentPairing> _gate(
    _AgentCall call,
    AgentPairing pairing,
    McpPrincipal principal, {
    required String tool,
    AgentOp op = AgentOp.read,
    bool allowStanding = true,
    String? entryId,
    String? entryName,
    String? detail,
  }) async {
    call.approved = false;
    call.standing = false;

    if (pairing.mode == AgentMode.trusted) {
      if (!_sessions.agent.isUnlocked) {
        _deny(
          call,
          principal,
          pairing,
          tool: tool,
          op: op,
          code: 'locked',
          message: '智能体会话未解锁：请在 EasyPass 中解锁或重新开启智能体访问',
          entryId: entryId,
          entryName: entryName,
        );
      }
      final fresh = await _reloadPairingAfterGate(
        call,
        principal,
        pairing,
        tool: tool,
        op: op,
        entryId: entryId,
        entryName: entryName,
      );
      _assertRequestAllowed(fresh, approvedThisCall: false, standing: false, op: op);
      _enterKeyUse(call);
      return fresh;
    }

    // 方式 1：本会话已放行读（仅普通读）。
    if (allowStanding && op == AgentOp.read && _standingRead.contains(pairing.id)) {
      call.standing = true;
      final fresh = await _reloadPairingAfterGate(
        call,
        principal,
        pairing,
        tool: tool,
        op: op,
        entryId: entryId,
        entryName: entryName,
      );
      _borrowKeyFromUiForThisCall(call);
      _assertRequestAllowed(fresh, approvedThisCall: false, standing: true, op: op);
      return fresh;
    }

    final verdict = await _requestApproval(
      pairing,
      op: op,
      toolName: tool,
      allowStandingOption: allowStanding && op == AgentOp.read,
      entryId: entryId,
      entryName: entryName,
      detail: detail,
    );
    if (verdict != _ApprovalVerdict.allowed) {
      // 一次调用一行：超时记 timeout，拒绝/取消/限流记 denied（不重复写）。
      _auditAdd(
        call,
        principal,
        mode: pairing.mode,
        tool: tool,
        op: op,
        decision: verdict == _ApprovalVerdict.timeout ? 'timeout' : 'denied',
        entryId: entryId,
        entryName: entryName,
      );
      throw McpToolException(
        'denied',
        switch (verdict) {
          _ApprovalVerdict.timeout => '审批超时，本次操作未执行',
          _ApprovalVerdict.rateLimited => '审批请求过多，本次操作未执行，请稍后重试',
          _ApprovalVerdict.cancelled => '审批已被取消，本次操作未执行',
          _ => '用户未同意本次操作',
        },
      );
    }

    call.approved = true;
    final fresh = await _reloadPairingAfterGate(
      call,
      principal,
      pairing,
      tool: tool,
      op: op,
      entryId: entryId,
      entryName: entryName,
    );
    // 用户当面同意之后才借钥匙；ui 已锁则借不到（fail closed）。
    _borrowKeyFromUiForThisCall(call);
    _assertRequestAllowed(fresh, approvedThisCall: true, standing: false, op: op);
    return fresh;
  }

  /// 审批/免询问路径之后重读配对与总开关；任何一项变化都拒绝（H1）。
  Future<AgentPairing> _reloadPairingAfterGate(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing snapshot, {
    required String tool,
    required AgentOp op,
    String? entryId,
    String? entryName,
  }) async {
    final fresh = await _pairingStore.findById(principal.pairingId);
    if (fresh == null || fresh.isRevoked) {
      _deny(call, principal, snapshot,
          tool: tool,
          op: op,
          message: '配对已失效，本次操作未执行',
          entryId: entryId,
          entryName: entryName);
    }
    if (fresh.isExpiredAt(_now)) {
      _deny(call, principal, snapshot,
          tool: tool,
          op: op,
          message: '配对已过期，本次操作未执行',
          entryId: entryId,
          entryName: entryName);
    }
    if (fresh.mode != snapshot.mode) {
      _deny(call, principal, snapshot,
          tool: tool,
          op: op,
          message: '访问方式已变更，本次操作未执行',
          entryId: entryId,
          entryName: entryName);
    }
    if (!await _isAccessEnabled()) {
      _deny(call, principal, snapshot,
          tool: tool,
          op: op,
          message: '智能体访问已关闭，本次操作未执行',
          entryId: entryId,
          entryName: entryName);
    }
    return fresh;
  }

  void _assertRequestAllowed(
    AgentPairing pairing, {
    required bool approvedThisCall,
    required bool standing,
    AgentOp op = AgentOp.read,
  }) {
    final result = AgentAccessPolicy.evaluate(AgentAccessRequest(
      op: op,
      entryOpen: true,
      typeExposed: true,
      revoked: pairing.isRevoked,
      expired: pairing.isExpiredAt(_now),
      sessionUnlocked: _sessions.agent.isUnlocked,
      mode: pairing.mode,
      trusted: pairing.trusted,
      approvedThisCall: approvedThisCall,
      standingRead: standing,
    ));
    if (!result.allowed) {
      // 不回传策略枚举名：拒绝原因只留给服务端（策略文件自己的纪律）。
      throw McpToolException('denied', '访问被拒绝');
    }
  }

  /// 审批前硬闸预检：条目未开放 / 类型不暴露 / 越界 / 配对失效时**不弹审批**。
  void _precheckOrDeny(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing pairing,
    VaultItem item, {
    required AgentOp op,
  }) {
    final reason = AgentAccessPolicy.precheck(_requestFor(call, pairing, item, op: op));
    if (reason == null) return;
    _deny(
      call,
      principal,
      pairing,
      tool: call.tool,
      op: op,
      message: '条目未开放或本次访问不被允许',
      entryId: item.id,
      entryName: item.name,
    );
  }

  /// 审批后的最终判定（用新鲜 pairing + item 跑完整 evaluate）。
  void _evaluateOrDeny(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing pairing,
    VaultItem item, {
    required AgentOp op,
  }) {
    final result = AgentAccessPolicy.evaluate(_requestFor(call, pairing, item, op: op));
    if (result.allowed) return;
    _deny(
      call,
      principal,
      pairing,
      tool: call.tool,
      op: op,
      message: '条目未开放或本次访问不被允许',
      entryId: item.id,
      entryName: item.name,
    );
  }

  /// 记一行 denied 审计并抛出业务错误（`Never`）。
  Never _deny(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing pairing, {
    required String tool,
    required AgentOp op,
    required String message,
    String code = 'denied',
    String decision = 'denied',
    String? entryId,
    String? entryName,
  }) {
    _auditAdd(
      call,
      principal,
      mode: pairing.mode,
      tool: tool,
      op: op,
      decision: decision,
      entryId: entryId,
      entryName: entryName,
    );
    throw McpToolException(code, message);
  }

  AgentAccessRequest _requestFor(
    _AgentCall call,
    AgentPairing pairing,
    VaultItem item, {
    AgentOp op = AgentOp.read,
  }) {
    return AgentAccessRequest(
      op: op,
      entryOpen: item.agentOpen,
      typeExposed: _isExposedType(item.type),
      revoked: pairing.isRevoked,
      expired: pairing.isExpiredAt(_now),
      sessionUnlocked: _sessions.agent.isUnlocked,
      inScope: _inScope(pairing, item),
      mode: pairing.mode,
      trusted: pairing.trusted,
      approvedThisCall: call.approved,
      standingRead: call.standing,
    );
  }

  /// 只有 login / secure_note 对智能体暴露（H5；identity/SSH 永不可达）。
  static bool _isExposedType(EntryType type) =>
      type == EntryType.login || type == EntryType.secureNote;

  bool _inScope(AgentPairing pairing, VaultItem item) {
    final folders = pairing.scopeFolders;
    final types = pairing.scopeTypes;
    if (folders.isEmpty && types.isEmpty) return true;
    if (item.folderId != null && folders.contains(item.folderId)) return true;
    return types.contains(item.type.wireName);
  }

  // ─── 内部：审批 ────────────────────────────────────────

  /// 向 UI 发一次审批并等待。
  ///
  /// 超时/取消/拒绝都返回结局；**审计由 `_gate` 统一写**（一次调用一行）。
  /// 审批并发超过上限时直接返回 `rateLimited`（不广播、不落 pending）。
  Future<_ApprovalVerdict> _requestApproval(
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
    if (sink == null) return _ApprovalVerdict.denied;

    // M2：每配对 / 全局 pending 上限。超限直接拒绝，不打扰用户。
    final pairingPending =
        _pendingPairing.values.where((id) => id == pairing.id).length;
    if (pairingPending >= maxPendingApprovalsPerPairing ||
        _pendingApprovals.length >= maxPendingApprovalsGlobal) {
      return _ApprovalVerdict.rateLimited;
    }

    final approvalId = 'a_${_uuid.v4()}';
    final completer = Completer<_ApprovalVerdict>();
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
      // 写/删的"详细"：**只列字段名与动作/非秘密值**，绝不含秘密值（§10 口径）。
      'detail': ?detail,
    });

    _ApprovalVerdict verdict;
    try {
      verdict = await completer.future.timeout(_approvalTimeout);
    } on TimeoutException {
      verdict = _ApprovalVerdict.timeout;
      // 超时也要通知 UI 关闭弹窗（否则陈旧弹窗还能点，用户以为还来得及）。
      onApprovalResolved?.call(approvalId, 'timeout');
    } finally {
      _pendingApprovals.remove(approvalId);
      _pendingPairing.remove(approvalId);
      _pendingAllowStanding.remove(approvalId);
    }
    return verdict;
  }

  // ─── 内部：借钥匙（方式 1）─────────────────────────────

  /// 方式 1 的一次性钥匙：从 **ui 域**复制一份给 agent 域。
  ///
  /// 为什么必须复制：`VaultSession._wipe()` 是原地清零，共享同一个 `Uint8List`
  /// 会让"锁 agent 域"顺手把 ui 的密钥清零（反之亦然）。
  /// 为什么从 ui 取：审批是用户当面点的，说明 ui 域此刻是可信且已解锁的。
  void _borrowKeyFromUiForThisCall(_AgentCall call) {
    if (_sessions.agent.isUnlocked) {
      _enterKeyUse(call);
      return;
    }
    final uiKey = _sessions.ui.key;
    if (uiKey == null) {
      throw McpToolException(
        'locked',
        '保险库已锁定：请在 EasyPass 里解锁后再批准智能体访问',
      );
    }
    _sessions.agent.unlock(Uint8List.fromList(uiKey));
    _borrowedKey = true;
    _enterKeyUse(call);
  }

  void _enterKeyUse(_AgentCall call) {
    if (call.keyUser) return;
    call.keyUser = true;
    _keyUsers++;
  }

  /// 调用结束时收尾：最后一个钥匙使用者离开、且钥匙是"借来的"才锁回。
  void _leaveKeyUse(_AgentCall call) {
    if (!call.keyUser) return;
    call.keyUser = false;
    if (_keyUsers > 0) _keyUsers--;
    if (_keyUsers == 0 && _borrowedKey) {
      _borrowedKey = false;
      _sessions.agent.lock();
    }
  }

  // ─── 内部：数据视图与工具函数 ──────────────────────────

  Future<List<VaultItem>> _visibleItems(
    _AgentCall call,
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
    final visible = <VaultItem>[];
    for (final item in candidates) {
      // 搜索路径不支持 SQL 过滤：在内存里补 type/folder 条件（否则
      // `type=login&query=x` 会把其它类型也返回回来）。
      if (query.isNotEmpty) {
        if (type != null && item.type != type) continue;
        if (folderId != null && item.folderId != folderId) continue;
      }
      if (AgentAccessPolicy.evaluate(_requestFor(call, pairing, item)).allowed) {
        visible.add(item);
      }
    }
    return visible;
  }

  /// 文件夹 id → 名称（详情/审批「详细」用；删掉的文件夹回退成 id）。
  Future<Map<String, String>> _folderNames() async {
    final folders = await _repository.getFolders();
    return {for (final folder in folders) folder.id: folder.name};
  }

  /// 总开关是否打开（`end_session` 与审批后复核用）。
  Future<bool> _isAccessEnabled() => _agentAccess.isEnabled();

  void _setAuditTarget(_AgentCall call, VaultItem item) {
    call.errorEntryId = item.id;
    call.errorEntryName = item.name;
  }

  static String _requiredId(Map<String, Object?> args) {
    final raw = args['id'];
    if (raw != null && raw is! String) {
      throw McpToolException('invalidRequest', 'id 必须是字符串');
    }
    final id = ((raw as String?) ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');
    return id;
  }

  static String _requiredText(
    Map<String, Object?> args,
    String key, {
    required int maxLength,
  }) {
    final value = _optionalText(args, key, maxLength: maxLength)?.trim() ?? '';
    if (value.isEmpty) throw McpToolException('invalidRequest', '$key 必填');
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

  /// 只接受字符串的选填参数（非字符串一律 invalidRequest，避免类型错误
  /// 被当成"没传"而改变语义）。
  static String? _optionalString(Map<String, Object?> args, String key) {
    final raw = args[key];
    if (raw == null) return null;
    if (raw is! String) {
      throw McpToolException('invalidRequest', '$key 必须是字符串');
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
      final rawLength = raw['length'];
      if (rawLength != null && rawLength is! num) {
        throw McpToolException('invalidRequest', 'length 必须是数字');
      }
      final length = ((rawLength as num?)?.toInt() ?? 20).clamp(8, 128);
      // 只透传真正的 bool：客户端传 "false" 之类的字符串时不能让它把
      // 生成器的 `as bool?` 转炸（参数类型错误 → invalidRequest）。
      final options = <String, dynamic>{'length': length};
      for (final key in const [
        'useUpper',
        'useLower',
        'useNumbers',
        'useSymbols',
      ]) {
        final value = raw[key];
        if (value == null) continue;
        if (value is! bool) {
          throw McpToolException('invalidRequest', '$key 必须是布尔值');
        }
        options[key] = value;
      }
      final password = generatePassword(options);
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
  static EntryType _writableType(Object? raw) {
    if (raw != null && raw is! String) {
      throw McpToolException('invalidRequest', 'type 必须是字符串');
    }
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
      final rawLabel = entry['label'];
      if (rawLabel is! String || rawLabel.trim().isEmpty) {
        throw McpToolException('invalidRequest', '自定义字段的 label 必填');
      }
      final rawValue = entry['value'];
      if (rawValue != null && rawValue is! String) {
        throw McpToolException('invalidRequest', '自定义字段的 value 必须是字符串');
      }
      final value = (rawValue as String?) ?? '';
      if (value.length > _maxFieldLength) {
        throw McpToolException('invalidRequest', '自定义字段的值太长');
      }
      final rawType = entry['type'];
      if (rawType != null && rawType is! String) {
        throw McpToolException('invalidRequest', '自定义字段的 type 必须是字符串');
      }
      fields.add(CustomField(
        label: rawLabel.trim(),
        value: value,
        type: CustomFieldType.fromWire((rawType as String?) ?? 'text'),
      ));
    }
    return fields;
  }

  // ─── 内部：审计 ────────────────────────────────────────

  /// 本次调用放行时该记的 decision。
  ///
  /// 靠「本会话内允许读取」放行的读，必须记成 `allowed_standing`：
  /// 否则审计里"用户这次点了同意"和"被免询问绕过"完全不可区分。
  String _allowedDecision(_AgentCall call) =>
      call.standing ? 'allowed_standing' : 'allowed';

  void _auditAdd(
    _AgentCall call,
    McpPrincipal principal, {
    required AgentMode mode,
    required String tool,
    required AgentOp op,
    required String decision,
    String? entryId,
    String? entryName,
  }) {
    // 一次调用只允许一行审计：后续的失败兜底看到这个标志就闭嘴。
    call.audited = true;
    _emitAudit(
      pairingId: principal.pairingId,
      nickname: principal.nickname,
      mode: mode.name,
      tool: tool,
      op: call.auditOp ?? _opLabel(op),
      decision: decision,
      entryId: entryId,
      entryName: entryName,
    );
  }

  /// 底层审计写入：内存环形缓冲 + 落库旁路（失败静默） + UI 广播。
  void _emitAudit({
    required String pairingId,
    required String nickname,
    required String mode,
    required String tool,
    required String op,
    required String decision,
    String? entryId,
    String? entryName,
  }) {
    final entry = AgentAuditEntry(
      at: _now,
      pairingId: pairingId,
      nickname: nickname,
      mode: mode,
      tool: tool,
      op: op,
      entryId: entryId,
      entryName: entryName,
      decision: decision,
    );
    _auditQueue.addLast(entry);
    while (_auditQueue.length > _auditCapacity) {
      _auditQueue.removeFirst();
    }

    final sink = _auditSink;
    if (sink != null) {
      unawaited(Future<void>.sync(() => sink(entry)).catchError((Object _) {}));
    }
    onAuditRecorded?.call();
  }

  /// 失败兜底：只有这次调用**还没有**写过审计行时才补一条 `error`。
  ///
  /// 兜底覆盖 `notFound` / 参数不对 / 意外异常；拒绝与超时已经各自记过
  /// `denied` / `timeout`，这里不重复。
  void _auditErrorIfNeeded(
    _AgentCall call,
    McpPrincipal principal,
    AgentPairing pairing,
  ) {
    if (call.audited) return;
    _auditAdd(
      call,
      principal,
      mode: pairing.mode,
      tool: call.tool,
      op: call.op,
      decision: 'error',
      entryId: call.errorEntryId,
      entryName: call.errorEntryName,
    );
  }

  static String _nicknameOf(AgentPairing pairing) =>
      pairing.nickname.trim().isEmpty ? '未命名智能体' : pairing.nickname;

  static String _opLabel(AgentOp op) => switch (op) {
        AgentOp.read => 'read',
        AgentOp.sensitiveRead => 'sensitiveRead',
        AgentOp.write => 'write',
        AgentOp.delete => 'delete',
      };

  /// 工具 → 操作类型（失败审计与状态展示用；具体工具会自己传准确 op）。
  static AgentOp _opForTool(String tool) => switch (tool) {
        'create_entry' || 'update_entry' || 'restore_entry' => AgentOp.write,
        'delete_entry' => AgentOp.delete,
        'copy_to_clipboard' => AgentOp.sensitiveRead,
        _ => AgentOp.read,
      };

  /// 审批「详细」里展示值的截断：显式标记，避免"看起来完整其实被砍"。
  static String _clipDetail(String value, [int max = _maxDetailValueLength]) {
    if (value.length <= max) return value;
    return '${value.substring(0, max)}…（已截断）';
  }
}
