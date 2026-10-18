/// 协议层的**线格式编解码**。
///
/// 两套条目 JSON，用途不同、**不要混用**：
/// - [entryToBridgeJson]：浏览器扩展用的受限形状（协议 v3 起冻结，只有
///   `hasTotp`、没有 TOTP 种子 / SSH 私钥），扩展与 C++ 桥都依赖它的字段名。
/// - [itemToJson] / [itemFromJson]：UI 客户端用的完整明文形状（= `VaultItem.toJson()`），
///   因为它要显示、编辑密码与 TOTP 种子。
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
