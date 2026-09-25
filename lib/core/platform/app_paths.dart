import 'dart:io';

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

  /// User-writable application data directory.
  static Directory get dataDirectory {
    // Keep the Windows (and other non-Linux desktop) behavior unchanged.
    if (!Platform.isLinux) return executableDirectory;

    final configuredDataHome = Platform.environment['XDG_DATA_HOME'];
    final dataHome =
        (configuredDataHome != null && configuredDataHome.isNotEmpty)
        ? configuredDataHome
        : _defaultLinuxDataHome();
    return Directory(p.join(dataHome, _linuxDataDirectoryName));
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
      // Copy through a sibling `.tmp` file so an interrupted copy never leaves
      // a half-written database at the canonical path.  The POSIX rename is
      // atomic on the same filesystem; the old file stays put in case the new
      // install ever wants to fall back.
      final tmpFile = File('${file.path}.tmp');
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
                  'AppPaths: chmod 600 on migration .tmp '
                  '${tmpFile.path} failed '
                  '(exit ${tmpChmod.exitCode}); continuing',
                );
              }
            } on ProcessException catch (e) {
              // ignore: avoid_print
              print(
                'AppPaths: chmod 600 spawn failed on migration .tmp '
                '(${_chmodSpawnDetail(e)}); continuing',
              );
            }
          }
          try {
            await tmpFile.delete();
          } catch (_) {
            // Best effort: a stray `.tmp` 现在至少是 0600，下一次启动
            // 的 _enforceLinuxPrivacy 会再 chmod 一次。
          }
        }
        throw FileSystemException(
          'Unable to migrate the legacy EasyPass database',
          file.path,
          error is OSError ? error : null,
        );
      }
      // After a successful migration, the freshly placed `easypass.db` and
      // any leftover `*.tmp` need the same 0600 treatment. Re-running the
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
