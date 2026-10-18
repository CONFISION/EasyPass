/// EasyPass 核心服务进程入口。
///
/// **不得**（间接）import 任何 Flutter 库：这个入口用 `dart build cli` 编成
/// 无 Flutter 的 AOT 可执行文件（`dart compile exe` 不可用 —— 依赖图里
/// `sqlite3` / `objective_c` 带 build hook）。
///
/// 模式：
/// - `--serve`（默认）：唯一的常驻核心，持有密码库与密钥；
/// - `--bridge`：native messaging 宿主（Linux 包装脚本用），转发浏览器 ↔ 核心；
/// - `--shutdown`：请求运行中的核心退出（唯一合法的停机通道）；
/// - `--status`：打印发现文件与核心状态（脚本 / CI 用）；
/// - `--version`：打印核心与协议版本。
///
/// 退出码：0 成功；1 失败；2 `--serve` 发现已有核心在跑。
library;

import 'dart:convert';
import 'dart:io';

import 'package:easypass/core/constants/app_constants.dart';
import 'package:easypass/core/platform/app_paths.dart';
import 'package:easypass/core_service/bridge_forwarder.dart';
import 'package:easypass/core_service/core_client.dart';
import 'package:easypass/core_service/core_info.dart';
import 'package:easypass/core_service/core_service.dart';
import 'package:easypass/protocol/protocol.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version') || args.contains('-v')) {
    stdout.writeln(
      'easypass_core ${AppConstants.coreVersion} '
      '(protocol $coreProtocolVersion)',
    );
    exit(0);
  }

  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    exit(0);
  }

  if (args.contains('--status')) {
    exit(await _status());
  }

  if (args.contains('--lock')) {
    // 托盘"仅退出 UI"、脚本都用它：只锁库，不停核心。
    // 没有核心在跑时 lockRunningCore() 返回 true（无事可做）⇒ 退 0，
    // 这样 CLI 在开发态不会误报失败，Linux 的 g_spawn_sync 也不会拿到非零。
    final locked = await lockRunningCore();
    stdout.writeln(locked ? 'vault locked' : 'could not lock the vault');
    exit(locked ? 0 : 1);
  }

  if (args.contains('--shutdown')) {
    final stopped = await shutdownRunningCore();
    stdout.writeln(stopped ? 'core stopped' : 'core did not stop in time');
    exit(stopped ? 0 : 1);
  }

  if (args.contains('--bridge') || args.contains('--native-host')) {
    exit(await runBridgeForwarder());
  }

  // 默认 = --serve
  try {
    final service = await CoreService.start();
    await service.stopped;
    exit(0);
  } on CoreAlreadyRunning catch (error) {
    stderr.writeln('easypass_core: $error');
    exit(2);
  } catch (error) {
    stderr.writeln('easypass_core: 启动失败：$error');
    exit(1);
  }
}

/// `--status`：running=true 时退 0，否则退 1（便于脚本判定）。
Future<int> _status() async {
  final info = await CoreDiscovery.read();
  final client = await CoreClient.connectToRunning(role: 'ui');
  if (client == null) {
    stdout.writeln(jsonEncode({
      'running': false,
      'info': info?.toJson(),
      'dataDirectory': AppPaths.dataDirectory.path,
    }));
    return 1;
  }
  try {
    final status = await client.request(Actions.getStatus);
    stdout.writeln(jsonEncode({
      'running': true,
      'info': info?.toJson(),
      'status': status,
    }));
    return 0;
  } finally {
    client.close();
  }
}

const String _usage = '''
EasyPass 核心服务

  easypass_core --serve        启动唯一常驻核心（默认）
  easypass_core --bridge       native messaging 宿主：转发浏览器 ↔ 核心
  easypass_core --lock         锁定保险库（核心继续运行）
  easypass_core --shutdown     请求运行中的核心退出
  easypass_core --status       打印核心状态（JSON；未运行退 1）
  easypass_core --version      打印核心与协议版本

核心常驻，不会空闲自退；只有 --shutdown / shutdownCore 动作才会退出。
''';
