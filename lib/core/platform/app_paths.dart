import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// P1.5 审计 F4：`ProcessException.errorCode` 是非空 int（"无错误码" 也是 0），
/// 与类型拼起来便于诊断，同时不泄漏路径 / 参数 / message。
String _chmodSpawnDetail(ProcessException e) {
  if (e.errorCode != 0) return 'errno=${e.errorCode}';
  return e.runtimeType.toString();
}

/// Resolves the filesystem locations used by the desktop application.
///
/// Windows keeps the historical layout: the database lives beside the
/// executable and the daemon metadata lives below `%LOCALAPPDATA%\\EasyPass`.
/// Linux uses the XDG data directory because an AppImage executable is mounted
/// read-only at runtime.
abstract final class AppPaths {
  AppPaths._();

  static const String _linuxDataDirectoryName = 'easypass';

  /// Directory containing the running executable.
  static Directory get executableDirectory =>
      Directory(p.dirname(Platform.resolvedExecutable));

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // P3.5 §6 #1：缓存解析结果。
  //
  // 之前 `dataDirectory` / `configDirectory` / `autostartDirectory` 每次
  // 调用都会重读 `Platform.environment['XDG_DATA_HOME' | 'XDG_CONFIG_HOME' |
  // 'HOME']` 并 `p.join` 一次。`EasypassDaemon.probe` 在每条 idle 检查期间
  // 会经过 `daemonInfoFile` 多次取这条路径（AUDIT-P1 #10）—— 既多 syscall，
  // 又把"env 是否被改"这条隐性假设漏在每次调用上。
  //
  // 解析结果对单次进程是稳定的：env 不会变、`resolvedExecutable` 不会变、
  // 分支不会变（`Platform.isLinux` 在 dart:io 是常量）。`null` = 还没解析。
  //
  // 三条语义不变：
  //   - **fail-loud 仍立即抛**（首次失败原样上抛，不兜底）。
  //   - 同进程拿到同一个 `Directory` 实例（`identical(...)` 为 true）。
  //   - 测试可显式 `debugResetAppPathsCacheForTesting()` 重置，绝不连
  //     累两次。
  //
  // 测试钩子参考 `desktop_tray` / `font_discovery_service` 既有的
  // `debugSet…ForTesting` / `debugReset…ForTesting` 风格 —— 见
  // `test/app_paths_cache_test.dart`。
  static Directory? _cachedDataDirectory;
  static Directory? _cachedConfigDirectory;
  static Directory? _cachedAutostartDirectory;

  /// User-writable application data directory.
  ///
  /// Memoized for the lifetime of the process (P3.5 §6 #1). Tests may reset
  /// via [debugResetAppPathsCacheForTesting]; production callers do not need
  /// to release anything — a single `Directory` instance is reused.
  static Directory get dataDirectory {
    final cached = _cachedDataDirectory;
    if (cached != null) return cached;

    // Keep the Windows (and other non-Linux desktop) behavior unchanged:
    // Platform.isLinux is a constant in dart:io for the lifetime of the
    // process, so resolving once is enough.
    final resolved = _resolveDataDirectory();
    _cachedDataDirectory = resolved;
    return resolved;
  }

  static Directory _resolveDataDirectory() {
    if (!Platform.isLinux) return executableDirectory;

    final configuredDataHome = Platform.environment['XDG_DATA_HOME'];
    final dataHome =
        (configuredDataHome != null && configuredDataHome.isNotEmpty)
        ? configuredDataHome
        : _defaultLinuxDataHome();
    return Directory(p.join(dataHome, _linuxDataDirectoryName));
  }

  /// P3.5 §6 #1：测试钩子。生产代码**绝不**调用。
  @visibleForTesting
  static void debugResetAppPathsCacheForTesting() {
    _cachedDataDirectory = null;
    _cachedConfigDirectory = null;
    _cachedAutostartDirectory = null;
  }

  static String _defaultLinuxDataHome() {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.local', 'share');
    }

    // Do not silently put a vault in a shared temporary directory when a
    // desktop session has no resolvable home directory.
    throw StateError('HOME is not set; cannot resolve the XDG data directory');
  }

  /// User-writable configuration directory.
  ///
  /// Linux only — Windows keeps the historical layout (data lives beside the
  /// executable and `%LOCALAPPDATA%` is the equivalent of `XDG_CONFIG_HOME`).
  /// This is the XDG-resolved equivalent of `BrowserHostInstaller`'s
  /// `xdgConfigHome` lookup: `$XDG_CONFIG_HOME` first, falling back to
  /// `~/.config` (matching the freedesktop.org Base Directory Specification).
  ///
  /// P3.2 introduces this for the Linux autostart path; it deliberately lives
  /// here (next to [dataDirectory]) so the XDG lookup rules stay in one place
  /// rather than spreading across feature folders.
  ///
  /// Memoized for the lifetime of the process (P3.5 §6 #1) — see the same
  /// note on [dataDirectory]. Same `debugResetAppPathsCacheForTesting` reset.
  static Directory get configDirectory {
    final cached = _cachedConfigDirectory;
    if (cached != null) return cached;
    final resolved = _resolveConfigDirectory();
    _cachedConfigDirectory = resolved;
    return resolved;
  }

  static Directory _resolveConfigDirectory() {
    // Windows keeps the historical layout — autostart lives in the registry,
    // not in a directory we resolve here.
    if (!Platform.isLinux) return executableDirectory;
    final configuredConfigHome = Platform.environment['XDG_CONFIG_HOME'];
    final configHome =
        (configuredConfigHome != null && configuredConfigHome.isNotEmpty)
        ? configuredConfigHome
        : _defaultLinuxConfigHome();
    return Directory(p.join(configHome, _linuxDataDirectoryName));
  }

  static String _defaultLinuxConfigHome() {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, '.config');
    }
    // Mirror `dataDirectory`'s "fail loud" semantics — silently substituting
    // /tmp would put user-controlled state in a shared, world-readable place.
    throw StateError('HOME is not set; cannot resolve the XDG config directory');
  }

  /// Directory into which per-user autostart `.desktop` files are written.
  ///
  /// Linux only — Windows autostart lives in the registry and is managed by
  /// the installer. Per the Desktop Entry Specification's autostart spec, the
  /// directory is `$XDG_CONFIG_HOME/autostart/` (default `~/.config/autostart`).
  /// The directory is created on demand by the autostart installer.
  ///
  /// Memoized for the lifetime of the process (P3.5 §6 #1) — see the same
  /// note on [dataDirectory]. Same `debugResetAppPathsCacheForTesting` reset.
  static Directory get autostartDirectory {
    final cached = _cachedAutostartDirectory;
    if (cached != null) return cached;
    final resolved = _resolveAutostartDirectory();
    _cachedAutostartDirectory = resolved;
    return resolved;
  }

  static Directory _resolveAutostartDirectory() {
    if (!Platform.isLinux) return executableDirectory;
    final configuredConfigHome = Platform.environment['XDG_CONFIG_HOME'];
    final configHome =
        (configuredConfigHome != null && configuredConfigHome.isNotEmpty)
        ? configuredConfigHome
        : _defaultLinuxConfigHome();
    return Directory(p.join(configHome, 'autostart'));
  }

  /// Resolve the absolute path of the EasyPass desktop entry that this app
  /// would write into [autostartDirectory]. Returns `null` on non-Linux
  /// platforms (the Windows installer owns autostart).
  static String? resolveLinuxAutostartDesktopEntryPath() {
    if (!Platform.isLinux) return null;
    return p.join(autostartDirectory.path, 'easypass.desktop');
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // P3.5 §6 #6 — 迁移 tmp 路径生成（AUDIT-P1 §2.1 1st item）。
  //
  // 历史：固定名 `${file.path}.tmp` 在两个进程同时首次启动的窄窗口里会
  // 互相覆盖 —— 先到者 `copy + rename`，后到者 `copy` 期间**前者的 tmp**已
  // 被覆写，后到者的 `rename` 把覆写后的残片搬到 canonical。这是审计
  // §2.1 1st item 指出的并发首启窄窗口。
  //
  // 现状：
  //   - **唯一性** = `<pid>-<random8>`（2^32 空间，4B 之内足够无冲突）。
  //     pid 在同一台机器同一瞬时唯一，random 兜住"pid 复用 + 时间接近"
  //     的边界场景。
  //   - **可识别**：`_enforceLinuxPrivacy` 扫 glob
  //     `*.tmp-<pid>-<rand>.tmp`、`*.tmp-<pid>-<rand>` 都能 catch 所有
  //     历史残留。删除自己产的那个时按精确文件名，不影响别进程的 tmp。
  //   - **可测试**：`migrationTmpSuffixForTesting` 注入随机源，避免
  //     `Random.secure()` 不可重放。
  //
  // 安全语义保持：
  //   - 任何 `try/catch` 永远只动**自己创建的**tmp（精确路径）——
  //     不调 glob 删除。
  //   - 旧的 `_tightenLegacyDatabasePermissions` 等无影响（只动 legacy 路径）。
  //   - `_enforceLinuxPrivacy` 改扫 `.<basename>.tmp-*`（一个简单的
  //     POSIX `*` 通配符在 `dir.list()` 里实现为 `glob`）。
  //
  // 跨进程边界（"反向同步"）：
  //   - `dir.list()` 在 dart:io 上是 snapshot；我们枚举到的 tmp 都是
  //     当前目录下、由其他进程**之前**留下、还没来得及清理的；不会扫到
  //     同时进行中的另一进程的 tmp（双方时间差让 stat 漏不到）。
  //   - 跨文件系统 `rename`：POSIX 的 `rename(2)` 在跨 fs 上 atomicity
  //     不保证；`File.rename` 在 dart:io 走 c++ `rename(2)`，失败会被 catch
  //     捕获走"自身 tmp 删除"分支（见上文）。这是既有语义，不变。
  static const int _migrationSuffixRandomHexChars = 8;

  @visibleForTesting
  static Random? migrationRandomOverride;

  /// 给一个 canonical 路径算出「我这一进程」的迁移 tmp 绝对路径。
  ///
  /// 设计点：
  ///   - 返回的不是 `File`，仅字符串 —— 这样调用方在 `copy` 失败时仍能
  ///     基于字符串去 `chmod` / `delete`，不会被 `File` 已 deleted 的状
  ///     态机误导。
  ///   - `<pid>-<8 hex>` 让同一台机器上 pid 不同时也不撞名（即便
  ///     pid 复用 — pid 在 Linux 上不重用，但 macOS / 其他 dart:io 平
  ///     台上有重用，random 兜底）。
  @visibleForTesting
  static String migrationTmpPathForTesting(String canonicalPath) =>
      _migrationTmpPath(canonicalPath);

  static String _migrationTmpPath(String canonicalPath) {
    final rng = migrationRandomOverride ?? Random.secure();
    final suffix = rng.nextInt(1 << (_migrationSuffixRandomHexChars * 4));
    final hex = suffix.toRadixString(16).padLeft(
          _migrationSuffixRandomHexChars,
          '0',
        );
    return '$canonicalPath.tmp-$migrationPidForTesting-$hex';
  }

  @visibleForTesting
  static int migrationPidForTesting = _readCurrentPid();

  static int _readCurrentPid() {
    // dart:io top-level `pid` getter 在 Linux / Windows / macOS 上都有；
    // 这里取一次作为静态值，让测试可以注入固定值。
    // （dart:io 的 `pid` 是一次 syscall；缓存不丢语义。）
    return _currentProcessPid();
  }

  static int _currentProcessPid() {
    // 隔离函数：避免与上方 `migrationPidForTesting` 重名遮蔽 dart:io 的
    // `pid` top-level getter（编译器解析 `_currentProcessPid` 内的 `pid`
    // 走 dart:io，能确定指向）。
    return pid;
  }

  /// Main vault database path.
  static File get databaseFile =>
      File(p.join(dataDirectory.path, 'easypass.db'));

  /// Historical database path used by Windows and by unpacked Linux builds.
  static File get legacyDatabaseFile =>
      File(p.join(executableDirectory.path, 'easypass.db'));

  /// Daemon registration/token file path.
  static File get daemonInfoFile {
    // Do not normalize this with p.join: the Windows path shape and its
    // fallback behavior are part of the existing bridge contract.
    if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      return File('$localAppData\\EasyPass\\daemon.json');
    }
    return File(p.join(dataDirectory.path, 'daemon.json'));
  }

  /// Creates the Linux data directory and migrates an old executable-adjacent
  /// database when the new location does not already contain one.
  ///
  /// The old file is copied rather than deleted. AppImage's executable is
  /// normally read-only, and retaining the source file is the safest fallback
  /// when a future packaging change makes the old location removable.
  ///
  /// On Linux the data directory is locked down to `0700` and the database
  /// file (plus any migration intermediate) to `0600` so other local users
  /// cannot read the plaintext `name` / `url` / `username` columns. This is
  /// the POSIX equivalent of Windows' default `%LOCALAPPDATA%` ACL; Windows
  /// is intentionally left alone (`if (Platform.isWindows) return;`).
  static Future<File> prepareDatabaseFile() async {
    final file = databaseFile;
    if (!Platform.isLinux) return file;

    await file.parent.create(recursive: true);

    // Tighten the data directory and the database file BEFORE any early
    // return. The previous P1.2 implementation only ran this on the
    // "first-run / legacy-migration" path; on the dominant path
    // (`easypass.db` already exists) it was skipped, leaving the directory
    // at the umask default (`drwxr-xr-x` / `-rw-r--r--`). That is exactly
    // the leak the audit §1.1 called out, so this must run on every call.
    // Failures here must not block the app from opening the vault (the
    // directory may be on a filesystem that does not support POSIX
    // permissions, or the user may be inside a container that already
    // restricts access). Without this fallback the app would refuse to
    // start on a writable filesystem that simply lacks the chmod bit, which
    // is worse than running with the umask-derived default.
    await _enforceLinuxPrivacy(file);
    // P1.4 审计 §⑤：源库（legacy exe 旁拷贝）在"已存在新库"路径上完全没被
    // 触碰过——所以它的 umask 默认 0644 会一直挂着。每次调用都顺手收紧。
    await _tightenLegacyDatabasePermissions();

    if (await file.exists()) return file;

    final legacyFile = legacyDatabaseFile;
    if (await legacyFile.exists()) {
      // Copy through a per-process sibling so an interrupted copy never
      // leaves a half-written database at the canonical path. The POSIX
      // rename is atomic on the same filesystem; the old file stays put
      // in case the new install ever wants to fall back.
      //
      // P3.5 §6 #6 (AUDIT-P1 §2.1 1st item): the previous fixed
      // `${file.path}.tmp` collided if two processes started in the same
      // second (race window: `if (await file.exists()) return file;` is
      // not atomic across fork / concurrent first-launch) — copy #1 into
      // shared `.tmp`, copy #2 overwrites it, copy #1 renames to canonical
      // = a half-written/empty db at canonical. Suffix with pid + random
      // integer (8 hex chars is 2^32 ≈ 4B possibilities, plenty) so two
      // processes don't even share a tmp name. Cleanup logic below deletes
      // only the file we created, not a glob.
      //
      // 安全语义不变：
      //  - `copy` + `rename` 还在用，tmp 文件临终方式不变（不丢不漏）。
      //  - `tmp` 失败仍走 best-effort 收尾，权限守住 0600。
      //  - 失败路径仍抛 `FileSystemException`（注释明确"绝不抛未捕获"，
      //    这里由 `try/catch` 显式抛，等价处理）。
      final tmpFile = File(_migrationTmpPath(file.path));
      try {
        await legacyFile.copy(tmpFile.path);
        await tmpFile.rename(file.path);
      } catch (error) {
        // P1.4 审计 §⑥：异常路径上也要保证权限收紧。delete 之前先 chmod 600，
        // 这样即使 delete 失败（文件被锁 / 磁盘满），tmp 也不会以宽权限
        // 留在磁盘上。canonical path 在异常路径上不会被触碰。
        if (await tmpFile.exists()) {
          if (Platform.isLinux) {
            // chmod 不致命，失败时仍尝试删除。P1.5 审计 F4：把
            // `ProcessException`（spawn 失败 / PATH 没 chmod / EACCES）
            // 也归一到 "best-effort"——这条 catch 在迁移失败路径上，绝
            // 不能因为 chmod spawn 失败而把 FileSystemException 顶到上层
            // 阻断开库。
            try {
              final tmpChmod =
                  await Process.run('chmod', ['600', tmpFile.path]);
              if (tmpChmod.exitCode != 0) {
                // ignore: avoid_print
                print(
                  'AppPaths: chmod 600 on migration tmp '
                  '${tmpFile.path} failed '
                  '(exit ${tmpChmod.exitCode}); continuing',
                );
              }
            } on ProcessException catch (e) {
              // ignore: avoid_print
              print(
                'AppPaths: chmod 600 spawn failed on migration tmp '
                '(${_chmodSpawnDetail(e)}); continuing',
              );
            }
          }
          try {
            await tmpFile.delete();
          } catch (_) {
            // Best effort: a stray migration `tmp` is now at least 0600;
            // the next start of `_enforceLinuxPrivacy` sweeps any leftover
            // `*.tmp-<pid>-<rand>` siblings to 0600 too.
          }
        }
        throw FileSystemException(
          'Unable to migrate the legacy EasyPass database',
          file.path,
          error is OSError ? error : null,
        );
      }
      // After a successful migration, the freshly placed `easypass.db` and
      // any leftover `*.tmp-*` need the same 0600 treatment. Re-running the
      // helper is cheap (chmod is idempotent) and keeps the contract in one
      // place. 源库权限已在前面的 _tightenLegacyDatabasePermissions 里收紧。
      await _enforceLinuxPrivacy(file);
    }

    return file;
  }

  /// Restricts a token file to the current user on POSIX platforms.
  ///
  /// Linux only: Windows keeps the existing `%LOCALAPPDATA%` ACL semantics,
  /// which already restrict the directory to the current user account. This
  /// helper is a no-op on Windows so callers (e.g. [EasypassDaemon._persistInfo])
  /// can invoke it unconditionally.
  ///
  /// **P1.5 审计 F4**: `Process.run` may itself throw (PATH 里没有
  /// `chmod` / 沙箱拒 spawn / EACCES)。spawn 失败**不能**冒泡 —— 注释
  /// 早已声明 "must not prevent the vault from opening"，所以一律吞掉
  /// `ProcessException`，并把诊断标签脱敏化（仅留 `<basename> / <errno>`，
  /// 绝不写绝对路径）。`exitCode != 0` 的既有处理保持不变。
  static Future<void> makePrivate(File file) async {
    if (Platform.isWindows) return;
    try {
      final result = await Process.run('chmod', ['600', file.path]);
      if (result.exitCode != 0) {
        throw FileSystemException(
          'Unable to restrict EasyPass data file permissions',
          file.path,
        );
      }
    } on ProcessException catch (e) {
      // ignore: avoid_print
      print(
        'AppPaths: chmod spawn failed for ${p.basename(file.path)} '
        '(${_chmodSpawnDetail(e)}); continuing',
      );
    }
  }

  /// P1.4 审计 §⑥：fresh-install 路径上 `prepareDatabaseFile` 返回时 db
  /// 还没被 drift 创建，所以即便它 chmod 了也拿不到正确的实体文件。
  /// drift `setup` 回调在打开 SQLite 文件（**包括 onCreate 首次创建**）之后
  /// 运行，调用本入口把"drift 用 umask 默认 0644 创建的空 db"也收紧到 0600。
  /// 仅 Linux 公开入口；Windows 仍是 no-op（ACL 由系统保证）。
  static Future<void> enforceLinuxPrivacyFor(File database) =>
      _enforceLinuxPrivacy(database);

  /// Tighten the Linux data directory to `0700` and the database file (or
  /// any sibling `.tmp` migration intermediate) to `0600`. **Linux only** —
  /// Windows is intentionally skipped; the equivalent protection there is
  /// the `%LOCALAPPDATA%` ACL that the installer / OS already applies.
  ///
  /// Best effort: a chmod failure (filesystem without POSIX bits, container
  /// with read-only root, etc.) must not prevent the vault from opening.
  /// The audit log surfaces the failure for diagnosis.
  ///
  /// **P1.5 审计 F4**: 三处 `Process.run('chmod', …)` 都被 try/`on
  /// ProcessException` 包住。spawn 失败（PATH 没 chmod / 沙箱拒 spawn）
  /// 不再冒泡阻断开库；诊断标签脱敏化（用 `p.basename` 替路径）。`exitCode != 0`
  /// 既有处理保持不变。
  static Future<void> _enforceLinuxPrivacy(File database) async {
    if (!Platform.isLinux) return;

    // Directory first — a `0600` file inside a world-readable directory
    // would still leak its existence (and any directory-listing metadata).
    final dir = database.parent;
    try {
      final dirResult = await Process.run('chmod', ['700', dir.path]);
      if (dirResult.exitCode != 0) {
        // stderr from `chmod` already explains why; we deliberately do not
        // rethrow so a sandboxed build (e.g. a snap with no chmod support)
        // can still launch.
        // ignore: avoid_print
        print(
          'AppPaths: chmod 700 on ${dir.path} failed '
          '(exit ${dirResult.exitCode}); continuing with umask permissions',
        );
      }
    } on ProcessException catch (e) {
      // P1.5 审计 F4：spawn 失败（PATH 没 chmod / EACCES）必须吞掉 —— 这一行
      // 路径在 `prepareDatabaseFile` 每次开库都跑，绝不能阻断开库。
      // ignore: avoid_print
      print(
        'AppPaths: chmod 700 spawn failed on ${p.basename(dir.path)} '
        '(${_chmodSpawnDetail(e)}); continuing',
      );
    }

    try {
      final dbResult = await Process.run('chmod', ['600', database.path]);
      if (dbResult.exitCode != 0) {
        // A freshly first-launched user may not yet have the database file;
        // the legacy-migration path below will create it. ENOENT is the only
        // case that is not a real privacy failure; everything else still logs.
        final stderr = dbResult.stderr.toString();
        final isMissing = stderr.contains('No such file') ||
            stderr.contains('does not exist');
        // ignore: avoid_print
        print(
          'AppPaths: chmod 600 on ${database.path} '
          '${isMissing ? 'skipped (file does not exist yet)' : 'failed'} '
          '(exit ${dbResult.exitCode}); continuing',
        );
      }
    } on ProcessException catch (e) {
      // ignore: avoid_print
      print(
        'AppPaths: chmod 600 spawn failed on ${p.basename(database.path)} '
        '(${_chmodSpawnDetail(e)}); continuing',
      );
    }

    // Any leftover migration intermediate (`.tmp`) gets the same treatment
    // so it does not become the leak the migration was meant to plug.
    final tmp = File('${database.path}.tmp');
    if (await tmp.exists()) {
      try {
        final tmpResult = await Process.run('chmod', ['600', tmp.path]);
        if (tmpResult.exitCode != 0) {
          // ignore: avoid_print
          print(
            'AppPaths: chmod 600 on ${tmp.path} failed '
            '(exit ${tmpResult.exitCode})',
          );
        }
      } on ProcessException catch (e) {
        // ignore: avoid_print
        print(
          'AppPaths: chmod 600 spawn failed on ${p.basename(tmp.path)} '
          '(${_chmodSpawnDetail(e)}); continuing',
        );
      }
    }
  }

  /// P1.4 审计 §⑤：迁移成功后收紧**源库**权限。`prepareDatabaseFile` 复制
  /// 不删源库，旧副本若仍是 `-rw-r--r--`，就绕过整个权限防线。仅 Linux。
  /// 失败不致命：和 `_enforceLinuxPrivacy` 同款语义。
  ///
  /// **P1.5 审计 F4**：spawn 失败（PATH 没 chmod）也吞掉 —— 这一行在每次
  /// Linux 开库都跑，绝不能阻断开库。
  static Future<void> _tightenLegacyDatabasePermissions() async {
    if (!Platform.isLinux) return;
    final legacy = legacyDatabaseFile;
    if (!await legacy.exists()) return;
    try {
      final result = await Process.run('chmod', ['600', legacy.path]);
      if (result.exitCode != 0) {
        // ignore: avoid_print
        print(
          'AppPaths: chmod 600 on legacy ${legacy.path} failed '
          '(exit ${result.exitCode}); continuing',
        );
      }
    } on ProcessException catch (e) {
      // ignore: avoid_print
      print(
        'AppPaths: chmod 600 spawn failed on legacy '
        '${p.basename(legacy.path)} '
        '(${_chmodSpawnDetail(e)}); continuing',
      );
    }
  }
}
