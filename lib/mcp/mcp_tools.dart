import 'package:easypass/protocol/protocol.dart';

/// 智能体工具清单（**静态、版本化**）。
///
/// 为什么必须静态：
/// - MCP 规范承认"工具投毒 / rug pull"无法从协议层证明，缓解办法就是把工具定义
///   钉死；动态注册或改描述 = 给客户端审批层开枪的机会；
/// - 客户端会用 `readOnlyHint` / `destructiveHint` 决定审批行为，写错等于误导它。
///
/// 命名纪律：全部使用 snake_case，且**不复用** bridge 域的 camelCase 动作名
/// （`getAllCredentials` 之类），避免"看起来是同一个东西"的错觉（见
/// `test/role_whitelist_test.dart` 对 agent 动作名的约束）。
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    this.readOnly = true,
    this.destructive = false,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final bool readOnly;
  final bool destructive;

  Map<String, Object?> toJson() => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'annotations': {
          'readOnlyHint': readOnly,
          'destructiveHint': destructive,
        },
      };
}

/// 3.1.0 的工具面：**读 + 写/删（走回收站）+ 敏感读**。
///
/// 写操作的形状刻意保持"窄"：
/// - `create_entry` 只开放 login / secure_note（identity / ssh_key 字段太多，
///   用 UI 建更不容易出错）；新建条目**默认对智能体永久拒绝**，需用户在 UI 打开；
/// - `delete_entry` 只做软删（进回收站），**永远不能彻底删除** —— 彻底删除是
///   用户独占的决定，不在工具面里；
/// - 所有返回值都不含秘密（密码/验证码/私钥只在剪贴板里落地）。
const List<McpTool> agentTools = <McpTool>[
  McpTool(
    name: 'status',
    description:
        '查看当前配对状态：保险库是否已解锁、可见条目数、访问方式、活动窗口。',
    inputSchema: {'type': 'object', 'properties': {}, 'additionalProperties': false},
  ),
  McpTool(
    name: 'begin_session',
    description:
        '为批量操作开一个显式窗口（purpose 必填，写入审计）。窗口内不会被空闲锁定打断。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'purpose': {'type': 'string', 'description': '一句话说明这次要做什么'},
        'ttlSeconds': {
          'type': 'integer',
          'minimum': 30,
          'maximum': 1800,
          'description': '窗口时长，默认 300 秒，上限 1800 秒',
        },
      },
      'required': ['purpose'],
      'additionalProperties': false,
    },
  ),
  McpTool(
    name: 'end_session',
    description: '结束窗口，并**立即锁定智能体会话域**。',
    inputSchema: {'type': 'object', 'properties': {}, 'additionalProperties': false},
  ),
  McpTool(
    name: 'list_entries',
    description:
        '列出对智能体开放的条目**元数据**（不含密码、备注、TOTP 种子、私钥、自定义字段值）。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'type': {'type': 'string', 'enum': ['login', 'secure_note', 'identity', 'ssh_key']},
        'folder': {'type': 'string', 'description': '文件夹 id'},
        'query': {'type': 'string', 'description': '自由词搜索'},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 200},
        'cursor': {'type': 'string'},
      },
      'additionalProperties': false,
    },
  ),
  McpTool(
    name: 'get_entry',
    description: '取单条目的元数据（同样不含任何秘密）。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
  ),
  McpTool(
    name: 'create_entry',
    description:
        '新建条目（只支持 login / secure_note）。'
        'secure_note 没有 url / username / password 字段，传了会 invalidRequest。'
        'password 可传字符串，或 {"generate": true} 让核心生成并直接加密入库 —— 明文不会返回。'
        '**新建条目默认对智能体开放**（用户可随时在 EasyPass 里改成「永久拒绝」收回）。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'type': {
          'type': 'string',
          'enum': ['login', 'secure_note'],
          'description': '默认 login',
        },
        'name': {'type': 'string'},
        'folder': {'type': 'string', 'description': '文件夹 id（可空）'},
        'url': {'type': 'string'},
        'username': {'type': 'string'},
        'password': {
          'description': '字符串，或 {"generate": true, "length"?: int, '
              '"useSymbols"?: bool} 让核心生成（明文不回传）',
        },
        'notes': {'type': 'string'},
        'customFields': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'label': {'type': 'string'},
              'value': {'type': 'string'},
              'type': {
                'type': 'string',
                'enum': ['text', 'hidden', 'boolean'],
              },
            },
            'required': ['label'],
            'additionalProperties': false,
          },
        },
      },
      'required': ['name'],
      'additionalProperties': false,
    },
    readOnly: false,
  ),
  McpTool(
    name: 'update_entry',
    description:
        '局部更新条目（没传的字段不动）。只支持 login / secure_note 的字段；'
        'identity / ssh_key 的字段请在 EasyPass 界面里修改。'
        '审批弹窗只会列出**字段名**，不会显示密码等值。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'name': {'type': 'string'},
        'notes': {'type': 'string'},
        'folder': {
          'description': '文件夹 id；传 null 或空串表示移出文件夹',
        },
        'url': {'type': 'string'},
        'username': {'type': 'string'},
        'password': {
          'description': '字符串，或 {"generate": true} 让核心生成',
        },
        'isFavorite': {'type': 'boolean'},
        'customFields': {
          'type': 'array',
          'items': {'type': 'object'},
        },
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    readOnly: false,
  ),
  McpTool(
    name: 'delete_entry',
    description:
        '把条目移到**回收站**（软删除，可由用户恢复）。'
        '智能体**不能**彻底删除条目 —— 清空回收站/永久删除只由用户在 EasyPass 里操作。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    readOnly: false,
    destructive: true,
  ),
  McpTool(
    name: 'list_trash',
    description:
        '列出回收站里**对智能体开放**的条目元数据（带删除时间）。'
        '只能看到"开放"的条目；用户的「永久拒绝」是硬闸。',
    inputSchema: {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
  ),
  McpTool(
    name: 'restore_entry',
    description: '把回收站里的条目恢复出来（写操作，逐次审批）。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    readOnly: false,
  ),
  McpTool(
    name: 'copy_to_clipboard',
    description:
        '把某个字段的值写进系统剪贴板，**只返回是否成功、不返回明文**。'
        '智能体据此去目标窗口粘贴即可 —— 密码永远不会进入模型上下文。',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'field': {
          'type': 'string',
          'enum': [
            'password',
            'totp',
            'notes',
            'private_key',
            'passphrase',
            'custom',
          ],
          'description': '要复制的字段，默认 password',
        },
        'customLabel': {
          'type': 'string',
          'description': '自定义字段的标签（field=custom 时必填）',
        },
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    // 不是只读：它改变了本机剪贴板（其它程序可能读到）。
    readOnly: false,
  ),
];

/// 工具名集合（`tools/call` 的白名单判定用）。
final Set<String> agentToolNames = {
  for (final tool in agentTools) tool.name,
};

/// 当前智能体工具面的版本。工具定义变化时必须递增（审计与排查要用）。
///
/// 1 → 2（3.1.0 阶段 2）：新增 create / update / delete / list_trash / restore，
/// `status.entryCount` 的语义也从"此刻可读条数"改成"开放条数"。
const String agentToolSurfaceVersion = '2';

/// 引用了协议层的错误码，避免 MCP 层另造一套字符串。
class McpErrorCodes {
  McpErrorCodes._();

  static const int parseError = -32700;
  static const int invalidRequest = -32600;
  static const int methodNotFound = -32601;
  static const int invalidParams = -32602;
  static const int internalError = -32603;

  /// 复用协议 5 的错误码（错误响应里同时给出，便于客户端统一处理）。
  static const String locked = ErrorCodes.locked;
  static const String unauthorized = ErrorCodes.unauthorized;
}
