import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;

/// 浏览器扩展 Native Messaging 主机的 Linux 安装 / 卸载 / 状态服务。
///
/// 背景：
/// Windows 上 EasyPass 走注册表（`HKCU\...\NativeMessagingHosts\com.easypass.app`）
/// + 单个 manifest 文件（`%LOCALAPPDATA%\EasyPass\com.easypass.app.json`）。
/// Linux 不存在注册表概念，Chromium 系走
/// `~/.config/<vendor>/NativeMessagingHosts/<name>.json`，Firefox 走
/// `~/.mozilla/native-messaging-hosts/<name>.json`，每个 vendor 各一份。
/// 这是 Mozilla/Chromium 通用约定，本服务只生成/清理这些 manifest 文件。
///
/// 设计原则（红线）：
/// - **纯 Dart**，无 GUI 依赖；home 目录可通过参数注入，便于单测。
/// - **写文件必须可幂等**：重复安装内容一致；卸载已经不在的也返回成功。
/// - **绝不向 stdout 写非协议内容**：所有诊断走 stderr 或本服务返回的 result。
/// - Windows 路径下 `install/uninstall/status` 全部返回 `skippedOnPlatform`，由
///   调用方负责告知用户"Windows 用安装器"。
///
/// 来源（事实依据）：见 `dist/P2.1-facts.md`。
class BrowserHostInstaller {
  /// 主机名（在扩展与原生主机之间标识），与 Windows 一致。
  static const String hostName = 'com.easypass.app';

  /// 固定扩展 ID（由 manifest.json 的 `key` 字段导出）。该 ID **不能**改，
  /// 改了就与已发布的扩展脱钩 —— 所有现有用户的浏览器拿不到这个 host。
  /// 见 `browser_extension/native_host/com.easypass.app.json:6`、
  /// `installer/easypass_setup.iss:133`。
  static const String extensionId =
      'hlkbbdlgaocmnjlgpafkimobnkfniike';

  /// 通过环境变量 `EASYPASS_BROWSER_HOST_EXTENSION_ID` 注入额外/替代的
  /// 扩展 ID（多 ID 用英文逗号分隔）—— 用于"应用只知道扩展 ID 列表"
  /// 的部署形态：发行版多 ID 集合、内部测试、临时换 ID 时不必改源码。
  ///
  /// 默认 = `[extensionId]`（与 Windows 现状完全一致）。返回值会作为
  /// manifest 的 `allowed_origins` / `allowed_extensions` 写入，见
  /// [BrowserHostInstaller.renderManifest] 的 `extensionIds` 参数 —— 这
  /// 是 [BrowserHostInstaller.install] / `renderManifest` 真正调用它的
  /// 地方，而不是把它写成死代码。
  static List<String> resolveExtensionIds({Map<String, String>? environment}) {
    const envKey = 'EASYPASS_BROWSER_HOST_EXTENSION_ID';
    final raw = (environment ?? Platform.environment)[envKey];
    if (raw == null || raw.isEmpty) return const [extensionId];
    final ids = raw
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (ids.isEmpty) return const [extensionId];
    return ids;
  }

  /// `wrapper`（被 manifest `path` 指向的可执行脚本）。
  static const String wrapperFileName = 'easypass-native-host.sh';

  /// 读环境变量；空串视作未设置。
  static String? _envPath(String key) {
    final v = Platform.environment[key];
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// 描述文案（写入 manifest 的 `description`）。
  static const String manifestDescription =
      'EasyPass Password Manager Native Messaging Host';

  /// Linux 平台下"包装易主扩展"目录：与 `AppPaths.dataDirectory` 同源；
  /// 区别在于：wrapper 必须紧挨 `easypass` 二进制，否则 manifest `path`
  /// 可能在 AppImage 移动后失效。
  ///
  /// 这里复用 `XDG_DATA_HOME/easypass/` 而**不**用 `~/.local/bin/`，原因：
  /// - 与 daemon.json / 数据目录同处一地（`AppPaths.dataDirectory` 决议路径），
  ///   一处备份即同时带走 manifest + 数据库 + wrapper 的关系；
  /// - 不污染 PATH、不动用户 `~/.local/bin`。
  static String resolveWrapperDirectory({
    required String home,
    String? xdgDataHome,
  }) {
    final configured = xdgDataHome;
    final base = (configured != null && configured.isNotEmpty)
        ? configured
        : p.join(home, '.local', 'share');
    return p.join(base, 'easypass');
  }

  /// vendor → manifest 路径（绝对）。
  ///
  /// 注意 Brave 的子目录名历史上变过：Chromium 系通用是
  /// `~/.config/<vendor>/NativeMessagingHosts/`。我们这里**只**使用
  /// Mozilla/Chromium 文档明确的 vendor（chrome / chromium / brave /
  /// microsoft-edge / firefox），其他 vendor 不写 —— `status()` 看到未
  /// 列出的 manifest 也不去碰。
  ///
  /// Edge Linux 路径沿用 Chromium 系约定：
  /// `~/.config/microsoft-edge/NativeMessagingHosts/<name>.json`（其中
  /// `<name>` 是 hostName 字面量 `com.easypass.app`）。Edge for Linux
  /// 是 Chromium 内核，这条路径与上游现行实现一致。
  static Map<BrowserVendor, String> resolveVendorManifestPaths(
    String homeDir, {
    String? xdgConfigHome,
  }) {
    final config = xdgConfigHome ?? p.join(homeDir, '.config');
    final mozilla = p.join(homeDir, '.mozilla');
    return {
      BrowserVendor.chrome: p.join(config, 'google-chrome',
          'NativeMessagingHosts', '$hostName.json'),
      BrowserVendor.chromium: p.join(config, 'chromium',
          'NativeMessagingHosts', '$hostName.json'),
      BrowserVendor.brave: p.join(config, 'BraveSoftware',
          'Brave-Browser', 'NativeMessagingHosts', '$hostName.json'),
      BrowserVendor.edge: p.join(config, 'microsoft-edge',
          'NativeMessagingHosts', '$hostName.json'),
      BrowserVendor.firefox:
          p.join(mozilla, 'native-messaging-hosts', '$hostName.json'),
    };
  }

  /// vendor → "探测根"路径（即"用户是否装了这个 vendor"）。
  ///
  /// 这是 S2 修复：用一个比 manifest 目录更浅的根来判断 vendor 是否存
  /// 在。例如 Firefox 用户装了 Firefox 但还没建过 `native-messaging-hosts/`
  /// 子目录 —— 我们应当建这个子目录，而不是跳过 Firefox。
  ///
  /// 一般约定：
  /// - Chromium 系 → `~/.config/<vendor>/`（顶层 vendor 目录）
  /// - Brave → `~/.config/BraveSoftware/Brave-Browser/`
  /// - Firefox → `~/.mozilla/`
  static Map<BrowserVendor, String> resolveVendorRootPaths(
    String homeDir, {
    String? xdgConfigHome,
  }) {
    final config = xdgConfigHome ?? p.join(homeDir, '.config');
    final mozilla = p.join(homeDir, '.mozilla');
    return {
      BrowserVendor.chrome: p.join(config, 'google-chrome'),
      BrowserVendor.chromium: p.join(config, 'chromium'),
      BrowserVendor.brave: p.join(config, 'BraveSoftware', 'Brave-Browser'),
      BrowserVendor.edge: p.join(config, 'microsoft-edge'),
      BrowserVendor.firefox: mozilla,
    };
  }

  /// 构造 wrapper 脚本内容。
  ///
  /// 工作机制（解析顺序，按列表逐个 `test -x` 探测，命中即 `exec`）：
  /// 1. `$APPIMAGE` —— AppImage runtime 在 spawn 时注入。**只有**AppImage
  ///    形态下浏览器拉 wrapper 时才可能存在；浏览器自己的进程环境不带它。
  /// 2. 安装时烘焙进来的绝对路径候选（[extraCandidates]，由 `install()`
  ///    按"用户 home + XDG_DATA_HOME + 同目录"等位置解析后传入）。这是修
  ///    复"wrapper 在浏览器 spawn 后的纯环境里跑、找不到二进制"的环节：
  ///    浏览器看到的 stdio pipe 来自我们写死的路径，不依赖运行时 PATH。
  /// 3. 与 wrapper 同目录的 `easypass`（系统安装的最常见姿势：
  ///    `~/.local/share/easypass/easypass` 与 wrapper 同处）。
  /// 4. `command -v easypass`（PATH 兜底，开发测试用）。
  ///
  /// 全部解析失败：往 stderr 写**包含每个失败原因**的错误行 + `exit 127`。
  /// **绝不**往 stdout 写非协议内容 —— 浏览器进程从 stdout 读原生消息帧，
  /// 任何额外字节都会让 4B 长度前缀立刻失同步。
  ///
  /// [extraCandidates] 里的每条路径都按 POSIX shell 单引号闭合规则转义
  /// （单引号 → `'\''`），即使路径含空格、引号、换行也不会让 wrapper 失效。
  static String renderWrapperScript({List<String> extraCandidates = const []}) {
    // 整段 wrapper 不再走 raw template + Dart `${...}` 字符串 —— Dart 解析器
    // 会把 shell 的 `$VAR` / `$_c` / `${...}` 误识别为插值。改成程序化拼装：
    // 每行都用普通字符串字面量拼接，`r'$'` + `'_c'` 等方式把 `$` 注入 Dart
    // 字符串（让 shell 看到的 `$VAR` 是字面 `${VAR}` 字面 `$VAR` 字面 `$@`）。
    final quoted = extraCandidates.map(_shellSingleQuote).toList();
    final buf = StringBuffer();
    void w(String line) => buf.writeln(line);

    w('#!/bin/sh');
    w('# EasyPass native-host wrapper (Linux).');
    w('#');
    w('# This script is the value of the native-messaging manifest\'s '
        '`path` field.');
    w('# The browser spawns it with stdin/stdout as the message pipe; we '
        'MUST NOT');
    w('# write anything else to stdout (the protocol is 4-byte length '
        'prefix +');
    w('# UTF-8 JSON; extra bytes break framing).');
    w('#');
    w('# Resolution order (first hit wins):');
    w('#   1. \${APPIMAGE}            -- set by the AppImage runtime inside one');
    w('#   2. baked absolute paths   -- provided at install time (see below)');
    w('#   3. <wrapper_dir>/easypass -- sibling install, common for system '
        'installs');
    w('#   4. `easypass` on PATH     -- dev/test fallback only');
    w('#');
    w('# Failure: a clear line on stderr explaining every probe we tried, '
        'then');
    w('# exit 127. Never silent: the browser would otherwise keep spawning us');
    w('# and the user would see "Unknown action: ..." without knowing why.');
    w('');
    w('set -eu');
    // 双保险：不依赖 argv 解析，直接告诉 App"我是被浏览器拉起的宿主"。
    w('export EASYPASS_NATIVE_HOST=1');
    w('');
    w('log() {');
    w('  # stderr only; stdout is reserved for the protocol.');
    w('  printf \'easypass-native-host: %s\\n\' "\$1" 1>&2');
    w('}');
    w('');
    w('# Track every probe we tried so the failure message names them all.');
    w('_tried=\'\'');
    w('');
    w('record() {');
    w('  _tried="\${_tried}\${_tried:+; }\$1"');
    w('}');
    w('');
    w('if [ -n "\${APPIMAGE:-}" ]; then');
    w('  if [ -x "\${APPIMAGE}" ]; then');
    w('    exec "\${APPIMAGE}" --native-host "\$@"');
    w('  fi');
    w('  record "APPIMAGE=\'\${APPIMAGE}\' (not executable or missing)"');
    w('else');
    w('  record \'APPIMAGE (unset)\'');
    w('fi');

    if (quoted.isNotEmpty) {
      w('');
      w('  # Candidate absolute paths baked in at install time. Each is '
          'probed');
      w('  # with `[ -x "\$_c" ]`; the first hit is exec\'d. This is what '
          'lets');
      w('  # the wrapper locate the real binary when the browser spawns us '
          'with');
      w('  # its own (minimal) environment and APPIMAGE is not set.');
      // `for _c in LIST do` 必须是单条逻辑行（POSIX sh 严格规则）。这里
      // 在每条候选路径后追加 `\`（最后一条除外）做行延续，让多行排版
      // 仍然拼成一个 for-list。
      w('  for _c in \\');
      for (var i = 0; i < quoted.length; i++) {
        final isLast = i == quoted.length - 1;
        final suffix = isLast ? '' : ' \\';
        w('    ${quoted[i]}$suffix');
      }
      w('  do');
      w('    if [ -x "\$_c" ]; then');
      w('      exec "\$_c" --native-host "\$@"');
      w('    else');
      w('      record "baked candidate=\'\$_c\' (missing or not '
          'executable)"');
      w('    fi');
      w('  done');
    }

    w('');
    w('HERE="\$(dirname "\$(readlink -f "\$0")")"');
    w('if [ -x "\${HERE}/easypass" ]; then');
    w('  exec "\${HERE}/easypass" --native-host "\$@"');
    w('fi');
    w('record "\${HERE}/easypass (missing or not executable)"');
    w('');
    w('if command -v easypass >/dev/null 2>&1; then');
    w('  exec easypass --native-host "\$@"');
    w('fi');
    w('record \'command -v easypass (not on PATH)\'');
    w('');
    w('log "cannot locate easypass binary; tried: \${_tried}"');
    w('exit 127');

    return buf.toString();
  }

  /// POSIX shell 单引号闭合（用于把路径常量嵌入 wrapper 脚本）。
  ///
  /// 单引号字符串里不能直接出现 `'`；POSIX 约定是先关 `'`，再插入转义
  /// 单引号 `\'`，再开 `'`，即 `'\''`。空串返回 `''`。
  @visibleForTesting
  static String shellSingleQuote(String s) => _shellSingleQuote(s);

  /// 安装时把"可能的真实二进制路径"收集出来，写进 wrapper。
  ///
  /// 调用方通常传当前 `Platform.resolvedExecutable`（即用户正在跑的
  /// `easypass` 的真实位置 —— AppImage 内是 `/tmp/.mount_xxx/AppRun` 之类，
  /// 解包后是某个 build 目录下的 `easypass`）。同时把 wrapper 的同名目录
  /// 也带上（系统安装场景），便于升级后"binary 被移到 sibling"也能找到。
  ///
  /// 返回值是**去重 + 顺序保留**的绝对路径列表。空串 / 解析失败的位置
  /// 会被丢弃。
  /// wrapper 的最后一道兜底：`command -v easypass`。
  ///
  /// status 复算解析链时也要看这里，否则"唯一可达的二进制在 PATH 上"
  /// 会被误报成 BROKEN（红队评审 S-D 第 6 条）。
  /// AppImage / 解包运行时的临时挂载路径：App 退出即失效，不作为候选。
  @visibleForTesting
  static bool isEphemeralMountPath(String path) =>
      path.contains('/.mount_') || path.startsWith('/tmp/.mount');

  static List<String> _pathCandidatesFor(String name, {String? pathEnv}) {
    final path = pathEnv ?? Platform.environment['PATH'];
    if (path == null || path.isEmpty) return const <String>[];
    final out = <String>[];
    for (final dir in path.split(':')) {
      if (dir.isEmpty) continue;
      final candidate = p.join(dir, name);
      if (File(candidate).existsSync()) out.add(candidate);
    }
    return out;
  }

  static List<String> resolveWrapperBinaryCandidates({
    required String wrapperDirectory,
    String? resolvedExecutable,
    String? homeDir,
    String? xdgDataHome,
    String? appImagePath,
  }) {
    final out = <String>[];
    void add(String? raw) {
      if (raw == null) return;
      final s = raw.trim();
      if (s.isEmpty) return;
      if (out.contains(s)) return;
      out.add(s);
    }

    // AppImage 的**持久文件路径**优先（红队评审 #1）：AppImage 运行时
    // `Platform.resolvedExecutable` 指向临时挂载里的副本（`/tmp/.mount_*`），
    // App 退出即失效；而浏览器 spawn wrapper 时**不会**带 `$APPIMAGE`。
    // 所以必须把持久路径烘焙进去，否则 AppImage 用户 install 报 0、
    // status 却报 BROKEN。
    add(appImagePath);
    if (resolvedExecutable == null ||
        !isEphemeralMountPath(resolvedExecutable)) {
      add(resolvedExecutable);
    }

    // wrapper 同目录下的 `easypass` —— 系统安装 + P4 桌面集成的常见形态。
    add(p.join(wrapperDirectory, 'easypass'));

    // 安装目录本身（与 `AppPaths.dataDirectory` 同源，wrapperDirectory 已
    // 是它，但显式再列一次可以抵御"`AppPaths` 改了路径解析"这类隐式改动）。
    if (homeDir != null && homeDir.isNotEmpty) {
      final base = (xdgDataHome != null && xdgDataHome.isNotEmpty)
          ? xdgDataHome
          : p.join(homeDir, '.local', 'share');
      add(p.join(base, 'easypass', 'easypass'));
    }

    return out;
  }

  /// 构造单份 manifest 内容（不含尾随换行的 JSON object）。
  ///
  /// `allowed` 字段对应 vendor 接受的形式：Chrome/Edge/Brave/Chromium 用
  /// `allowed_origins`，Firefox 用 `allowed_extensions`（取值是扩展 ID
  /// 本身，不带 `@vendor` 后缀、不带 trailing slash —— 这是 Mozilla 文档
  /// 要求的格式）。
  ///
  /// [extensionIds] 决定 `allowed_*` 列表里的具体值；默认 = `[extensionId]`
  /// （Windows 现状字面量）。空列表会被折叠回默认值 —— 避免产出"零 ID"的
  /// manifest 导致浏览器拒绝。
  static String renderManifest({
    required String wrapperAbsolutePath,
    required BrowserVendor vendor,
    List<String>? extensionIds,
  }) {
    final ids = (extensionIds == null || extensionIds.isEmpty)
        ? const [extensionId]
        : extensionIds;
    final isFirefox = vendor == BrowserVendor.firefox;
    final allowedKey = isFirefox ? 'allowed_extensions' : 'allowed_origins';
    final allowedValues = isFirefox
        ? List<String>.from(ids)
        : ids.map((id) => 'chrome-extension://$id/').toList();
    final manifest = <String, Object>{
      'name': hostName,
      'description': manifestDescription,
      'path': wrapperAbsolutePath,
      'type': 'stdio',
      allowedKey: allowedValues,
    };
    return const JsonEncoder.withIndent('  ').convert(manifest);
  }

  // ─── Service entry points ─────────────────────────────────────────────

  /// 安装：写 wrapper + 已探测到的 vendor 各自的 manifest。
  ///
  /// 幂等：内容完全一致，重复调用不会出错（覆盖写）。已存在的 manifest
  /// 路径相同 → 文本相同 → 校验通过。
  ///
  /// vendor 探测：只对"用户机器上能看到的 vendor 根目录"写 manifest
  /// （Chrome 看 `~/.config/google-chrome/`，Firefox 看 `~/.mozilla/`
  /// 等）。若某 vendor 根目录不存在，则**跳过**这个 vendor 而不是无
  /// 条件创建 —— 避免给没装 Brave 的用户造一个 `BraveSoftware/...` 空目
  /// 录、以及避免把 Firefox 路径上的 `~/.mozilla/` 强行创建出来（用户可
  /// 能从来没装过 Firefox）。
  ///
  /// Linux 之外：`BrowserHostInstallResult.skipped(platform)` —— 调用方决定
  /// 是打条提示还是退出非零。
  Future<BrowserHostInstallResult> install({
    required String homeDir,
    String? xdgDataHome,
    String? xdgConfigHome,
    /// 测试用注入点：不传时走 [resolveExtensionIds]（读 `Platform.environment`）。
    List<String>? extensionIdsOverride,
    /// 测试用注入点：不传时读 `Platform.environment['APPIMAGE']`。
    String? appImagePathOverride,
  }) async {
    if (!Platform.isLinux) {
      return BrowserHostInstallResult.skipped(
        platform: Platform.operatingSystem,
      );
    }

    final wrapperDir = Directory(resolveWrapperDirectory(
      home: homeDir,
      xdgDataHome: xdgDataHome,
    ));
    final wrapperDirExisted = await wrapperDir.exists();
    await wrapperDir.create(recursive: true);
    if (!wrapperDirExisted) {
      await _ensurePermissions(
        wrapperDir.path,
        '0700',
        kind: 'wrapper dir',
      );
    }

    // 收集"可能装着真实二进制的位置"，烘焙进 wrapper —— 见
    // [resolveWrapperBinaryCandidates]。这是修复"浏览器式环境无 $APPIMAGE"
    // 的关键：浏览器拉 wrapper 时看不到 `$APPIMAGE`、看不到 PATH 上自定
    // 义安装的 `easypass`，只能靠我们写死的路径。
    final candidates = resolveWrapperBinaryCandidates(
      wrapperDirectory: wrapperDir.path,
      resolvedExecutable: Platform.resolvedExecutable,
      homeDir: homeDir,
      xdgDataHome: xdgDataHome,
      appImagePath: appImagePathOverride ?? _envPath('APPIMAGE'),
    );
    final wrapperPath = p.join(wrapperDir.path, wrapperFileName);
    await File(wrapperPath).writeAsString(
      renderWrapperScript(extraCandidates: candidates),
    );
    await _ensurePermissions(wrapperPath, '0700', kind: 'wrapper');

    final cfg = xdgConfigHome ?? _envPath('XDG_CONFIG_HOME');
    final paths = resolveVendorManifestPaths(homeDir, xdgConfigHome: cfg);
    final roots = resolveVendorRootPaths(homeDir, xdgConfigHome: cfg);
    final extensionIds = extensionIdsOverride ?? resolveExtensionIds();
    final manifests = <BrowserVendor, String>{};
    final skipped = <BrowserVendor, String>{};
    for (final entry in paths.entries) {
      final vendor = entry.key;
      final manifestPath = entry.value;
      final manifestDirPath = p.dirname(manifestPath);
      final vendorRootPath = roots[vendor]!;
      // vendor 根目录探测：例如 `~/.config/google-chrome/` 或 `~/.mozilla/`。
      // 不存在就跳过 —— 不要给没装该浏览器的用户造空目录。
      if (!await Directory(vendorRootPath).exists()) {
        skipped[vendor] = 'vendor root not detected ($vendorRootPath)';
        continue;
      }
      // vendor 根在 ⇒ 确保 manifest 所在子目录在（NativeMessagingHosts
      // / native-messaging-hosts），必要时建一个，**只对自己刚建的这个
      // 子目录** chmod 0700 —— 不会动用户已有的 vendor profile 目录权限。
      final manifestDir = Directory(manifestDirPath);
      final manifestDirExisted = await manifestDir.exists();
      await manifestDir.create(recursive: true);
      if (!manifestDirExisted) {
        await _ensurePermissions(manifestDir.path, '0700',
            kind: 'manifest dir (${vendor.name})');
      }
      final body = renderManifest(
        wrapperAbsolutePath: wrapperPath,
        vendor: vendor,
        extensionIds: extensionIds,
      );
      await File(manifestPath).writeAsString('$body\n');
      await _ensurePermissions(manifestPath, '0644', kind: 'manifest');
      manifests[vendor] = manifestPath;
    }

    return BrowserHostInstallResult.installed(
      wrapperPath: wrapperPath,
      manifests: manifests,
      skippedVendors: skipped,
      bakedCandidates: candidates,
    );
  }

  /// 卸载：删全部 5 份 manifest（5 个 vendor × 1 份），wrapper 保留
  /// （删除 wrapper 是 P4 desktop 集成的事 —— 卸载浏览器扩展支持不该顺
  /// 手清掉一个还能跑 `--native-host` 的脚本；wrapper 自身 0700 但不含
  /// 敏感数据，留着不影响安全）。
  ///
  /// **wrapper 文件会保留**，vendor 目录本身也保留（用户还可能在用该
  /// 浏览器，只是不要 EasyPass 这条 manifest 而已）。
  ///
  /// 幂等：任何一份已不存在都返回 true，不抛错。
  Future<BrowserHostUninstallResult> uninstall({
    required String homeDir,
    String? xdgDataHome,
  }) async {
    if (!Platform.isLinux) {
      return BrowserHostUninstallResult.skipped(
        platform: Platform.operatingSystem,
      );
    }

    final paths = resolveVendorManifestPaths(homeDir);
    final removed = <BrowserVendor>[];
    final missing = <BrowserVendor>[];
    for (final entry in paths.entries) {
      final file = File(entry.value);
      if (await file.exists()) {
        await file.delete();
        removed.add(entry.key);
      } else {
        missing.add(entry.key);
      }
    }

    // wrapper 文件本身：保留（见上）。但顺手回报 wrapper 路径，方便 UI 显示。
    final wrapperDirPath = resolveWrapperDirectory(
      home: homeDir,
      xdgDataHome: xdgDataHome,
    );
    final wrapperPath = p.join(wrapperDirPath, wrapperFileName);

    return BrowserHostUninstallResult(
      uninstalled: true,
      removed: removed,
      missing: missing,
      wrapperPath: wrapperPath,
      wrapperStillExists: await File(wrapperPath).exists(),
    );
  }

  /// 状态查询：完全只读，不写任何文件。
  ///
  /// 报告每个 vendor 的 manifest 是否存在、其 `path` 字段指向的文件
  /// 是否仍然可执行。**关键改进（MF1）**：除了检查 manifest 指向的 wrapper
  /// 文件本身，还**复算 wrapper 的解析链**（`$APPIMAGE` / 烘焙的候选 /
  /// 同目录 / PATH 上的 `easypass`）—— 任何一条链上能找到真实可执行文件，
  /// wrapper 就算"能用"。所有链都断 → `resolutionChainBroken=true`，
  /// `isFullyInstalled` 不能再回 true（即使 manifest 与 wrapper 文件都
  /// 在），即"路径失效"。
  ///
  /// 注意：status 时拿不到 `$APPIMAGE`（这是浏览器 spawn 时才注入的），
  /// 也没法看 wrapper 内部的 `command -v easypass` 的 PATH —— 所以复算
  /// 的是 wrapper 解析链中**纯路径**那部分（烘焙候选 + 同目录 + 系统中
  /// 常见安装位置）。如果 wrapper 真靠 PATH 上的 `easypass` 兜底，status
  /// 会把这种情况归为"无法静态确认"，但仍然报告 wrapper 文件可执行（用户
  /// 可以从 `wrapperUsable` 自己看）。
  ///
  /// **MF-A 一致性（修订 2）**：`install()` 与 `status()` 现在对"哪些
  /// vendor 该装/该查"使用**同一份**判定 —— 探测 vendor 根目录存在与否，
  /// 把每个 vendor 标为 detected / not-detected。`isFullyInstalled` 只对
  /// detected vendor 提要求；not-detected 不影响总体判定。这是为了解
  /// 决红队评审指出的"只装 Chrome 的用户永远修不好"的循环：之前 status
  /// 要求 5 个 vendor 全有 manifest，否则报 partial → 用户重跑 install
  /// 又只跳了已探测到的 → 永远 partial。
  ///
  /// **S-D 一致性（修订 2）**：`status()` 复算解析链时，除了用"当前
  /// resolvedExecutable + wrapper 同目录 + XDG 常见位"，**还**解析
  /// wrapper 文件本身烘焙的 `for _c in ...` 候选列表，二者取**并集**
  /// 探测。这样在 wrapper 是旧版本、二进制被移到 baked 列表里的位
  /// 置时也能正确判断，不会报假 BROKEN。
  ///
  /// [resolvedExecutableOverride] 默认为 `null`（= 用 `Platform.resolvedExecutable`）。
  /// 测试可显式传一个**不可达**路径让"链全断"分支被覆盖。传 `''` 表
  /// 显式"不注入任何 resolvedExecutable"。
  Future<BrowserHostStatus> status({
    required String homeDir,
    String? xdgDataHome,
    String? xdgConfigHome,
    /// 测试用注入点：不传时读 `Platform.environment['PATH']`。
    String? pathEnvOverride,
    Object? resolvedExecutableOverride = const _Sentinel(),
  }) async {
    if (!Platform.isLinux) {
      return BrowserHostStatus.skipped(platform: Platform.operatingSystem);
    }

    final cfg = xdgConfigHome ?? _envPath('XDG_CONFIG_HOME');
    final paths = resolveVendorManifestPaths(homeDir, xdgConfigHome: cfg);
    final roots = resolveVendorRootPaths(homeDir, xdgConfigHome: cfg);
    final wrapperDirPath = resolveWrapperDirectory(
      home: homeDir,
      xdgDataHome: xdgDataHome,
    );
    final wrapperPath = p.join(wrapperDirPath, wrapperFileName);

    // vendor 根目录探测：与 [install] 使用同一份 `resolveVendorRootPaths`，
    // 保证"是否安装"的口径一致（MF-A）。
    final detectedVendors = <BrowserVendor>{};
    for (final entry in roots.entries) {
      if (await Directory(entry.value).exists()) {
        detectedVendors.add(entry.key);
      }
    }

    // `resolvedExecutableOverride` 现在只用于**信息性**探测（下面以
    // `(informational)` 标出的那一条），**不参与** resolutionChainBroken
    // 闸门 —— 闸门只看 wrapper 自己的解析链。测试仍可用它注入一个不存在
    // 的路径来锁定"status 进程住哪不影响闸门"这一不变量。
    final String? ambientExecutable =
        identical(resolvedExecutableOverride, const _Sentinel())
            ? Platform.resolvedExecutable
            : resolvedExecutableOverride as String?;
    final bakedCandidates = await _readBakedCandidatesFromWrapper(wrapperPath);
    final siblingCandidates = resolveWrapperBinaryCandidates(
      wrapperDirectory: wrapperDirPath,
      homeDir: homeDir,
      xdgDataHome: xdgDataHome,
    );
    final pathCandidates =
        _pathCandidatesFor('easypass', pathEnv: pathEnvOverride);
    final probeCandidates = <String>{
      ...bakedCandidates,
      ...siblingCandidates,
      ...pathCandidates,
    };
    final probeResults = <String, bool>{};
    var anyCandidateReachable = false;
    for (final cand in probeCandidates) {
      final hit = await _looksExecutable(cand);
      probeResults[cand] = hit;
      if (hit) anyCandidateReachable = true;
    }

    if (ambientExecutable != null &&
        ambientExecutable.isNotEmpty &&
        !probeResults.containsKey(ambientExecutable)) {
      probeResults['$ambientExecutable (informational, status process)'] =
          await _looksExecutable(ambientExecutable);
    }

    final vendorReports = <BrowserVendor, BrowserHostVendorReport>{};
    for (final entry in paths.entries) {
      final file = File(entry.value);
      final exists = await file.exists();
      String? pathField;
      bool pathValid = false;
      if (exists) {
        try {
          final json = jsonDecode(await file.readAsString())
              as Map<String, dynamic>;
          pathField = json['path'] as String?;
          if (pathField != null) {
            final target = File(pathField);
            final targetExists = await target.exists();
            pathValid = targetExists && await _looksExecutable(target.path);
          }
        } catch (_) {
          // JSON 损坏也算 path 失效。
        }
      }
      vendorReports[entry.key] = BrowserHostVendorReport(
        manifestPath: entry.value,
        manifestExists: exists,
        wrapperPath: pathField,
        wrapperUsable: pathValid,
        vendorDetected: detectedVendors.contains(entry.key),
      );
    }

    final wrapperFileExists = await File(wrapperPath).exists();
    return BrowserHostStatus(
      wrapperPath: wrapperPath,
      wrapperExists: wrapperFileExists,
      vendorReports: vendorReports,
      resolutionProbes: probeResults,
      resolutionChainBroken: !anyCandidateReachable,
      detectedVendors: detectedVendors,
    );
  }

  /// 从 wrapper 文件里把 install 时烘焙的 `for _c in ...` 候选列表读出来。
  ///
  /// wrapper 用 POSIX 单引号闭合所有 baked 候选（见 [renderWrapperScript]），
  /// 这里反向解析：定位 `for _c in \` 与下一行 `do` 之间的内容，按行扫
  /// 每条 `'<...>'` 串，**反转义** `'\''` → `'`。读不出来 / wrapper 不存在 /
  /// wrapper 不是我们写的，返回空列表 —— 复算链就只用 ambient 候选。
  ///
  /// 这是 S-D 的核心：让 status 在 wrapper 已 baked 但 binary 已移到 baked
  /// 路径的场景里仍然能正确判定（不再依赖"当前环境的 resolvedExecutable"）。
  @visibleForTesting
  static Future<List<String>> readBakedCandidatesFromWrapper(
          String wrapperAbsolutePath) =>
      _readBakedCandidatesFromWrapper(wrapperAbsolutePath);
}

/// `Object?` 哨兵 —— 区分"用户没传参数"和"用户显式传 null"。
class _Sentinel {
  const _Sentinel();
}

/// Linux 支持的 vendor 集合。
///
/// 5 个 vendor：Chrome / Chromium / Brave / Microsoft Edge / Firefox。
/// 顺序与 manifest 路径解析保持一致 —— 新增 vendor 时**两边**都要改。
enum BrowserVendor {
  chrome,
  chromium,
  brave,
  edge,
  firefox;

  String get displayName {
    switch (this) {
      case BrowserVendor.chrome:
        return 'Google Chrome';
      case BrowserVendor.chromium:
        return 'Chromium';
      case BrowserVendor.brave:
        return 'Brave';
      case BrowserVendor.edge:
        return 'Microsoft Edge';
      case BrowserVendor.firefox:
        return 'Mozilla Firefox';
    }
  }
}

Future<void> _ensurePermissions(
  String path,
  String mode, {
  required String kind,
}) async {
  // chmod 不是 POSIX 强制的；在没有 chmod 的环境（沙箱 / Windows 等）我们
  // 静默失败 —— 与 `AppPaths.makePrivate` 的"best effort"语义保持一致。
  // 诊断信息走 stderr：wrapper 自身的 stdout 必须留给 native messaging 帧。
  try {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      stderr.writeln(
        'BrowserHostInstaller: chmod $mode on $kind '
        '($path) failed (exit ${result.exitCode}); continuing',
      );
    }
  } on ProcessException catch (_) {
    stderr.writeln(
        'BrowserHostInstaller: chmod spawn failed for $kind; continuing');
  }
}

/// 简单判断一个文件是否可执行（POSIX 视角：任何 execute bit 被设置就算）。
/// 不依赖 `dart:io` 的 `File.stat` mode 位（dart:io 把文件 mode 暴露得不全），
/// 直接走 `ls -l` 风格的输出。
Future<bool> _looksExecutable(String path) async {
  try {
    final result = await Process.run('test', ['-x', path]);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// POSIX shell 单引号闭合 —— 见 [BrowserHostInstaller.shellSingleQuote]
/// 的公开代理；这里是真正干活的位置（公开方法只是为了 `@visibleForTesting`）。
String _shellSingleQuote(String s) {
  // 空串在 shell 里也是合法 token（空参数），但语义上我们更想要 `''`。
  if (s.isEmpty) return "''";
  // 拆掉所有 `'`，每段两端各补 `'`，中间用 `\'` 桥接。
  final parts = s.split("'");
  return "'${parts.join("'\\''")}'";
}

/// 从 wrapper 文件里读 install 时烘焙的 `for _c in ...` 候选列表。
///
/// wrapper 用 POSIX 单引号闭合所有 baked 候选（见 [renderWrapperScript]）。
/// 这里反向解析：定位 `for _c in \` 与下一行 `do` 之间的内容，按行扫
/// 每条 `'<...>'` 串，**反转义** `'\''` → `'`。读不出来 / wrapper 不
/// 存在 / wrapper 不是我们写的，返回空列表 —— 复算链就只用 ambient
/// 候选。
///
/// 这是 S-D 的核心：让 status 在 wrapper 已 baked 但 binary 已移到 baked
/// 路径的场景里仍然能正确判定（不再依赖"当前环境的 resolvedExecutable"）。
///
/// 实现为**纯函数**（除 `File.existsSync()` / `readAsStringSync()` 外不
/// 走任何 I/O），所以 `[BrowserHostInstaller.readBakedCandidatesFromWrapper]`
/// 可以直接复用于测试。
Future<List<String>> _readBakedCandidatesFromWrapper(
    String wrapperAbsolutePath) async {
  final file = File(wrapperAbsolutePath);
  if (!file.existsSync()) return const [];
  String body;
  try {
    body = file.readAsStringSync();
  } catch (_) {
    return const [];
  }
  return parseBakedCandidatesFromWrapperScript(body);
}

/// 公开的（@visibleForTesting）纯函数 —— 从 wrapper 脚本原文解析 baked 候选。
///
/// 测试可以直接喂字符串，不用先写文件。
@visibleForTesting
List<String> parseBakedCandidatesFromWrapperScript(String body) {
  // 找 `for _c in \` 这一行（后面带换行）；再到下一个 `  do` 之前的所有行
  // 都是候选。每行被 `\` 续行符折起来：POSIX sh 把 `\<LF>` 当空白。
  final forIdx = body.indexOf('for _c in');
  if (forIdx < 0) return const [];
  final afterFor = body.substring(forIdx);
  // for-list 终止于 `  do` 或 `do\n`（可能多缩进）。先按物理行分割再判断。
  final lines = afterFor.split('\n');
  final out = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    // `for _c in \` 自身跳过；下面的逻辑行（开头两个空格 + 内容 + 可能的 `\`）
    // 才放候选。
    if (i == 0) continue;
    if (line.trim() == 'do') break;
    // 去掉行尾的 `\` 行延续符 + 缩进（两空格）。候选按 shellSingleQuote 闭
    // 合过 —— 形态是 `    '/...'\` 或最后一行 `    '/...'`
    var stripped = line;
    if (stripped.endsWith(' \\')) {
      stripped = stripped.substring(0, stripped.length - 2);
    } else if (stripped.endsWith('\\')) {
      stripped = stripped.substring(0, stripped.length - 1);
    }
    stripped = stripped.trimLeft();
    // 必须以单引号闭合：开始和结束都是 `'`，中间允许 `'\''` 转义。
    if (stripped.length < 2 ||
        stripped[0] != "'" ||
        stripped[stripped.length - 1] != "'") {
      continue;
    }
    final inner = stripped.substring(1, stripped.length - 1);
    // 反转义 `'\''` → `'`
    final unescaped = inner.replaceAll(r"'\''", "'");
    out.add(unescaped);
  }
  return out;
}

// ─── Result types ─────────────────────────────────────────────

/// `install()` 结果。
class BrowserHostInstallResult {
  final bool installed;
  final String? platform;
  final String? wrapperPath;
  final Map<BrowserVendor, String>? manifests;

  /// 安装时跳过的 vendor（vendor 根目录不存在 → 不强行造空目录）。
  /// Key 是 vendor，value 是跳过原因（人类可读）。
  final Map<BrowserVendor, String> skippedVendors;

  /// 安装时烘焙进 wrapper 的真实二进制候选路径 —— 用于 status() 复算
  /// 解析链、以及 UI 调试时显示"wrapper 知道去哪些地方找二进制"。
  final List<String> bakedCandidates;

  const BrowserHostInstallResult._({
    required this.installed,
    this.platform,
    this.wrapperPath,
    this.manifests,
    this.skippedVendors = const {},
    this.bakedCandidates = const [],
  });

  factory BrowserHostInstallResult.installed({
    required String wrapperPath,
    required Map<BrowserVendor, String> manifests,
    Map<BrowserVendor, String>? skippedVendors,
    List<String>? bakedCandidates,
  }) =>
      BrowserHostInstallResult._(
        installed: true,
        wrapperPath: wrapperPath,
        manifests: manifests,
        skippedVendors: skippedVendors ?? const {},
        bakedCandidates: bakedCandidates ?? const [],
      );

  factory BrowserHostInstallResult.skipped({required String platform}) =>
      BrowserHostInstallResult._(installed: false, platform: platform);

  @override
  String toString() {
    if (!installed) {
      return 'BrowserHostInstallResult(skipped on $platform)';
    }
    final lines = manifests!.entries
        .map((e) => '  ${e.key.name}: ${e.value}')
        .join('\n');
    final skippedLines = skippedVendors.isEmpty
        ? ''
        : '\n  skipped: ${skippedVendors.entries.map((e) => '${e.key.name}=${e.value}').join(', ')}';
    return 'BrowserHostInstallResult(installed\n'
        '  wrapper: $wrapperPath\n'
        '$lines$skippedLines)';
  }
}

/// `uninstall()` 结果。
class BrowserHostUninstallResult {
  final bool uninstalled;
  final String? platform;
  final List<BrowserVendor> removed;
  final List<BrowserVendor> missing;
  final String? wrapperPath;
  final bool wrapperStillExists;

  const BrowserHostUninstallResult({
    required this.uninstalled,
    required this.removed,
    required this.missing,
    this.platform,
    this.wrapperPath,
    this.wrapperStillExists = false,
  });

  factory BrowserHostUninstallResult.skipped({required String platform}) =>
      BrowserHostUninstallResult(
        uninstalled: false,
        removed: const [],
        missing: const [],
        platform: platform,
      );

  @override
  String toString() {
    if (!uninstalled) {
      return 'BrowserHostUninstallResult(skipped on $platform)';
    }
    return 'BrowserHostUninstallResult(removed=${removed.map((v) => v.name).toList()} '
        'missing=${missing.map((v) => v.name).toList()} '
        'wrapperStillExists=$wrapperStillExists)';
  }
}

/// `status()` 结果。
class BrowserHostStatus {
  final bool checked;
  final String? platform;
  final String? wrapperPath;
  final bool wrapperExists;
  final Map<BrowserVendor, BrowserHostVendorReport> vendorReports;

  /// wrapper 解析链上每个候选路径的可达性（true = 该文件存在且可执行）。
  /// 这是 [BrowserHostInstaller.status] 复算 wrapper 解析顺序得到的"路
  /// 径失效"判断依据 —— 详情见 `status()` 注释。
  final Map<String, bool> resolutionProbes;

  /// `true` = 复算 wrapper 解析链（不依赖 `$APPIMAGE` 与 PATH 兜底）时
  /// **没有任何**候选路径可达。这是 MF1 新增的状态：用户能从这条告诉
  /// 出来"wrapper 在，但二进制不见了" —— 而不是只看 wrapper 自己 x 位
  /// 就回 "installed"。
  final bool resolutionChainBroken;

  /// 探测到的 vendor 集合（vendor 根目录存在的）—— MF-A 修订 2 新增。
  ///
  /// 这是 [install] 与 [status] 现在共享的"vendor 是否安装"的判定口
  /// 径：探测 vendor 根目录 → 标为 detected / not-detected。`isFullyInstalled`
  /// 只对 detected vendor 提要求；not-detected 记 N/A，**不影响**总体判定。
  final Set<BrowserVendor> detectedVendors;

  const BrowserHostStatus._({
    required this.checked,
    required this.wrapperExists,
    required this.vendorReports,
    this.resolutionProbes = const {},
    this.resolutionChainBroken = false,
    this.platform,
    this.wrapperPath,
    this.detectedVendors = const {},
  });

  factory BrowserHostStatus({
    required String wrapperPath,
    required bool wrapperExists,
    required Map<BrowserVendor, BrowserHostVendorReport> vendorReports,
    Map<String, bool>? resolutionProbes,
    bool resolutionChainBroken = false,
    Set<BrowserVendor>? detectedVendors,
  }) =>
      BrowserHostStatus._(
        checked: true,
        wrapperPath: wrapperPath,
        wrapperExists: wrapperExists,
        vendorReports: vendorReports,
        resolutionProbes: resolutionProbes ?? const {},
        resolutionChainBroken: resolutionChainBroken,
        detectedVendors: detectedVendors ?? const {},
      );

  factory BrowserHostStatus.skipped({required String platform}) =>
      BrowserHostStatus._(
        checked: false,
        wrapperExists: false,
        vendorReports: const {},
        platform: platform,
      );

  /// "全部就绪"判定（MF-A 修订 2）：
  ///
  /// 1. 必须真有 wrapper 文件（`wrapperExists`）；
  /// 2. wrapper 的解析链不能断（`!resolutionChainBroken`）；
  /// 3. **每个被探测到的 vendor** 都得有 manifest + 可用 wrapper。
  ///
  /// **不被探测到的 vendor**（not-detected，记 N/A）**不影响**总体判
  /// 定 —— 这是为了解决红队评审指出的"只装 Chrome 的用户永远修不好"
  /// 的循环：之前要求 5 vendor 全在，否则报 partial → 用户重跑 install
  /// 又只装已探测的 → 永远 partial。修订 2 之后："detected vendor 都
  /// 有 manifest" ⇒ full；"detected vendor 缺 manifest 或链断" ⇒
  /// partial（CLI 点名哪个 detected 缺）；"没任何 manifest" ⇒ 未装。
  bool get isFullyInstalled {
    if (!checked) return false;
    if (!wrapperExists) return false;
    if (resolutionChainBroken) return false;
    for (final r in vendorReports.values) {
      if (!r.vendorDetected) continue; // not-detected = N/A，不参与判定。
      if (!r.manifestExists || !r.wrapperUsable) return false;
    }
    return true;
  }

  /// "半成品"判定（MF-A 修订 2）：
  ///
  /// 至少一个 **detected** vendor 的 manifest 存在（但 wrapperUsable 失
  /// 效 / 解析链断 / 还有别的 detected vendor 没装上）。
  ///
  /// not-detected vendor 不参与 partial 判定 —— 否则只装 Chrome 的用
  /// 户会被判为 partial（5 份 manifest 中 1 份在，4 份"未装"，按旧
  /// 语义算 partial；CLI 提示"重跑 install 修复"→ install 又跳过未探测
  /// 的 → 永远 partial）。
  bool get isPartiallyInstalled {
    if (!checked) return false;
    if (isFullyInstalled) return false;
    // 解析链断（wrapper 找不到任何二进制）⇒ 归"未装/失效"（退出码 2），
    // 不报"半成品"，否则用户会以为"重跑 install 能修"却看不到真因。
    if (resolutionChainBroken) return false;
    // 语义（修订 2）：只要有任何 manifest、但没到"detected vendor 全部就绪"⇒ 半成品；
    // 一份 manifest 都没有 ⇒ 未装（CLI 报 not installed，退出码 2），
    // 这样 "uninstall 之后" 不会被误报为半成品。
    return vendorReports.values.any((r) => r.manifestExists);
  }

  /// 给 CLI 用的："detected vendor 中哪些缺 manifest / wrapperUsable"。
  /// 用于打印人类可读的"半成品"清单。
  Iterable<BrowserVendor> get missingDetectedVendors sync* {
    for (final v in detectedVendors) {
      final r = vendorReports[v];
      if (r == null) continue;
      if (!r.manifestExists || !r.wrapperUsable) yield v;
    }
  }

  @override
  String toString() {
    if (!checked) {
      return 'BrowserHostStatus(skipped on $platform)';
    }
    final lines = vendorReports.entries
        .map((e) => '  ${e.key.name}: ${e.value}')
        .join('\n');
    return 'BrowserHostStatus(wrapper=$wrapperPath, exists=$wrapperExists, '
        'chainBroken=$resolutionChainBroken\n'
        '$lines)';
  }

  /// **CLI 退出码语义**（S5 #1 抽出，便于单测）。
  ///
  /// 这是 CLI 子命令 `--browser-host-status` 把 [BrowserHostStatus] 状态
  /// 对象映射到进程退出码的**唯一**入口：
  ///
  /// - `isFullyInstalled`         → 0（已安装，全部 vendor 就绪）
  /// - `isPartiallyInstalled`     → 1（半成品，至少一份 manifest 存在）
  /// - 其它                       → 2（未装 / 解析链断 / 已跳过平台）
  ///
  /// 在 `test/browser_host_installer_test.dart` 里直接断言这套映射，避免
  /// CLI 状态语义变更时没人盯得到退出码漂移。
  int toExitCode() {
    if (isFullyInstalled) return 0;
    if (isPartiallyInstalled) return 1;
    return 2;
  }
}

/// 单 vendor 的状态报告。
class BrowserHostVendorReport {
  final String manifestPath;
  final bool manifestExists;

  /// manifest 内 `path` 字段解析出的 wrapper 路径（manifest 缺失时 null）。
  final String? wrapperPath;

  /// wrapper 文件存在且可执行（manifest 缺失时为 false）。
  final bool wrapperUsable;

  /// 该 vendor 的浏览器根目录是否存在（MF-A：install 与 status 共用同一
  /// 份"哪些 vendor 该装/该查"的判定；not-detected 记 N/A，不参与总体判定）。
  final bool vendorDetected;

  const BrowserHostVendorReport({
    required this.manifestPath,
    required this.manifestExists,
    required this.wrapperPath,
    required this.wrapperUsable,
    this.vendorDetected = true,
  });

  @override
  String toString() =>
      'BrowserHostVendorReport(manifest=${manifestExists ? "exists" : "missing"} '
      'wrapper=${wrapperUsable ? "ok" : (wrapperPath == null ? "n/a" : "broken")} '
      'detected=$vendorDetected)';
}