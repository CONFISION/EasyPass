// 命名参数用可读的公开名映射到私有字段（与 core_actions.dart / core_service.dart
// 同款），刻意不用 initializing formal。
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';

import 'package:easypass/core/crypto/totp_service.dart';
import 'package:easypass/core/platform/system_clipboard.dart';
import 'package:easypass/core_service/agent_access_policy.dart';
import 'package:easypass/core_service/agent_access_store.dart';
import 'package:easypass/core_service/agent_pairing_store.dart';
import 'package:easypass/core_service/session_domains.dart';
import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/data/repositories/vault_repository.dart';
import 'package:easypass/mcp/mcp_handler.dart';
import 'package:easypass/protocol/codecs.dart';

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

  /// 审批超时：必须短于客户端自己的 `tools/call` 超时（DSH 默认 60s），
  /// 否则客户端先超时、用户随后点"同意"就成了对没人等待的调用授权。
  static const Duration approvalTimeout = Duration(seconds: 45);

  /// 向 UI 广播审批请求的钩子（核心把它接到 `_broadcast`）。
  void Function(Map<String, Object?> request)? onApprovalRequested;

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

    switch (tool) {
      case 'status':
        return _status(pairing, principal);      case 'begin_session':
        return _beginSession(pairing, principal, args);
      case 'end_session':
        return _endSession(pairing, principal);
      case 'list_entries':
        return _listEntries(pairing, principal, args);
      case 'get_entry':
        return _getEntry(pairing, principal, args);
      case 'copy_to_clipboard':
        return _copyToClipboard(pairing, principal, args);
      default:
        throw McpToolException('invalidRequest', '未知工具：$tool');
    }
  }

  // ─── 工具 ──────────────────────────────────────────────

  Future<Map<String, Object?>> _status(
    AgentPairing pairing,
    McpPrincipal principal,
  ) async {
    final unlocked = _sessions.agent.isUnlocked;
    var visible = 0;
    if (unlocked) {
      visible = (await _visibleItems(pairing)).length;
    }
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

  Future<Map<String, Object?>> _beginSession(
    AgentPairing pairing,
    McpPrincipal principal,
    Map<String, Object?> args,
  ) async {
    _requireUnlocked();
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
      decision: 'allowed',
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
    _requireUnlocked();
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
      decision: 'allowed',
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
    _requireUnlocked();
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');
    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
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
      decision: 'allowed',
    );
    final folders = await _folderNames();
    return entryToAgentJson(item, folderName: folders[item.folderId]);
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
    _requireUnlocked();
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');

    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');
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

  void _requireUnlocked() {
    if (!_sessions.agent.isUnlocked) {
      throw McpToolException('locked', '保险库已锁定：请先在 EasyPass 里解锁');
    }
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
  }) async {
    _callApproved = false;
    _callStanding = false;

    if (pairing.mode == AgentMode.trusted) {
      _assertRequestAllowed(pairing, approvedThisCall: false);
      return;
    }

    // 方式 1：本会话已放行读（仅普通读）。
    if (allowStanding &&
        op == AgentOp.read &&
        _standingRead.contains(pairing.id)) {
      _callStanding = true;
      _assertRequestAllowed(pairing, approvedThisCall: false);
      return;
    }

    final approved = await _requestApproval(
      pairing,
      op: op,
      toolName: tool,
      allowStandingOption: allowStanding && op == AgentOp.read,
      entryId: entryId,
      entryName: entryName,
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
    _assertRequestAllowed(pairing, approvedThisCall: true);
  }

  void _assertRequestAllowed(
    AgentPairing pairing, {
    required bool approvedThisCall,
  }) {
    _requireAllowed(
      pairing,
      AgentAccessRequest(
        op: AgentOp.read,
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
  }
}
