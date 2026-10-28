import 'dart:convert';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/platform/app_paths.dart';
import 'package:easypass/protocol/protocol.dart';
import 'package:meta/meta.dart' show visibleForTesting;

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

/// 发现文件**存在但不可用**（读不出来 / 内容不是合法注册信息）。
///
/// 为什么必须和"文件不存在"区分：文件不存在 = 没有核心在跑，调用方可以安全地
/// 拉起新核心；文件存在但坏掉 = 核心可能正在跑，只是我们读不到它的端口/令牌。
/// 此时若当成"没有核心"，`--lock` / `--shutdown` 会对用户谎报成功（fail-open），
/// UI 也可能再拉起一个核心并发写库。调用方必须按"核心状态未知"处理。
class CoreDiscoveryException implements Exception {
  CoreDiscoveryException(this.message, {this.path});

  final String message;
  final String? path;

  @override
  String toString() => 'CoreDiscoveryException: $message';
}

/// 发现文件的读写与清理。
class CoreDiscovery {
  CoreDiscovery._();

  static File? _infoFileOverride;

  /// 发现文件路径；生产固定为 [AppPaths.daemonInfoFile]。
  static File get infoFile => _infoFileOverride ?? AppPaths.daemonInfoFile;

  /// 测试钩子：把发现文件重定向到临时路径；传 null 恢复默认。
  @visibleForTesting
  static void debugSetInfoFileForTesting(File? file) {
    _infoFileOverride = file;
  }

  /// 读取发现文件。
  ///
  /// - 文件不存在 ⇒ 返回 null（没有核心在跑，调用方可以安全拉起）；
  /// - 存在但读取失败 / 内容不是合法注册信息 ⇒ 抛 [CoreDiscoveryException]
  ///   （核心状态未知，调用方必须 fail closed）。
  static Future<CoreInfo?> read() async {
    final file = infoFile;
    final String raw;
    try {
      raw = await file.readAsString();
    } on PathNotFoundException {
      return null;
    } catch (error) {
      throw CoreDiscoveryException(
        '发现文件存在但无法读取（${file.path}）：$error',
        path: file.path,
      );
    }
    final info = CoreInfo.tryParse(raw);
    if (info == null) {
      throw CoreDiscoveryException(
        '发现文件存在但内容不是有效的核心注册信息（可能已损坏）：${file.path}',
        path: file.path,
      );
    }
    return info;
  }

  /// 原子写入发现文件：同目录临时文件 + rename。
  ///
  /// 为什么必须原子：客户端随时可能在读这个文件；直接 `writeAsString` 会先截断
  /// 再写，读方可能读到半截 JSON。temp+rename 让读方要么看到旧内容、要么看到
  /// 新内容。Windows 上目标已存在时 rename 可能被拒（被短暂占用或文件系统
  /// 语义不同），退化成"先删旧文件再 rename"：中间有极短的"文件不存在"窗口，
  /// 但读方看到"不存在"只会按无核心处理（轮询/重连会恢复），比读到半截安全。
  static Future<void> write(CoreInfo info) async {
    final file = infoFile;
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(info.toJson()), flush: true);
      await AppPaths.makePrivate(tmp);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        try {
          await file.delete();
        } on PathNotFoundException {
          // 目标本来就不存在（另一进程刚删掉）：直接继续 rename。
        }
        await tmp.rename(file.path);
      }
    } catch (_) {
      // 失败时清掉临时文件，异常继续向上抛（由调用方决定是否致命）。
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // 清理尽力而为。
      }
      rethrow;
    }
    await AppPaths.makePrivate(file);
  }

  /// 只删除**我们自己写的**那份（port + token 都对得上）。
  ///
  /// 防的是这个竞态：新核心已经接管并覆写了文件，旧核心退出时若无脑删除，
  /// 就会把可用核心的注册信息一起删掉。内容坏掉时也**不删**（读不出就不动它，
  /// 由用户/上层决定怎么处理）。
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
