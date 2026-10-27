// 命名参数用可读的公开名映射到私有字段（与 core_actions.dart / core_service.dart
// 同款），刻意不用 initializing formal。
// ignore_for_file: prefer_initializing_formals

import 'dart:collection';

import 'package:easypass/core_service/agent_access_policy.dart';
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
    required this.nickname,
    required this.mode,
    required this.tool,
    required this.op,
    this.entryId,
    this.entryName,
    required this.decision,
  });

  final int at;
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
    DateTime Function()? clock,
    int auditCapacity = 200,
  })  : _repository = repository,
        _sessions = sessions,
        _pairingStore = pairingStore,
        _clock = clock ?? DateTime.now,
        _auditCapacity = auditCapacity;

  final VaultRepository _repository;
  final SessionDomains _sessions;
  final AgentPairingStore _pairingStore;
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

    switch (tool) {
      case 'status':
        return _status(pairing, principal);
      case 'begin_session':
        return _beginSession(pairing, principal, args);
      case 'end_session':
        return _endSession(pairing, principal);
      case 'list_entries':
        return _listEntries(pairing, principal, args);
      case 'get_entry':
        return _getEntry(pairing, principal, args);
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
    _requireRequestAllowed(pairing);

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
    // 会话结束**立即锁 agent 域**（不调 lockAll：不把用户正在用的 UI 踢下线）。
    _sessions.agent.lock();
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
    _requireRequestAllowed(pairing);
    final query = (args['query'] as String? ?? '').trim();
    final folders = await _folderNames();
    final items = await _visibleItems(
      pairing,
      type: EntryType.fromWire(args['type']),
      folderId: args['folder'] as String?,
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
    _requireRequestAllowed(pairing);
    final id = (args['id'] as String? ?? '').trim();
    if (id.isEmpty) throw McpToolException('invalidRequest', 'id 必填');
    final item = await _repository.getItem(id);
    if (item == null) throw McpToolException('notFound', '找不到该条目');

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

  AgentAccessRequest _requestFor(AgentPairing pairing, VaultItem item) {
    return AgentAccessRequest(
      op: AgentOp.read,
      entryOpen: item.agentOpen,
      revoked: pairing.isRevoked,
      expired: pairing.isExpiredAt(_now),
      sessionUnlocked: _sessions.agent.isUnlocked,
      inScope: _inScope(pairing, item),
      mode: pairing.mode,
      trusted: pairing.trusted,
      // 阶段 1 还没有审批 UI：方式 1 一律 notApproved（fail closed）。
      // 请求级闸门已经先把方式 1 挡住了，这里保留同样的口径以防将来加审批时漏改。
      approvedThisCall: false,
      standingRead: false,
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

  void _requireAllowed(AgentPairing pairing, AgentAccessRequest request) {
    final result = AgentAccessPolicy.evaluate(request);
    if (!result.allowed) {
      throw McpToolException('denied', '访问被拒绝（${result.reason!.name}）');
    }
  }

  /// 请求级闸门（**在读任何条目之前**）。
  ///
  /// 为什么要单独一道：如果只做逐条过滤，方式 1 在阶段 1 会"静默返回空列表"——
  /// agent 看到的是"没有条目"，而不是"你没被批准"。显式拒绝才符合 fail closed，
  /// 也让排查有据可依。
  void _requireRequestAllowed(AgentPairing pairing) {
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
        // 阶段 1 还没有审批 UI：方式 1 一律 notApproved（fail closed）。
        approvedThisCall: false,
        standingRead: false,
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
  }
}
