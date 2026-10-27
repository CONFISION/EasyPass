// 命名参数用可读的公开名映射到私有字段（与 core_actions.dart 同款）。
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:easypass/core/platform/app_paths.dart';
import 'package:easypass/core/platform/dpapi.dart';
import 'package:easypass/data/database/database.dart';

/// 智能体访问（总开关 + 专属密钥 + 包裹后的 vaultKey）的落盘。
///
/// 三处存储、互相缺一不可：
/// 1. `vault_meta.agent.enabled` —— 总开关状态（关掉 = 停 MCP 服务）；
/// 2. `vault_meta.agent.wrap`   —— 被专属密钥包裹的 vaultKey；
/// 3. `agent.key.dpapi` 文件    —— DPAPI 保护下的专属密钥本体。
///
/// **只拿到库文件**（备份/同步盘）解不开保险库；**只拿到 DPAPI blob** 也没有
/// 库里的 wrapped key。两者同时泄露且在同一台机器、同一用户下才等于失守 ——
/// 那时真正的边界已经是"同一用户账户"（见 SECURITY.md）。
class AgentAccessException implements Exception {
  AgentAccessException(this.message);

  final String message;

  @override
  String toString() => 'AgentAccessException: $message';
}

class AgentAccessStore {
  AgentAccessStore(this._db, {File? blobFile}) : _blobFile = blobFile;

  /// 总开关：`'1'` = 开。
  static const String enabledKey = 'agent.enabled';

  /// 被专属密钥包裹后的 vaultKey（base64，见 `AgentKeyMaterial`）。
  static const String wrapKey = 'agent.wrap';

  /// DPAPI 的固定 entropy：不认识的工具解不开这些 blob。
  static final Uint8List entropy =
      Uint8List.fromList(utf8.encode('easypass-agent-key-v1'));

  final AppDatabase _db;
  final File? _blobFile;

  File get blobFile => _blobFile ?? AppPaths.agentKeyBlobFile;

  Future<bool> isEnabled() async => (await _db.getMeta(enabledKey)) == '1';

  Future<void> setEnabled(bool enabled) =>
      _db.setMeta(enabledKey, enabled ? '1' : '0');

  Future<String?> readWrap() => _db.getMeta(wrapKey);

  Future<void> writeWrap(String blob) => _db.setMeta(wrapKey, blob);

  Future<void> clearWrap() => _db.deleteMeta(wrapKey);

  /// 把专属密钥用 DPAPI 落到本机（仅当前 Windows 用户可解）。
  Future<void> storeAgentKey(Uint8List agentKey) async {
    if (!Dpapi.isSupported) {
      throw AgentAccessException('本平台不支持 DPAPI，智能体访问不可用');
    }
    final blob = Dpapi.protect(agentKey, entropy: entropy);
    final file = blobFile;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(blob, flush: true);
    await AppPaths.makePrivate(file);
  }

  /// 读出专属密钥；文件缺失 / DPAPI 解不开（换了用户或机器）/ 损坏 ⇒ 返回 null。
  ///
  /// **不抛异常、也不回退**：调用方拿到 null 就必须 fail closed（保持锁定、
  /// 不启动 MCP 服务）。
  Future<Uint8List?> loadAgentKey() async {
    if (!Dpapi.isSupported) return null;
    final file = blobFile;
    if (!await file.exists()) return null;
    try {
      final blob = await file.readAsBytes();
      return Dpapi.unprotect(blob, entropy: entropy);
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteAgentKey() async {
    final file = blobFile;
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {
        // 删不掉不阻塞关闭：wrap 已经清掉，blob 单独存在也没用。
      }
    }
  }

  /// 关闭总开关：三处一起清（先清库里的 wrap，再删 blob）。
  Future<void> wipe() async {
    await setEnabled(false);
    await clearWrap();
    await deleteAgentKey();
  }
}
