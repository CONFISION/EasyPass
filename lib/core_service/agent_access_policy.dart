/// 智能体访问判定 —— **纯函数**，不做任何 IO。
///
/// 为什么要单独抽出来：这是整个智能体接口最该被测试压死的地方。
/// 两个真实先例说明"授权本身放行"比"权限被攻破"更常见：
/// - Asana 的 MCP 跨租户泄露：**内部租户隔离 bug**，不是攻击；
/// - Supabase MCP 外泄：官方定性是「No permissions were violated. The agent
///   just followed instructions it should never have trusted.」
///
/// 判定顺序（评审修复后）：
/// 1. 条目开关（I-9，永远第一条）；
/// 2. 条目类型是否对智能体暴露（H5：只有 login / secure_note）；
/// 3. 配对身份 / 会话 / 范围 / 操作类型；
/// 4. 访问方式（可信直通 / 逐次审批 + 本会话免询问）。
/// 1、2 两档是"任何方式、任何 scope、任何可信状态都突破不了"的硬闸。
library;

/// 访问方式（用户在 设置 → 智能体访问方式 里切换）。
enum AgentMode {
  /// 每次调用都要用户审批（读也审批，可勾"本会话内允许读取"）。
  approval,

  /// 可信直通：配对经用户二次校验后不再逐次审批，但每次访问都写审计。
  trusted,
}

/// 一次操作的类型。分档是硬约束：**敏感读不享受"本会话免询问"**。
enum AgentOp {
  /// 读元数据（list / get / status / session 开关）。
  read,

  /// 读明文或验证码（reveal / totp / clipboard）。
  sensitiveRead,

  /// 新建 / 修改（含 restore）。
  write,

  /// 删除。
  delete,
}

/// 拒绝原因。只进服务端判定，**不进模型上下文、不进审批文案**
/// （避免把内部策略细节喂给模型；审计用 decision 的粗粒度值）。
enum AgentDenyReason {
  /// 条目"永久拒绝"（I-9 硬闸）。
  entryClosed,

  /// 条目类型不对智能体暴露（H5：identity / SSH 等）。
  typeNotExposed,

  pairingRevoked,
  pairingExpired,
  keyRejected,

  /// 智能体会话域已锁。
  sessionLocked,

  /// 不在配对设定的范围内。
  outOfScope,

  /// 该配对不允许这类操作。
  opNotAllowed,

  /// 方式 1：这次调用没拿到用户同意。
  notApproved,

  /// 方式 2：配对未被用户认证为可信。
  notTrusted,
}

/// 判定结果。
class AgentAccessResult {
  const AgentAccessResult.allow({this.standing = false})
      : allowed = true,
        reason = null;

  const AgentAccessResult.deny(AgentDenyReason this.reason)
      : allowed = false,
        standing = false;

  final bool allowed;

  /// `true` = 靠"本会话内允许读取"放行（审计要记 `allowed_standing`）。
  final bool standing;

  final AgentDenyReason? reason;

  @override
  String toString() => allowed
      ? 'allow${standing ? '(standing)' : ''}'
      : 'deny(${reason!.name})';
}

/// 判定输入 —— 由调用方把所有事实算好，策略本身不查库、不看会话。
class AgentAccessRequest {
  const AgentAccessRequest({
    required this.op,
    required this.entryOpen,
    required this.typeExposed,
    this.revoked = false,
    this.expired = false,
    this.keyMatches = true,
    required this.sessionUnlocked,
    this.inScope = true,
    this.opAllowed = true,
    required this.mode,
    this.trusted = false,
    this.approvedThisCall = false,
    this.standingRead = false,
  });

  final AgentOp op;

  /// 条目开关是否"开放"（`EntryPayload.agentOpen`）。
  final bool entryOpen;

  /// 条目类型是否对智能体暴露（只有 login / secure_note 为 true）。
  ///
  /// 单靠"开关"挡不住历史数据、导入文件与类型切换：一条被置成 open 的
  /// SSH 条目仍然能通过 entryOpen。类型闸是第二道硬闸，**排在 entryOpen
  /// 之后**（永久拒绝优先报 `entryClosed`）。
  final bool typeExposed;

  final bool revoked;
  final bool expired;
  final bool keyMatches;
  final bool sessionUnlocked;
  final bool inScope;
  final bool opAllowed;
  final AgentMode mode;
  final bool trusted;

  /// 方式 1：本次调用是否已拿到用户「同意」。
  final bool approvedThisCall;

  /// 方式 1：本会话是否已勾选「本会话内允许读取」。
  final bool standingRead;
}

/// 判定器。
class AgentAccessPolicy {
  AgentAccessPolicy._();

  /// 按上面的顺序判定。
  ///
  /// 顺序不能随意调整：条目开关先于类型，类型先于配对状态，配对状态先于
  /// 方式，保证"被永久拒绝的条目"和"类型不该暴露的条目"在任何情况下都拿不到允许。
  static AgentAccessResult evaluate(AgentAccessRequest r) {
    // 1. 条目开关是硬闸（I-9）：先于一切，包括"可信直通"。
    if (!r.entryOpen) return const AgentAccessResult.deny(AgentDenyReason.entryClosed);

    // 2. 类型硬闸（H5）：identity / SSH 永不对智能体暴露。排在 entryOpen 之后，
    //    所以"永久拒绝的 SSH 条目"仍报 entryClosed（用户看到的拒绝原因以开关为准）。
    if (!r.typeExposed) {
      return const AgentAccessResult.deny(AgentDenyReason.typeNotExposed);
    }

    // 3–5. 配对身份。
    if (r.revoked) {
      return const AgentAccessResult.deny(AgentDenyReason.pairingRevoked);
    }
    if (r.expired) {
      return const AgentAccessResult.deny(AgentDenyReason.pairingExpired);
    }
    if (!r.keyMatches) {
      return const AgentAccessResult.deny(AgentDenyReason.keyRejected);
    }

    // 6. 会话必须已解锁（fail closed）。
    if (!r.sessionUnlocked) {
      return const AgentAccessResult.deny(AgentDenyReason.sessionLocked);
    }

    // 7–8. 范围与操作类型。
    if (!r.inScope) {
      return const AgentAccessResult.deny(AgentDenyReason.outOfScope);
    }
    if (!r.opAllowed) {
      return const AgentAccessResult.deny(AgentDenyReason.opNotAllowed);
    }

    // 9. 方式 2：可信直通。
    if (r.mode == AgentMode.trusted) {
      if (!r.trusted) {
        return const AgentAccessResult.deny(AgentDenyReason.notTrusted);
      }
      return const AgentAccessResult.allow();
    }

    // 10. 方式 1：逐次审批。
    //    「本会话内允许读取」**只对普通读生效**：敏感读（明文/验证码）
    //    与写、删一律仍要本次同意 —— 否则它就是个绕过审批的后门。
    if (r.op == AgentOp.read && r.standingRead) {
      return const AgentAccessResult.allow(standing: true);
    }
    if (r.approvedThisCall) {
      return const AgentAccessResult.allow();
    }
    return const AgentAccessResult.deny(AgentDenyReason.notApproved);
  }

  /// 审批前预检：只判定**与"用户点不点同意"无关**的硬条件。
  ///
  /// 返回 null 表示"值得弹审批"；非 null 表示调用方应直接拒绝、**不要弹窗**。
  ///
  /// 为什么需要它：`evaluate` 的步骤里"是否已获本次同意"在最后；如果对一条
  /// 「永久拒绝」的条目先弹审批，用户点了同意之后才被告知"未开放"，等于让
  /// 智能体诱导无意义弹窗 —— 审批疲劳正是社会工程学的入口。
  ///
  /// 纪律：**不替代** `evaluate`。审批期间用户可能改条目开关 / 配对，
  /// `_gate` 之后仍要再走一次 `evaluate`（纵深防御）。
  static AgentDenyReason? precheck(AgentAccessRequest r) {
    if (!r.entryOpen) return AgentDenyReason.entryClosed;
    if (!r.typeExposed) return AgentDenyReason.typeNotExposed;
    if (r.revoked) return AgentDenyReason.pairingRevoked;
    if (r.expired) return AgentDenyReason.pairingExpired;
    if (!r.keyMatches) return AgentDenyReason.keyRejected;
    if (!r.sessionUnlocked) return AgentDenyReason.sessionLocked;
    if (!r.inScope) return AgentDenyReason.outOfScope;
    if (!r.opAllowed) return AgentDenyReason.opNotAllowed;
    return null;
  }
}
