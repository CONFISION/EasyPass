import 'package:easypass/data/models/entry_type.dart';
import 'package:easypass/data/models/vault_item.dart';
import 'package:easypass/protocol/protocol.dart';

/// 会话状态快照（来自核心，UI 只读）。
class AuthSnapshot {
  const AuthSnapshot({
    required this.status,
    required this.autoLockMinutes,
    required this.hasAuthMaterial,
    this.remainingSeconds,
  });

  /// `firstRun` / `locked` / `unlocked`。
  final String status;
  final int autoLockMinutes;

  /// 核心里是否已有校验材料。false 且旧钥匙串有材料 ⇒ 需要迁移。
  final bool hasAuthMaterial;
  final int? remainingSeconds;

  bool get isFirstRun => status == 'firstRun';
  bool get isUnlocked => status == 'unlocked';
  bool get isLocked => status == 'locked';
}

/// UI 的数据通道。
///
/// **UI 不再直接访问数据库**：所有读写都经这个接口落到核心服务。
/// 抽象出接口有两个用处：M4 完成前可以并行保留旧的内嵌实现；测试可以注入
/// 假实现（不必起真核心）。
abstract class VaultApi {
  // ─── 会话 / 认证 ────────────────────────────────────────

  Future<AuthSnapshot> authSnapshot();

  /// 解锁 UI 域。失败抛 [VaultApiException]。
  Future<void> unlock(String password);

  /// 锁定（UI 域；核心会顺带锁 bridge 域）。
  Future<void> lock();

  Future<void> setMasterPassword(String password, String confirmPassword);

  /// 原子轮换主密码（校验 + 整库重加密 + 写新校验材料都在核心内完成）。
  ///
  /// 返回 [ChangePasswordResult]：核心会告诉调用方**新的校验材料是否真的落盘**
  /// （`keyMaterialPersisted`）。写失败时轮换仍然有效（库里的轮换日志是权威），
  /// 但界面必须提示用户 —— 丢掉这个字段就等于把那条提示变成不可达代码。
  Future<ChangePasswordResult> changeMasterPassword({
    required String currentPassword,
    required String newPassword,
    required String confirmPassword,
  });

  /// 查看机密前的二次校验；返回 false 表示密码不对（不抛异常）。
  Future<bool> verifyMasterPassword(String password);

  /// 迁移期：把旧钥匙串里的校验材料交给核心（只接受一次）。
  Future<void> adoptLegacyKeyMaterial({
    required String salt,
    required String passwordHash,
  });

  Future<void> setAutoLockMinutes(int minutes);

  /// 上报用户活动（续期空闲计时器）。核心没起来时静默失败即可。
  Future<void> touchActivity();

  /// 核心的**会话事件**：`locked` / `unlocked` / `shuttingDown`。
  ///
  /// 为什么必须有：空闲锁定的权威在核心，核心自锁后会广播 `sessionLocked`；
  /// 客户端不订阅的话，UI 会停在"看起来还能用"的界面，直到某个动作回
  /// `locked` 才暴露 —— 那是客户端化最容易漏掉的一致性缺口。
  Stream<String> get sessionEvents;

  // ─── 读 ────────────────────────────────────────────────

  Future<List<VaultItem>> listItems({
    String? folderId,
    EntryType? type,
    bool favoritesOnly = false,
  });

  Future<VaultItem?> getItem(String id);

  Future<List<WireFolder>> listFolders();

  Future<List<VaultItem>> searchItems(String query);

  Future<int> countItemsInFolder(String folderId);

  /// 健康报告（核心算好；字段见 `CoreActions._getHealthReport`）。
  Future<Map<String, dynamic>> healthReport();

  /// 动态验证码（TOTP 种子不出核心）。
  Future<Map<String, dynamic>> getTotp(String entryId);

  // ─── 写 ────────────────────────────────────────────────

  Future<String> saveItem(VaultItem item);

  Future<void> deleteItem(String id);

  Future<String> addFolder(String name, {String icon = 'folder'});

  Future<void> updateFolder(String id, {String? name, String? icon});

  Future<void> removeFolder(String id);

  Future<void> deleteAllData();

  // ─── 导出 / 导入（核心直接读写文件）─────────────────────

  Future<void> exportVault(String format, String path);

  Future<Map<String, dynamic>> importVault(String format, String path);

  // ─── 智能体访问（3.1.0）─────────────────────────────────

  /// 智能体域是否已解锁。
  Future<bool> agentDomainUnlocked();

  /// 配对列表（**不含密钥哈希**）。
  Future<List<Map<String, dynamic>>> listAgentPairings();

  /// 创建配对：返回的 `key` **只出现这一次**，之后库里只有哈希。
  Future<Map<String, dynamic>> createAgentPairing({
    required String nickname,
    required String mode,
  });

  Future<void> revokeAgentPairing(String id);

  /// 切换访问方式；`mode == 'trusted'` 时必须给 [password]（核心二次校验）。
  Future<void> setAgentAccessMode({
    required String id,
    required String mode,
    String? password,
  });

  /// 用主密码解锁智能体域（显式用户动作）。
  Future<void> unlockAgentDomain(String password);

  Future<void> lockAgentDomain();

  // ─── 变更通知 ──────────────────────────────────────────

  /// 主题流（`items` / `item` / `folders` / `search`）。
  ///
  /// UI 的流式 provider 用它实现"写库即刷新"：收到主题 → 重取快照。
  Stream<String> get changes;
}

/// UI 侧统一的错误类型（把协议错误码带出来）。
class VaultApiException implements Exception {
  VaultApiException(this.code, this.message);

  final String code;
  final String message;

  bool get isLocked => code == ErrorCodes.locked;

  bool get needsKeyMigration => code == ErrorCodes.needsKeyMigration;

  @override
  String toString() => message;
}
/// `changeMasterPassword` 的结果。
class ChangePasswordResult {
  const ChangePasswordResult({
    required this.keyMaterialPersisted,
    required this.reencrypted,
  });

  /// 新的 salt / 校验哈希是否真的写进了库文件（`vault_meta`）。
  ///
  /// false 不是"改密失败"：轮换日志仍在，下次解锁会自动收敛；但用户需要知道
  /// "这次写入没有落盘"，所以我们把提示显示出来而不是假装一切正常。
  final bool keyMaterialPersisted;

  /// 本次重新加密的条目数（0 表示空库，正常）。
  final int reencrypted;
}
