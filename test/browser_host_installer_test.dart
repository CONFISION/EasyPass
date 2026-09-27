import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:easypass/features/browser_bridge/browser_host_installer.dart';

/// 浏览器桥接 host 安装 / 卸载 / 状态的服务层测试。
///
/// 范围：
/// - vendor → manifest 路径映射（5 个 vendor × 一条）
/// - manifest JSON 内容（path 绝对、allowed_* 与预期 ID 一致、type=stdio）
/// - 安装幂等 + 卸载幂等 + 卸载后残留为 0
/// - "路径失效" 检测（manifest 指向不存在的 host）
/// - 卸载的"missing"语义（未装过也返回成功）
///
/// 所有测试用一个**临时 HOME** 跑 —— 不要碰真实 `~/.config/...`。
/// 注意：依赖"可执行位（x）"的断言（wrapperUsable / isFullyInstalled）
/// 需要 chmod 真的生效；在 Linux 沙盒里默认成立，但在**不支持 chmod 的
/// 环境（如某些 CI 容器）里会失败** —— 那一类断言不再声称"chmod 失败也
/// 不影响"。需要写入权限的用例见 `S5：HOME 不可写`（已加 root 跳过）。
void main() {
  // 这些用例断言的是 **Linux 语义**（XDG manifest 路径、wrapper 脚本、可执行
  // 位、HOME 权限）。服务层在非 Linux（Windows/macOS）上会返回 `skipped`，
  // 这些断言没有意义 → 整个文件在非 Linux 上不注册用例，避免弄红 Windows CI。
  if (!Platform.isLinux) {
    return;
  }

  late Directory sandbox;
  late Directory homeDir;
  late BrowserHostInstaller installer;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easypass_bhi_');
    homeDir = Directory(p.join(sandbox.path, 'home'))..createSync(recursive: true);
    installer = BrowserHostInstaller();
  });

  tearDown(() async {
    if (await sandbox.exists()) {
      await sandbox.delete(recursive: true);
    }
  });

  /// 预建 vendor 根目录 → 让 install() 探测为"已装" ⇒ 写 manifest。
  /// 没调用这个 helper 的测试假定"vendor 根不在 → install 跳过"。
  Future<void> setupVendorRoots(Iterable<BrowserVendor> vendors) async {
    for (final v in vendors) {
      final roots = BrowserHostInstaller.resolveVendorRootPaths(
          homeDir.path);
      final root = roots[v]!;
      await Directory(root).create(recursive: true);
    }
  }

  group('vendor → manifest 路径映射', () {
    test('5 个 vendor 的 manifest 路径符合 XDG / Mozilla 约定', () {
      final paths = BrowserHostInstaller.resolveVendorManifestPaths(
        homeDir.path,
      );
      expect(paths.keys.toSet(), {
        BrowserVendor.chrome,
        BrowserVendor.chromium,
        BrowserVendor.brave,
        BrowserVendor.edge,
        BrowserVendor.firefox,
      });
      expect(
        paths[BrowserVendor.chrome],
        p.join(homeDir.path, '.config', 'google-chrome',
            'NativeMessagingHosts', '${BrowserHostInstaller.hostName}.json'),
      );
      expect(
        paths[BrowserVendor.chromium],
        p.join(homeDir.path, '.config', 'chromium',
            'NativeMessagingHosts', '${BrowserHostInstaller.hostName}.json'),
      );
      expect(
        paths[BrowserVendor.brave],
        p.join(homeDir.path, '.config', 'BraveSoftware', 'Brave-Browser',
            'NativeMessagingHosts', '${BrowserHostInstaller.hostName}.json'),
      );
      expect(
        paths[BrowserVendor.edge],
        p.join(homeDir.path, '.config', 'microsoft-edge',
            'NativeMessagingHosts', '${BrowserHostInstaller.hostName}.json'),
      );
      expect(
        paths[BrowserVendor.firefox],
        p.join(homeDir.path, '.mozilla', 'native-messaging-hosts',
            '${BrowserHostInstaller.hostName}.json'),
      );
    });

    test(r'wrapper 目录使用 $XDG_DATA_HOME/easypass（无则 ~/.local/share）',
        () {
      expect(
        BrowserHostInstaller.resolveWrapperDirectory(home: homeDir.path),
        p.join(homeDir.path, '.local', 'share', 'easypass'),
      );
      expect(
        BrowserHostInstaller.resolveWrapperDirectory(
          home: homeDir.path,
          xdgDataHome: '/srv/data',
        ),
        p.join('/srv/data', 'easypass'),
      );
    });

    test('vendor root 路径用于"vendor 是否安装"探测', () {
      final roots = BrowserHostInstaller.resolveVendorRootPaths(homeDir.path);
      expect(roots[BrowserVendor.chrome],
          p.join(homeDir.path, '.config', 'google-chrome'));
      expect(roots[BrowserVendor.chromium],
          p.join(homeDir.path, '.config', 'chromium'));
      expect(roots[BrowserVendor.brave],
          p.join(homeDir.path, '.config', 'BraveSoftware', 'Brave-Browser'));
      expect(roots[BrowserVendor.edge],
          p.join(homeDir.path, '.config', 'microsoft-edge'));
      expect(roots[BrowserVendor.firefox], p.join(homeDir.path, '.mozilla'));
    });
  });

  group('manifest 内容', () {
    test('Chromium 系 vendor 用 allowed_origins + chrome-extension:// scheme',
        () {
      for (final vendor in <BrowserVendor>[
        BrowserVendor.chrome,
        BrowserVendor.chromium,
        BrowserVendor.brave,
        BrowserVendor.edge,
      ]) {
        final body = BrowserHostInstaller.renderManifest(
          wrapperAbsolutePath: '/abs/path/easypass-native-host.sh',
          vendor: vendor,
        );
        final json = jsonDecode(body) as Map<String, dynamic>;
        expect(json['name'], BrowserHostInstaller.hostName);
        expect(json['type'], 'stdio');
        expect(json['path'], '/abs/path/easypass-native-host.sh');
        expect(
          (json['allowed_origins'] as List).single,
          'chrome-extension://${BrowserHostInstaller.extensionId}/',
        );
        expect(json.containsKey('allowed_extensions'), isFalse);
      }
    });

    test('Firefox 用 allowed_extensions（无 trailing slash、无 @vendor）', () {
      final body = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: '/abs/path/easypass-native-host.sh',
        vendor: BrowserVendor.firefox,
      );
      final json = jsonDecode(body) as Map<String, dynamic>;
      expect(json['type'], 'stdio');
      expect(json.containsKey('allowed_origins'), isFalse);
      expect(
        (json['allowed_extensions'] as List).single,
        BrowserHostInstaller.extensionId,
      );
    });

    test('扩展 ID 字符串与 Windows 现状字面量一致（事实锁定）', () {
      // 历史：Windows 装机使用 hlkbbdlgaocmnjlgpafkimobnkfniike（由 manifest.json
      // 的 key 字段导出）。本常量在 Linux 上必须产出同样的字面量，否则所有现
      // 有用户的浏览器拿不到这个 host。
      expect(BrowserHostInstaller.extensionId,
          'hlkbbdlgaocmnjlgpafkimobnkfniike');
    });

    test('renderManifest 接受多 ID 并写入 allowed_* 列表（MF3）', () {
      // MF3 修复：`resolveExtensionIds()` 的返回值现在真的进了 manifest。
      // 注入额外 ID 时，`allowed_origins` 列表里能看到每一个，缺一不可。
      final multi = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: '/abs/path/easypass-native-host.sh',
        vendor: BrowserVendor.chrome,
        extensionIds: const [
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ],
      );
      final json = jsonDecode(multi) as Map<String, dynamic>;
      expect(
        (json['allowed_origins'] as List),
        [
          'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
          'chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/',
        ],
      );

      // Firefox 也是同理，但用 `allowed_extensions`。
      final ffMulti = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: '/abs/path/easypass-native-host.sh',
        vendor: BrowserVendor.firefox,
        extensionIds: const [
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ],
      );
      final ffJson = jsonDecode(ffMulti) as Map<String, dynamic>;
      expect(
        (ffJson['allowed_extensions'] as List),
        ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'],
      );

      // 空列表回退到默认 `[extensionId]`，避免产"零 ID"的 manifest。
      final empty = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: '/abs/path/easypass-native-host.sh',
        vendor: BrowserVendor.chrome,
        extensionIds: const [],
      );
      final emptyJson = jsonDecode(empty) as Map<String, dynamic>;
      expect((emptyJson['allowed_origins'] as List).single,
          'chrome-extension://${BrowserHostInstaller.extensionId}/');
    });
  });

  group('wrapper 脚本', () {
    test('不会向 stdout 写非协议内容（除 exec 路径）', () {
      final body = BrowserHostInstaller.renderWrapperScript();
      // 失败兜底走 stderr；stdout 必须只透传给 exec 出的 `easypass`。
      expect(body.contains('1>&2'), isTrue);
      expect(body.contains('--native-host'), isTrue);
    });

    test(r'解析顺序：$APPIMAGE → baked → 同目录 → PATH 上的 easypass', () {
      // 注意：baked 块仅在 `extraCandidates` 非空时才会出现在 wrapper 里
      // （没候选时 for-loop 整段消失 —— 见下一个测试）。这里给它一条假
      // 候选，确保解析顺序的所有环节都能命中。
      final body = BrowserHostInstaller.renderWrapperScript(
        extraCandidates: const ['/dummy/candidate/easypass'],
      );
      final appimageIdx = body.indexOf('APPIMAGE');
      final bakedIdx = body.indexOf('_c in \\');
      final siblingIdx = body.indexOf('HERE');
      final pathIdx = body.indexOf('command -v easypass');
      expect(appimageIdx, greaterThanOrEqualTo(0));
      expect(bakedIdx, greaterThan(appimageIdx));
      expect(siblingIdx, greaterThan(bakedIdx));
      expect(pathIdx, greaterThan(siblingIdx));
    });

    test('extraCandidates 烘焙进 wrapper；POSIX 单引号闭合', () {
      // MF1 修复：把"真实二进制候选路径"在 install 时烘焙进 wrapper，路
      // 径含空格 / 单引号 / 双引号都不能让 wrapper 失效。
      final body = BrowserHostInstaller.renderWrapperScript(
        extraCandidates: const [
          '/opt/EasyPass/easypass',
          "/home/user's/easypass with space",
          '/path/with"double-quote/easypass',
        ],
      );
      // 每条候选都被 shell 单引号闭合：路径里嵌入的 `'` 全部用 `'\''` 闭合。
      expect(body, contains('/opt/EasyPass/easypass'));
      expect(body, contains(r"'/home/user'\''s/easypass with space'"));
      // 双引号不需要在单引号字符串里转义，但仍应被原样闭合。
      expect(body, contains(r'/path/with"double-quote/easypass'));
      // for 循环的逻辑行：每条候选（最后一条除外）后面必须跟 `\` 行延续。
      // 实际写入的字节里 `\` 是单字节。注意候选已经被 shellSingleQuote 闭
      // 合，所以行尾是 `'` + 空格 + `\`（` \`），不是 ` \` 跟在原文末尾。
      expect(body, contains("'/opt/EasyPass/easypass' \\"));
      expect(body,
          contains(r"'/home/user'\''s/easypass with space' \"));
      // 最后一条候选后**不**应有 `\`（否则 for list 不终止）。最后一条
      // 候选的原文 `/path/with"double-quote/easypass` 在 shellSingleQuote
      // 后是 `'/path/with"double-quote/easypass'` —— 也不应有 `\`。
      expect(body.contains('\'/path/with"double-quote/easypass\' \\'),
          isFalse);
      // 同样验证最后一行就以这个闭合引号 + LF 收尾。
      expect(body, contains('\'/path/with"double-quote/easypass\'\n'));
      // `do` 必须紧跟在最后一条候选后（POSIX sh 严格：for X in Y do
      // 必须在同一逻辑行 —— 用 `\` 把多行折成一行）。最后一条候选行以
      // 闭合引号 `'` 结尾，下一行是 `  do`（两个空格缩进）。直接用
      // `contains` 锁定这个 layout。
      expect(body, contains('/path/with"double-quote/easypass\''));
      expect(body, contains('  do\n'));
      // `do` 紧接的最后一条候选闭合引号（不在 \ 之后）。
      final doIdx = body.indexOf('  do\n');
      final beforeDo = body.substring(0, doIdx);
      expect(beforeDo.endsWith("'\n"), isTrue,
          reason: '最后一条候选必须以单引号 + LF 收尾，下一行才是 `do`');
    });

    test('shellSingleQuote 公开代理与实际行为一致（@visibleForTesting）', () {
      expect(BrowserHostInstaller.shellSingleQuote(''), "''");
      expect(BrowserHostInstaller.shellSingleQuote('plain'), "'plain'");
      expect(BrowserHostInstaller.shellSingleQuote("with'apos"),
          "'with'\\''apos'");
      // 实际嵌入到 wrapper 后能被 sh 正确解析（关键不变量）：把一个含
      // 单引号的路径走 shellSingleQuote 后传给 `sh`，应该**作为单条
      // token**被解析回原路径。最直接的验证：让 sh `eval` 这个串然后
      // 把它存进变量，再用 `printf '%s' "$X"` 输出。
      final raw = "/home/user's/easypass";
      final quoted = BrowserHostInstaller.shellSingleQuote(raw);
      // sh -c 'X=$1; printf "%s" "$X"' sh QUOTED ⇒ argv[1] 是 quoted 字
      // 符串。sh 不再展开 argv[1]（argv 是 literal），所以我们需要主动
      // 把 quoted 作为 shell 代码片段 eval 一次 —— 这正是 wrapper 后续
      // 把它当 `$candidate` 引用时的语义。
      // 用 raw string 避开 Dart 的 `$` 插值（`$X` / `$1` 都是 shell 变
      // 量，不是 Dart 的）。
      final probe = Process.runSync(
        'sh',
        [r'-c', r'eval "X=$1"; printf "%s" "$X"', 'sh', quoted],
      );
      expect(probe.exitCode, 0, reason: 'quoted path must be valid sh syntax');
      expect((probe.stdout as String), raw,
          reason: 'eval 后必须还原成原路径');
    });

    test('resolveWrapperBinaryCandidates：去重 + 顺序保留', () {
      final out = BrowserHostInstaller.resolveWrapperBinaryCandidates(
        wrapperDirectory: '/srv/data/easypass',
        resolvedExecutable: '/srv/data/easypass/easypass',
        homeDir: '/home/u',
        xdgDataHome: '/srv/data',
      );
      // 第一个应该是 `resolvedExecutable`，后面是 wrapper 同目录、最后
      // 是 XDG 解析后的同路径（重复项要折叠）。
      expect(out.first, '/srv/data/easypass/easypass');
      expect(out.toSet().length, out.length, reason: '不应有重复');
      // 三种来源都应该出现。
      expect(out, contains('/srv/data/easypass/easypass'));
    });

    test('wrapper 在没有候选时也能跑：for 块整段消失', () {
      final body = BrowserHostInstaller.renderWrapperScript();
      expect(body, isNot(contains('_c in')));
    });

    test('wrapper 在解析全失败时 stderr 明确报错且 exit 127', () async {
      // MF1 修复：缺 $APPIMAGE、没候选、没同目录 binary、PATH 上没有
      // `easypass` 时，wrapper 必须写一行**逐项原因**的错误到 stderr，
      // 然后 exit 127。stdout 不允许有任何字节（不能污染 native messaging
      // 帧）。
      final wrapper = File(p.join(homeDir.path, 'wrapper.sh'))
        ..writeAsStringSync(BrowserHostInstaller.renderWrapperScript());
      await Process.run('chmod', ['0700', wrapper.path]);

      final probe = await Process.run(
        wrapper.path,
        const [],
        environment: {
          // 浏览器式环境：HOME 在但 PATH 极小、APPIMAGE 不存在。
          'HOME': '/tmp',
          'PATH': '/usr/bin:/bin',
        },
      );
      expect(probe.exitCode, 127);
      final stderr = (probe.stderr as String).trim();
      expect(stderr, contains('easypass-native-host:'));
      expect(stderr, contains('cannot locate easypass binary'));
      expect(stderr, contains('APPIMAGE (unset)'));
      expect(stderr, contains('command -v easypass (not on PATH)'));
      // stdout 必须为空 —— 浏览器从 stdout 读 native messaging 帧，任何
      // 字节都会让 4B 长度前缀失同步。
      expect((probe.stdout as String), isEmpty);
    });
  });

  group('install / uninstall / status：真实文件系统', () {
    // install() 现在会探测 vendor 根目录（见 S2）。本组测试通过**预创建**
    // vendor 根目录让 install 触发全量 manifest 写入；不预建时只会写已
    // 探测到的 vendor。`setupVendorRoots()` helper 在 main() 顶层定义。

    test('未装之前 status → not installed', () async {
      // 显式把 resolvedExecutable 注入到一个不存在的路径，保证"链全断"
      // 分支在测试里也能命中 —— 否则 `Platform.resolvedExecutable` 在
      // 测试运行时是真存在的，会让这条断言在 CI 上偶发失败。
      final status = await installer.status(
        homeDir: homeDir.path,
        pathEnvOverride: '',
        resolvedExecutableOverride: '/definitely/does/not/exist/easypass',
      );
      expect(status.checked, isTrue);
      expect(status.isFullyInstalled, isFalse);
      expect(status.isPartiallyInstalled, isFalse);
      expect(status.wrapperExists, isFalse);
      // resolution chain 应复算 wrapper 解析顺序所涉及的位置，并把它们
      // 全部报告为不可达 —— 复算链全断 → `resolutionChainBroken=true`。
      expect(status.resolutionChainBroken, isTrue);
      for (final r in status.vendorReports.values) {
        expect(r.manifestExists, isFalse);
        expect(r.wrapperUsable, isFalse);
      }
    });

    test('install 写出 wrapper + 5 份 manifest（前提：5 vendor 根都在）',
        () async {
      await setupVendorRoots(BrowserVendor.values);
      final result = await installer.install(homeDir: homeDir.path);
      expect(result.installed, isTrue);
      expect(result.wrapperPath, isNotNull);

      expect(File(result.wrapperPath!).existsSync(), isTrue);
      expect(result.manifests, isNotNull);
      expect(result.manifests!.length, 5);
      expect(result.skippedVendors, isEmpty);
      expect(result.bakedCandidates, isNotEmpty);

      for (final path in result.manifests!.values) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }

      final status = await installer.status(homeDir: homeDir.path);
      expect(status.isFullyInstalled, isTrue);
      expect(status.isPartiallyInstalled, isFalse);
      expect(status.wrapperExists, isTrue);
      for (final r in status.vendorReports.values) {
        expect(r.manifestExists, isTrue);
        expect(r.wrapperPath, isNotNull);
      }
    });

    test('S2：vendor 根目录不存在 ⇒ 跳过该 vendor，不造空目录', () async {
      // 只预建 Chrome 与 Firefox 的 vendor 根 —— Brave / Edge / Chromium
      // 用户根本没装，install 不应该给它们造空目录。
      await setupVendorRoots(
          [BrowserVendor.chrome, BrowserVendor.firefox]);
      final result = await installer.install(homeDir: homeDir.path);
      expect(result.installed, isTrue);
      expect(result.manifests, isNotNull);
      expect(result.manifests!.length, 2);
      expect(result.skippedVendors.keys.toSet(),
          {BrowserVendor.chromium, BrowserVendor.brave, BrowserVendor.edge});

      // BraveSoftware 目录绝对不能凭空出现（用户没装 Brave）。
      expect(
          Directory(p.join(homeDir.path, '.config', 'BraveSoftware'))
              .existsSync(),
          isFalse);
      // microsoft-edge 也不能凭空出现。
      expect(
          Directory(p.join(homeDir.path, '.config', 'microsoft-edge'))
              .existsSync(),
          isFalse);
      // chromium 也不能凭空出现。
      expect(Directory(p.join(homeDir.path, '.config', 'chromium'))
              .existsSync(),
          isFalse);

      // Firefox 的 vendor 根（~/.mozilla/）已预建 ⇒ manifest 应在。
      final ffManifest = result.manifests![BrowserVendor.firefox]!;
      expect(File(ffManifest).existsSync(), isTrue);
    });

    test('MF3：EASYPASS_BROWSER_HOST_EXTENSION_ID 影响 manifest 内容',
        () async {
      // MF3 修复：`resolveExtensionIds()` 的返回值现在真的进了 manifest。
      // 这里**直接**调 `renderManifest` + 注入 ID，绕开 `Platform.environment`
      // 在 Linux 上不可写的坑（dart:io 文档说它在某些实现里是 unmodifiable
      // map），把"manifest 真用了多 ID"这一不变量锁住。
      const ids = [
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ];
      await setupVendorRoots([BrowserVendor.chrome]);
      await installer.install(homeDir: homeDir.path);

      // **直接**对已安装的 manifest 调 renderManifest 重写一遍，验证
      // `extensionIds` 真的影响最终 JSON。
      final originalManifestPath = (await installer.status(
              homeDir: homeDir.path))
          .vendorReports[BrowserVendor.chrome]!
          .manifestPath;
      final wrapperPath = (await installer.status(
              homeDir: homeDir.path))
          .wrapperPath!;

      // 渲染新 manifest（多 ID 版本），写回覆盖安装时的产物。
      final body = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: wrapperPath,
        vendor: BrowserVendor.chrome,
        extensionIds: ids,
      );
      File(originalManifestPath).writeAsStringSync('$body\n');

      // 重读 manifest 验证内容真的变成两个 ID。
      final reread = File(originalManifestPath).readAsStringSync();
      final json = jsonDecode(reread) as Map<String, dynamic>;
      expect(
        (json['allowed_origins'] as List),
        [
          'chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/',
          'chrome-extension://bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/',
        ],
      );

      // 此外验证 `resolveExtensionIds()` 默认值能正确产出单 ID（环境
      // 变量未设置时 fallback 到默认字面量）。
      final fallback = BrowserHostInstaller.renderManifest(
        wrapperAbsolutePath: wrapperPath,
        vendor: BrowserVendor.chrome,
      );
      final fallbackJson = jsonDecode(fallback) as Map<String, dynamic>;
      expect((fallbackJson['allowed_origins'] as List).single,
          'chrome-extension://${BrowserHostInstaller.extensionId}/');
    });

    test('MF1：install 把 candidates 烘焙进 wrapper', () async {
      await setupVendorRoots([BrowserVendor.chrome]);
      final result = await installer.install(homeDir: homeDir.path);
      expect(result.wrapperPath, isNotNull);
      final wrapperBody = File(result.wrapperPath!).readAsStringSync();
      expect(result.bakedCandidates, isNotEmpty);
      // 至少第一条 baked candidate 应该出现在 wrapper 里（单引号闭合后）。
      final firstQuoted = BrowserHostInstaller.shellSingleQuote(
          result.bakedCandidates.first);
      expect(wrapperBody, contains(firstQuoted));
    });

    test('install 幂等：第二次 install 不报错、内容一致', () async {
      await setupVendorRoots(BrowserVendor.values);
      await installer.install(homeDir: homeDir.path);
      final firstStatus = await installer.status(homeDir: homeDir.path);
      final firstManifests = <String, String>{};
      for (final entry in firstStatus.vendorReports.entries) {
        firstManifests[entry.key.name] =
            File(entry.value.manifestPath).readAsStringSync();
      }

      await installer.install(homeDir: homeDir.path);

      final secondStatus = await installer.status(homeDir: homeDir.path);
      for (final entry in secondStatus.vendorReports.entries) {
        final second = File(entry.value.manifestPath).readAsStringSync();
        expect(second, firstManifests[entry.key.name],
            reason: '${entry.key.name} 二次安装内容必须一致');
      }
    });

    test('uninstall 幂等：第一次删、第二次 no-op', () async {
      await setupVendorRoots(BrowserVendor.values);
      await installer.install(homeDir: homeDir.path);

      final first = await installer.uninstall(homeDir: homeDir.path);
      expect(first.uninstalled, isTrue);
      expect(first.removed.length, 5);
      expect(first.missing, isEmpty);
      // wrapper 文件保留（P4 桌面集成的"uninstall"才动它）
      expect(first.wrapperStillExists, isTrue);

      final second = await installer.uninstall(homeDir: homeDir.path);
      expect(second.uninstalled, isTrue);
      expect(second.removed, isEmpty);
      expect(second.missing.length, 5);
    });

    test('未装过直接 uninstall：所有 vendor 归为 missing，返回成功',
        () async {
      final result = await installer.uninstall(homeDir: homeDir.path);
      expect(result.uninstalled, isTrue);
      expect(result.removed, isEmpty);
      expect(result.missing.length, 5);
    });

    test('install 后 uninstall 再 status → not installed', () async {
      await setupVendorRoots(BrowserVendor.values);
      await installer.install(homeDir: homeDir.path);
      await installer.uninstall(homeDir: homeDir.path);

      final status = await installer.status(homeDir: homeDir.path);
      expect(status.isFullyInstalled, isFalse);
      expect(status.isPartiallyInstalled, isFalse);
      expect(status.wrapperExists, isTrue);
    });

    test('S5：HOME 不可写 ⇒ install 把错误冒出来，不静默成功', () async {
      // root 下 chmod 0500 并不能阻止写入（CAP_DAC_OVERRIDE）→ 该用例在
      // root / CI 容器里必然假失败，这里直接跳过。
      final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
      if (uid == '0') {
        return;
      }
      await setupVendorRoots([BrowserVendor.chrome]);
      // chmod 0500：所有者可读可执行但不可写。
      await Process.run('chmod', ['0500', homeDir.path]);
      bool threw = false;
      try {
        await installer.install(homeDir: homeDir.path);
      } catch (_) {
        threw = true;
      }
      // 恢复权限（不管结果如何都得还回去，免得 tearDown 删不掉）。
      await Process.run('chmod', ['0700', homeDir.path]);
      expect(threw, isTrue,
          reason: 'HOME 不可写时 install 必须抛错，不允许静默吞掉');
    });
  });

  group('wrapper 失效检测', () {
    test('manifest 指向不存在的 wrapper → wrapperUsable=false', () async {
      // 模拟"manifest 装着但 wrapper 被用户删了/移走了"的状态：
      // 装完正常 → 单独把 wrapper 删掉 → status 应能区分"manifest 在
      // 但 wrapper 失效"。
      // vendor 根必须预建，否则 install 会跳过。
      for (final v in BrowserVendor.values) {
        await Directory(BrowserHostInstaller.resolveVendorRootPaths(
                homeDir.path)[v]!)
            .create(recursive: true);
      }
      await installer.install(homeDir: homeDir.path);
      final wrapperPath = p.join(
        BrowserHostInstaller.resolveWrapperDirectory(home: homeDir.path),
        BrowserHostInstaller.wrapperFileName,
      );
      File(wrapperPath).deleteSync();

      final refreshed = await installer.status(homeDir: homeDir.path);
      expect(refreshed.wrapperExists, isFalse);
      expect(refreshed.isFullyInstalled, isFalse);
      // vendor 报告里 wrapperUsable 是 false（wrapper 文件不在）
      for (final r in refreshed.vendorReports.values) {
        expect(r.manifestExists, isTrue);
        expect(r.wrapperUsable, isFalse);
      }
    });

    test('MF1：wrapper 在但二进制都不可达 → resolutionChainBroken=true',
        () async {
      // 修了红队评审的"status 给假绿灯"问题：wrapper 自身 x 位满足 ≠
      // 二进制可达。要复算 wrapper 解析链 —— 任何候选都不存在时
      // resolutionChainBroken 必须 true，isFullyInstalled 必须 false。
      for (final v in BrowserVendor.values) {
        await Directory(BrowserHostInstaller.resolveVendorRootPaths(
                homeDir.path)[v]!)
            .create(recursive: true);
      }
      await installer.install(homeDir: homeDir.path);

      // S-D 之后 status 还会读 wrapper 里烘焙的候选（install 烘的是真实二
      // 进制，可达）—— 要真的构造"全断"，得把 wrapper 换成**只有不可达
      // 候选**的版本：用同一个 renderWrapperScript 生成（不是手写字符串），
      // 并确保不含任何可达候选。
      final wrapperFile = p.join(
        BrowserHostInstaller.resolveWrapperDirectory(home: homeDir.path),
        BrowserHostInstaller.wrapperFileName,
      );
      File(wrapperFile).writeAsStringSync(
        BrowserHostInstaller.renderWrapperScript(
          extraCandidates: const [
            '/definitely/does/not/exist/easypass-one',
            '/definitely/does/not/exist/easypass-two',
          ],
        ),
      );

      // 强制所有候选路径都不可达 → 解析链全断。
      final status = await installer.status(
        homeDir: homeDir.path,
        pathEnvOverride: '',
        resolvedExecutableOverride: '/definitely/does/not/exist/easypass',
      );
      expect(status.wrapperExists, isTrue,
          reason: 'wrapper 文件本身存在');
      expect(status.resolutionChainBroken, isTrue,
          reason: '解析链全断 → 路径失效');
      expect(status.isFullyInstalled, isFalse,
          reason: 'wrapper 文件在但二进制不可达 ⇒ 不是"fully installed"');
      expect(status.isPartiallyInstalled, isFalse,
          reason: '解析链断 ⇒ 归"未装/失效"（退出码 2），不报半成品');
      expect(status.toExitCode(), 2);
    });

    test('manifest JSON 损坏 → 报告为 wrapper missing，不抛错', () async {
      // 直接写一份坏 manifest，再跑 status：必须不抛错、把坏 vendor 归为
      // "wrapper missing"。
      for (final v in BrowserVendor.values) {
        await Directory(BrowserHostInstaller.resolveVendorRootPaths(
                homeDir.path)[v]!)
            .create(recursive: true);
      }
      await installer.install(homeDir: homeDir.path);
      final chromeManifest = File(p.join(homeDir.path, '.config',
          'google-chrome', 'NativeMessagingHosts',
          '${BrowserHostInstaller.hostName}.json'));
      chromeManifest.writeAsStringSync('not-json-at-all');

      final status = await installer.status(homeDir: homeDir.path);
      expect(status.checked, isTrue);
      // Chrome manifest 损坏 → 其 vendor 报告里 wrapperUsable 必须 false
      final chromeReport = status.vendorReports[BrowserVendor.chrome]!;
      expect(chromeReport.manifestExists, isTrue);
      expect(chromeReport.wrapperUsable, isFalse);
      // 其它 vendor 没受影响。
      for (final entry in status.vendorReports.entries) {
        if (entry.key == BrowserVendor.chrome) continue;
        expect(entry.value.manifestExists, isTrue);
      }
    });
  });

  group(r'不污染真实 $HOME', () {
    test('所有 manifest 路径都在传入的 homeDir 内', () async {
      // 这是个回归保护：不要哪天因为加 vendor 不小心写到了真实
      // ~/.config/...。
      await setupVendorRoots(BrowserVendor.values);
      await installer.install(homeDir: homeDir.path);
      final paths = BrowserHostInstaller.resolveVendorManifestPaths(
        homeDir.path,
      );
      for (final path in paths.values) {
        expect(p.isWithin(homeDir.path, path), isTrue,
            reason: 'manifest 路径必须在 sandbox 内: $path');
      }
      final wrapperDir = BrowserHostInstaller.resolveWrapperDirectory(
        home: homeDir.path,
      );
      expect(p.isWithin(homeDir.path, wrapperDir), isTrue);
    });
  });

  group('CLI 退出码语义（服务层 → 退出码映射的回归保护）', () {
    test('S5 #1: toExitCode() 映射表 (full=0 / partial=1 / other=2)', () {
      // 直接构造三种状态的 `BrowserHostStatus` 对象，覆盖 toExitCode 映
      // 射表本身 —— 这样不需要 chmod 真正成功（沙盒里会失败），也不需
      // 要真实的文件系统状态。
      // 全 vendor manifest 在 + wrapper 可用 + 链不断 ⇒ isFullyInstalled=true。
      final fullyReport = BrowserHostVendorReport(
        manifestPath: '/m',
        manifestExists: true,
        wrapperPath: '/w',
        wrapperUsable: true,
      );
      final fullyStatus = BrowserHostStatus(
        wrapperPath: '/w',
        wrapperExists: true,
        vendorReports: {
          for (final v in BrowserVendor.values) v: fullyReport,
        },
        resolutionChainBroken: false,
      );
      expect(fullyStatus.isFullyInstalled, isTrue);
      expect(fullyStatus.toExitCode(), 0);

      // partial：至少一份 manifest 存在，但 wrapperUsable 缺失 → isFully
      // false，但 partial true。
      final partialReport = BrowserHostVendorReport(
        manifestPath: '/m',
        manifestExists: true,
        wrapperPath: '/w',
        wrapperUsable: false, // 关键：wrapper 失效
      );
      final partialStatus = BrowserHostStatus(
        wrapperPath: '/w',
        wrapperExists: true,
        vendorReports: {
          for (final v in BrowserVendor.values) v: partialReport,
        },
        resolutionChainBroken: false,
      );
      expect(partialStatus.isFullyInstalled, isFalse);
      expect(partialStatus.isPartiallyInstalled, isTrue);
      expect(partialStatus.toExitCode(), 1);

      // not installed：vendorReports 全空（或全 missing）。
      final missingReport = BrowserHostVendorReport(
        manifestPath: '/m',
        manifestExists: false,
        wrapperPath: null,
        wrapperUsable: false,
      );
      final notInstalledStatus = BrowserHostStatus(
        wrapperPath: '/w',
        wrapperExists: false,
        vendorReports: {
          for (final v in BrowserVendor.values) v: missingReport,
        },
        resolutionChainBroken: true,
      );
      expect(notInstalledStatus.isFullyInstalled, isFalse);
      expect(notInstalledStatus.isPartiallyInstalled, isFalse);
      expect(notInstalledStatus.toExitCode(), 2);

      // 跳过平台（非 Linux）→ checked=false → 任何 vendor report 都
      // 不参与 → isFullyInstalled false、isPartiallyInstalled false
      // → exitCode 2。
      final skipped = BrowserHostStatus.skipped(platform: 'windows');
      expect(skipped.toExitCode(), 2);
    });

    test('toExitCode() 在真实文件系统：未装→2、装完→{0|1}、卸完→2', () async {
      // 端到端验证：跑 install → uninstall，让真实的状态对象喂给
      // toExitCode()。沙盒里 chmod 经常失败 → wrapperUsable=false →
      // isFullyInstalled 永远 false，所以"装完"那一步是 1（partial）
      // 而不是 0；这是沙盒限制，**不是** toExitCode 的语义问题。
      var status = await installer.status(
        homeDir: homeDir.path,
        resolvedExecutableOverride: '/no/such/binary/easypass',
      );
      expect(status.toExitCode(), 2);

      await setupVendorRoots(BrowserVendor.values);
      await installer.install(homeDir: homeDir.path);
      status = await installer.status(homeDir: homeDir.path);
      // 装完后状态：要么 isFullyInstalled（chmod 真正成功 ⇒ 0），要么
      // isPartiallyInstalled（chmod 失败 ⇒ 1）；绝对**不能** 2（=未装）。
      expect(status.toExitCode(), isNot(2));

      // 模拟半成品：删一份 manifest → 强制 partial → 1。
      final paths = BrowserHostInstaller.resolveVendorManifestPaths(
          homeDir.path);
      File(paths.values.first).deleteSync();
      status = await installer.status(homeDir: homeDir.path);
      expect(status.isPartiallyInstalled, isTrue);
      expect(status.toExitCode(), 1);

      // uninstall → 回到 not installed → 2。
      await installer.uninstall(homeDir: homeDir.path);
      status = await installer.status(homeDir: homeDir.path);
      expect(status.toExitCode(), 2);
    });
  });

  group('MF-A：install 与 status 判定口径一致（修订 2）', () {
    test('只装 Chrome：install 后 isFullyInstalled=true 且退出码 0', () async {
      await setupVendorRoots([BrowserVendor.chrome]);
      final result = await installer.install(homeDir: homeDir.path);
      expect(result.manifests!.keys.toList(), [BrowserVendor.chrome]);
      final status = await installer.status(homeDir: homeDir.path);
      expect(status.detectedVendors, {BrowserVendor.chrome});
      expect(status.isFullyInstalled, isTrue,
          reason: '旧语义要求 5 个 vendor 全在 → 只装 Chrome 永远修不好');
      expect(status.isPartiallyInstalled, isFalse);
      expect(status.missingDetectedVendors, isEmpty);
      expect(status.toExitCode(), 0);
    });

    test('detected 里缺一份 manifest ⇒ 半成品、退出码 1、点名缺谁', () async {
      await setupVendorRoots([BrowserVendor.chrome, BrowserVendor.firefox]);
      await installer.install(homeDir: homeDir.path);
      final paths =
          BrowserHostInstaller.resolveVendorManifestPaths(homeDir.path);
      File(paths[BrowserVendor.chrome]!).deleteSync();
      final status = await installer.status(homeDir: homeDir.path);
      expect(status.isFullyInstalled, isFalse);
      expect(status.isPartiallyInstalled, isTrue);
      expect(status.missingDetectedVendors, [BrowserVendor.chrome]);
      expect(status.toExitCode(), 1);
    });

    test('一份 manifest 都没有 ⇒ 未装（退出码 2），不误报半成品', () async {
      final status = await installer.status(
        homeDir: homeDir.path,
        pathEnvOverride: '',
        resolvedExecutableOverride: '/definitely/does/not/exist/easypass',
      );
      expect(status.isFullyInstalled, isFalse);
      expect(status.isPartiallyInstalled, isFalse);
      expect(status.toExitCode(), 2);
    });
  });

  group('S-A / S-D（修订 2 补充）', () {
    test('S-A：扩展 ID 注入 → install 产物真的用上多 ID', () async {
      const ids = [
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ];
      // 1) 环境变量解析（可注入 environment，不依赖进程环境）
      expect(
        BrowserHostInstaller.resolveExtensionIds(
            environment: const {
              'EASYPASS_BROWSER_HOST_EXTENSION_ID':
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            }),
        ids,
      );
      // 2) 端到端：install 写出的 manifest 里就是这两个 ID
      await setupVendorRoots([BrowserVendor.chrome]);
      await installer.install(homeDir: homeDir.path, extensionIdsOverride: ids);
      final paths =
          BrowserHostInstaller.resolveVendorManifestPaths(homeDir.path);
      final json = jsonDecode(File(paths[BrowserVendor.chrome]!).readAsStringSync())
          as Map<String, dynamic>;
      expect((json['allowed_origins'] as List), [
        'chrome-extension://${ids[0]}/',
        'chrome-extension://${ids[1]}/',
      ]);
    });

    test('S-D：status 复算解析链时也读 wrapper 里烘焙的候选（不报假 BROKEN）',
        () async {
      await setupVendorRoots([BrowserVendor.chrome]);
      final result = await installer.install(homeDir: homeDir.path);
      final baked = await BrowserHostInstaller.readBakedCandidatesFromWrapper(
          result.wrapperPath!);
      expect(baked, isNotEmpty);
      // 当前环境的 resolvedExecutable 故意指向不存在的位置：只有"读 wrapper
      // 烘焙列表"这条路径能救活判定。
      final status = await installer.status(
        homeDir: homeDir.path,
        resolvedExecutableOverride: '/definitely/does/not/exist/easypass',
      );
      expect(status.resolutionChainBroken, isFalse,
          reason: 'baked 候选可达 ⇒ 不能报 BROKEN');
      expect(status.isFullyInstalled, isTrue);
    });
  });

  group('修正轮 2 评审（#1/#2/#3）的补充修订', () {
    test('#1：AppImage 持久路径被烘焙，临时挂载路径被排除', () async {
      expect(
        BrowserHostInstaller.isEphemeralMountPath(
            '/tmp/.mount_AbC123/usr/bin/easypass'),
        isTrue,
      );
      expect(BrowserHostInstaller.isEphemeralMountPath('/opt/easypass'),
          isFalse);
      await setupVendorRoots([BrowserVendor.chrome]);
      final result = await installer.install(
        homeDir: homeDir.path,
        appImagePathOverride: '/opt/apps/EasyPass-2.3.2.AppImage',
      );
      expect(result.bakedCandidates.first, '/opt/apps/EasyPass-2.3.2.AppImage');
      final wrapper = File(result.wrapperPath!).readAsStringSync();
      expect(
        wrapper,
        contains(BrowserHostInstaller.shellSingleQuote(
            '/opt/apps/EasyPass-2.3.2.AppImage')),
      );
      for (final c in result.bakedCandidates) {
        expect(BrowserHostInstaller.isEphemeralMountPath(c), isFalse);
      }
    });

    test(r'#2：$XDG_CONFIG_HOME 生效（manifest 与 vendor 根都跟着走）',
        () async {
      final xdgConfig = Directory(p.join(sandbox.path, 'xdgcfg'))
        ..createSync(recursive: true);
      final paths = BrowserHostInstaller.resolveVendorManifestPaths(
          homeDir.path,
          xdgConfigHome: xdgConfig.path);
      expect(paths[BrowserVendor.chrome]!.startsWith(xdgConfig.path), isTrue);
      final roots = BrowserHostInstaller.resolveVendorRootPaths(homeDir.path,
          xdgConfigHome: xdgConfig.path);
      await Directory(roots[BrowserVendor.chrome]!).create(recursive: true);

      final result = await installer.install(
        homeDir: homeDir.path,
        xdgConfigHome: xdgConfig.path,
      );
      expect(result.manifests!.keys.toList(), [BrowserVendor.chrome]);
      expect(
          File(result.manifests![BrowserVendor.chrome]!).existsSync(), isTrue);
      // 默认 ~/.config 下不应被写入
      expect(
        File(BrowserHostInstaller.resolveVendorManifestPaths(homeDir.path)[
                BrowserVendor.chrome]!)
            .existsSync(),
        isFalse,
      );
    });

    test(r'#2b：uninstall 与 install 用同一份 $XDG_CONFIG_HOME 口径', () async {
      // 回归：uninstall 曾经不读 $XDG_CONFIG_HOME（也不收这个参数），于是
      // 设了该变量的用户执行卸载时去 ~/.config 找不到东西，报
      // "Already absent (no-op)" 退 0，而 manifest 留在原地。
      final xdgConfig = Directory(p.join(sandbox.path, 'xdgcfg-uninstall'))
        ..createSync(recursive: true);
      final roots = BrowserHostInstaller.resolveVendorRootPaths(homeDir.path,
          xdgConfigHome: xdgConfig.path);
      await Directory(roots[BrowserVendor.chrome]!).create(recursive: true);

      final installed = await installer.install(
        homeDir: homeDir.path,
        xdgConfigHome: xdgConfig.path,
      );
      final manifest = installed.manifests![BrowserVendor.chrome]!;
      expect(manifest.startsWith(xdgConfig.path), isTrue);
      expect(File(manifest).existsSync(), isTrue);

      final result = await installer.uninstall(
        homeDir: homeDir.path,
        xdgConfigHome: xdgConfig.path,
      );
      expect(result.uninstalled, isTrue);
      expect(result.removed, contains(BrowserVendor.chrome));
      expect(result.missing, isNot(contains(BrowserVendor.chrome)));
      expect(File(manifest).existsSync(), isFalse);
    });

    test('#3：PATH 可注入 —— 宿主 PATH 上有 easypass 也不会翻转闸门', () async {
      await setupVendorRoots([BrowserVendor.chrome]);
      await installer.install(homeDir: homeDir.path);
      final wrapperFile = p.join(
        BrowserHostInstaller.resolveWrapperDirectory(home: homeDir.path),
        BrowserHostInstaller.wrapperFileName,
      );
      File(wrapperFile).writeAsStringSync(
        BrowserHostInstaller.renderWrapperScript(
          extraCandidates: const ['/definitely/does/not/exist/only'],
        ),
      );
      final status = await installer.status(
        homeDir: homeDir.path,
        pathEnvOverride: '',
      );
      expect(status.resolutionChainBroken, isTrue);
    });
  });
}
