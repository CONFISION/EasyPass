/// 协议 v4 的服务端推送事件与订阅主题。
///
/// 设计取舍：核心只推"变更通知 + 版本号"，客户端收到后**重取快照**。
/// 这样每条 UI 侧的 drift 流都能一对一映射到一个主题，不会出现
/// "漏推一处导致界面不更新"的幽灵 bug。
class Events {
  Events._();

  /// 数据变更（写入事务提交后广播）。
  static const String changed = 'changed';

  /// 某个会话域被锁定（空闲超时或显式锁定）。
  static const String sessionLocked = 'sessionLocked';

  /// 某个会话域解锁。
  static const String sessionUnlocked = 'sessionUnlocked';

  /// 核心即将退出（收到 shutdownCore 后广播）。
  static const String coreShuttingDown = 'coreShuttingDown';

  /// 智能体请求一次需要用户审批的操作（方式 1）。
  ///
  /// 载荷：`approvalId` / `nickname` / `tool` / `op`（读|写|删）/ `target`。
  /// UI 用 `respondAgentApproval` 动作回话。新增事件，不需要升协议版本。
  static const String agentApprovalRequested = 'agentApprovalRequested';
}

/// 订阅主题：与 UI 现在依赖的 4 条 drift 流一一对应。
class Topics {
  Topics._();

  /// 条目列表（含按文件夹 / 类型 / 收藏过滤的变化）。
  static const String items = 'items';

  /// 单条目内容变化（带 `id`）。
  static const String item = 'item';

  /// 文件夹列表变化。
  static const String folders = 'folders';

  /// 搜索结果的底层数据变化（带 `query`）。
  static const String search = 'search';

  static const Set<String> all = {items, item, folders, search};
}
