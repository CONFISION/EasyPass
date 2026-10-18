import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// Resolves the filesystem locations used by EasyPass on **Windows**.
///
/// Layout: the database lives beside the executable, and the core's discovery
/// file (`daemon.json`) lives under `%LOCALAPPDATA%\EasyPass`.
///
/// The Linux port (XDG data directory, `0700`/`0600` permission tightening and
/// the executable-adjacent database migration) lives in the `linux` branch;
/// this branch does not contain it.
abstract final class AppPaths {
  AppPaths._();

  /// Directory containing the running executable.
  static Directory get executableDirectory =>
      Directory(p.dirname(Platform.resolvedExecutable));

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // 缓存解析结果。
  //
  // `dataDirectory` 会被高频调用（核心的每次空闲检查都会经过 `daemonInfoFile`
  // 取路径），所以解析一次后缓存：`resolvedExecutable` 与目录结构对单次进程
  // 是稳定的。`null` = 还没解析。
  //
  // 两条语义不变：
  //   - 同进程拿到同一个 `Directory` 实例（`identical(...)` 为 true）；
  //   - 测试可显式 `debugResetAppPathsCacheForTesting()` 重置 —— 见
  //     `test/app_paths_cache_test.dart`。
  static Directory? _cachedDataDirectory;

  /// User-writable application data directory.
  ///
  /// Memoized for the lifetime of the process. Tests may reset via
  /// [debugResetAppPathsCacheForTesting]; production callers do not need to
  /// release anything — a single `Directory` instance is reused.
  static Directory get dataDirectory {
    final cached = _cachedDataDirectory;
    if (cached != null) return cached;

    final resolved = _resolveDataDirectory();
    _cachedDataDirectory = resolved;
    return resolved;
  }

  static Directory _resolveDataDirectory() {
    // 数据目录 = 可执行文件目录（Windows）。
    //
    // 例外：核心服务被装到 `<app>\core\easypass_core.exe` 时，它的数据目录
    // 仍然是 `<app>`（= UI 二进制所在目录），否则同一个保险库会出现两个
    // 坐标。为什么核心要放子目录：`dart build cli` 的原生资产按
    // `<exe>\..\lib\sqlite3.dll` 解析，核心必须在子目录里、库放 `<app>\lib`，
    // 才能让一切留在安装目录内。
    //
    // 判据是"父目录里有 UI 二进制"，纯目录结构判断，不依赖任何环境变量。
    final exeDir = executableDirectory;
    final parent = exeDir.parent;
    if (File(p.join(parent.path, 'easypass.exe')).existsSync()) {
      return parent;
    }
    return exeDir;
  }

  /// 测试钩子。生产代码**绝不**调用。
  @visibleForTesting
  static void debugResetAppPathsCacheForTesting() {
    _cachedDataDirectory = null;
  }

  /// Main vault database path.
  static File get databaseFile =>
      File(p.join(dataDirectory.path, 'easypass.db'));

  /// Daemon registration / token file path.
  ///
  /// This is the core's discovery file: it carries the loopback port, the token
  /// and the core's version/pid. Do not normalize this with `p.join` — the
  /// Windows path shape and its fallback behavior are part of the existing
  /// bridge contract.
  static File get daemonInfoFile {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    return File('$localAppData\\EasyPass\\daemon.json');
  }

  /// 确保数据库文件可用（**Windows 上是 no-op**）。
  ///
  /// Linux 版本要在这一步建数据目录、把目录/库文件 chmod 到 700/600，并把
  /// exe 旁的旧库迁移到 XDG 目录 —— 那些逻辑随 `linux` 分支维护。
  /// Windows 的数据目录就是 exe 目录、访问控制由用户 profile 的 ACL 保证，
  /// 所以这里只返回路径（与 3.0.0 之前的行为完全一致）。
  static Future<File> prepareDatabaseFile() async => databaseFile;

  /// 收紧数据文件的权限（**Windows 上是 no-op**）。
  ///
  /// Linux 走 `chmod 600`；Windows 依赖 `%LOCALAPPDATA%` 的 ACL，无需处理。
  /// 签名保留是因为核心写 `daemon.json` 时会无条件调用它（见
  /// `lib/core_service/core_info.dart`）。
  static Future<void> makePrivate(File file) async {}
}
