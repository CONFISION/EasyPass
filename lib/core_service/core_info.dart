import 'dart:convert';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/platform/app_paths.dart';
import 'package:easypass/protocol/protocol.dart';

/// `daemon.json` —— 核心服务的**发现文件**。
///
/// 位置由 `AppPaths.daemonInfoFile` 决定（Windows `%LOCALAPPDATA%\EasyPass\`，
/// Linux `$XDG_DATA_HOME/easypass/`），权限收紧到当前用户可读。
///
/// v4 相比 v3 新增两个字段：
/// - `coreVersion`：核心实现版本（客户端据此判定"要不要换掉这个核心"）；
/// - `exe`：核心可执行文件的绝对路径 —— 客户端要**安全地**结束旧核心时，
///   必须拿它和实际进程镜像比对，避免 pid 复用误杀无辜进程。
class CoreInfo {
  const CoreInfo({
    required this.port,
    required this.token,
    required this.pid,
    this.protocolVersion = coreProtocolVersion,
    this.coreVersion = AppConstants.coreVersion,
    this.exe = '',
    this.mcpPort,
  });

  final int port;
  final String token;
  final int pid;
  final int protocolVersion;
  final String coreVersion;
  final String exe;

  /// 智能体接口（MCP）的 HTTP 端口；null = 本核心没启用（或启动失败）。
  final int? mcpPort;

  Map<String, dynamic> toJson() => {
        AppConstants.daemonInfoPortKey: port,
        AppConstants.daemonInfoTokenKey: token,
        AppConstants.daemonInfoProtocolVersionKey: protocolVersion,
        AppConstants.daemonInfoPidKey: pid,
        'coreVersion': coreVersion,
        'exe': exe,
        if (mcpPort != null) AppConstants.daemonInfoMcpPortKey: mcpPort,
      };

  /// 宽容解析：缺 `port` / `token` / `pid` 一律返回 null（视为陈旧文件）。
  static CoreInfo? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final port = map[AppConstants.daemonInfoPortKey];
      final token = map[AppConstants.daemonInfoTokenKey];
      final pid = map[AppConstants.daemonInfoPidKey];
      if (port is! int || token is! String || pid is! int) return null;
      return CoreInfo(
        port: port,
        token: token,
        pid: pid,
        protocolVersion:
            (map[AppConstants.daemonInfoProtocolVersionKey] as num?)?.toInt() ??
                0,
        coreVersion: (map['coreVersion'] as String?) ?? '',
        exe: (map['exe'] as String?) ?? '',
        mcpPort: (map[AppConstants.daemonInfoMcpPortKey] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  /// 这条发现信息是否指向一个**过时的**核心（协议低于当前版本）。
  ///
  /// 升级场景：2.4.x 的 `easypass.exe --service` daemon 写的是协议 ≤4 的文件，
  /// 它不认识协议 5 的加密握手。客户端据此在连接前就把它判为陈旧并退休
  /// （见 `CoreSession._connect` 的说明：只删文件、不盲杀进程）。
  bool get isStale => protocolVersion < coreProtocolVersion;

  @override
  String toString() =>
      'CoreInfo(pid=$pid, port=$port, protocol=$protocolVersion, '
      'version=$coreVersion)';
}

/// 发现文件的读写与清理。
class CoreDiscovery {
  CoreDiscovery._();

  static File get infoFile => AppPaths.daemonInfoFile;

  static Future<CoreInfo?> read() async {
    try {
      final file = infoFile;
      if (!await file.exists()) return null;
      return CoreInfo.tryParse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(CoreInfo info) async {
    final file = infoFile;
    await file.writeAsString(jsonEncode(info.toJson()));
    await AppPaths.makePrivate(file);
  }

  /// 只删除**我们自己写的**那份（port + token 都对得上）。
  ///
  /// 防的是这个竞态：新核心已经接管并覆写了文件，旧核心退出时若无脑删除，
  /// 就会把可用核心的注册信息一起删掉。
  static Future<void> removeIfOurs(CoreInfo info) async {
    try {
      final file = infoFile;
      if (!await file.exists()) return;
      final current = CoreInfo.tryParse(await file.readAsString());
      if (current == null) return;
      if (current.port != info.port || current.token != info.token) return;
      await file.delete();
    } catch (_) {
      // 尽力而为：删不掉不影响退出（新核心启动时会覆写）。
    }
  }

  /// 无条件清掉（旧核心退休 / 接管时使用）。文件不存在时是空操作。
  static Future<void> removeAny() async {
    try {
      final file = infoFile;
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 同上。
    }
  }
}

