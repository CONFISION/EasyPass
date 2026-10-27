/// 协议层的**线格式编解码**。
///
/// **三套**条目 JSON，用途不同、**不要混用**：
/// - [entryToBridgeJson]：浏览器扩展用的受限形状（协议 v3 起冻结，只有
///   `hasTotp`、没有 TOTP 种子 / SSH 私钥），扩展与 C++ 桥都依赖它的字段名。
/// - [itemToJson] / [itemFromJson]：UI 客户端用的完整明文形状（= `VaultItem.toJson()`），
///   因为它要显示、编辑密码与 TOTP 种子。
/// - [entryToAgentJson]：智能体视角，**只有元数据、没有任何秘密**（见该函数的说明）。
library;

import 'package:easypass/data/models/vault_item.dart';

import 'entry_type_wire.dart';

/// 浏览器扩展视角的条目 JSON（**形状冻结**，见原有 `_entryToJson`）。
Map<String, dynamic> entryToBridgeJson(VaultItem item) {
  final login = item.loginOrEmpty;
  return {
    'id': item.id,
    'type': item.type.wireName,
    'name': item.name,
    'url': login.url,
    'username': item.type == WireEntryType.identity
        ? item.identityOrEmpty.username
        : login.username,
    'password': login.password,
    'notes': item.notes,
    'hasTotp': item.isLogin && login.hasTotp,
    'isFavorite': item.isFavorite,
    'identity': item.identity?.toJson(),
    'sshKey': item.sshKey?.toJson(),
    'customFields': [
      for (final field in item.customFields) field.toJson(),
    ],
  };
}

/// UI 客户端视角的条目 JSON（完整明文）。
Map<String, dynamic> itemToJson(VaultItem item) => item.toJson();

/// **智能体视角**的条目元数据：**没有任何秘密**。
///
/// 为什么必须另起一份而不是复用上面两套：
/// - [entryToBridgeJson] 带 `password`（扩展要填充）；
/// - [itemToJson] 是完整明文（UI 要显示 / 编辑）。
/// 智能体是可被提示注入驱动的调用者，任何一次"顺手返回明文"都等于把秘密送进
/// 模型上下文 —— 用远程模型时就等于离开本机。所以这里**只给**：
/// id / name / type / folder / url / username / hasPassword / hasTotp /
/// isFavorite / updatedAt。
///
/// **明确不给**：notes（可能是安全笔记正文）、password、TOTP 种子、SSH 私钥与
/// 口令、自定义字段的**值**（连值也算秘密，只给"有几个字段"这种判断不需要的信息
/// 也一律不给）。
///
/// [folderName] 由调用方传文件夹名做展示；缺省回退到 `folderId`。
/// [deletedAt] 只在"回收站视图"（`list_trash`）里传：等于告诉智能体
/// "这条现在在回收站"，普通 `list_entries` / `get_entry` 永远拿不到回收站条目。
Map<String, dynamic> entryToAgentJson(
  VaultItem item, {
  String? folderName,
  int? deletedAt,
}) {
  final login = item.loginOrEmpty;
  return {
    'id': item.id,
    'name': item.name,
    'type': item.type.wireName,
    'folder': folderName ?? item.folderId,
    'url': item.isLogin ? login.url : '',
    'username': item.type == WireEntryType.identity
        ? item.identityOrEmpty.username
        : login.username,
    // 布尔代替值：智能体需要"有没有密码 / 有没有验证码"来做决策，不需要值本身。
    'hasPassword': item.isLogin && login.password.isNotEmpty,
    'hasTotp': item.isLogin && login.hasTotp,
    'isFavorite': item.isFavorite,
    'updatedAt': item.updatedAt,
    'deletedAt': ?deletedAt,
  };
}

/// 从 UI 客户端发来的条目 JSON 还原模型（宽容解析，不抛异常）。
VaultItem itemFromJson(Map<String, dynamic> json) => VaultItem.fromJson(json);

/// 文件夹的线格式模型。
///
/// 刻意**不复用 drift 的 `Folder` 行类**：协议层不该把数据库依赖带进客户端。
class WireFolder {
  final String id;
  final String name;
  final String icon;
  final int createdAt;
  final int updatedAt;

  const WireFolder({
    required this.id,
    required this.name,
    this.icon = 'folder',
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'icon': icon,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory WireFolder.fromJson(Map<String, dynamic> json) => WireFolder(
        id: (json['id'] ?? '') as String,
        name: (json['name'] ?? '') as String,
        icon: (json['icon'] ?? 'folder') as String,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      );
}
