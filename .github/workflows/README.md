# GitHub Actions — 触发条件与维护说明

本目录是 EasyPass 的 CI/CD 定义。两个工作流都只碰「测试 / 出包」，不参与任何版本号
修改：版本号仍然是手工推进的（`pubspec.yaml` ↔ `browser_extension/manifest.json` ↔
`lib/features/settings/screens/settings_screen.dart` 里显示的版本 ↔
`installer/easypass_setup.iss`，由 `browser_extension/tools/check_extension.mjs` 校验）。

| 文件 | 触发 | 做什么 |
| --- | --- | --- |
| `ci.yml` | push 到 `master`、任何 `pull_request` | Windows 上跑 analyze / test / 扩展静态检查 + 三个 jsdom 冒烟 / runner 语法检查 |
| `release.yml` | 推送 `v*` 形式的 tag（如 `v3.0.0`） | Windows 装包，汇总 `SHA256SUMS.txt` 并创建 GitHub Release |

两个文件的注释都是中文；`name:`（Actions 界面里显示的步骤名）保持英文，便于在
GitHub 网页上扫读。改动工作流后建议本地跑一次 `actionlint`（见文末）。

---

## ci.yml

```yaml
on:
  push: { branches: [master] }
  pull_request:            # opened / synchronize / reopened
```

- 同一分支或同一个 PR 再次推送时，旧的一次运行会被取消
  （`concurrency: ci-${{ github.ref }}`）。
- 权限只有 `contents: read`，不写任何东西。

### 唯一的任务：Windows

跑在 `windows-latest` 上，因为 Windows 是本仓库唯一支持的平台（Linux 适配在 `linux` 分支）。

  `easypass_daemon_terminate_test.dart` 的
SIGTERM 路径）在 Windows 上**不注册用例**，所以 Windows 上的报告最接近"全绿即真绿"，
断言也不会因平台而漂移（见 AGENTS.md 的 Build/Test/Lint）。步骤顺序：

1. `flutter pub get`
2. `flutter analyze --no-pub`
3. `flutter test --no-pub`
4. `npm ci`（jsdom）→ `node browser_extension/tools/check_extension.mjs`
   → `smoke_content.mjs` → `smoke_popup.mjs` → `smoke_popup_extra.mjs`
5. 准备 `windows/flutter/ephemeral` → `cmd /c windows\runner\check_syntax.bat`

### jsdom 从哪来（为什么仓库根多了一个 package.json）

三个 `smoke_*.mjs` 需要 jsdom，而仓库原本没有 `package.json`：脚本会先
`require('jsdom')`，失败后才依次找 `$EASYPASS_JSDOM` / `$EASY_PASS_JSDOM`、
`%TEMP%\easypass-smoke\node_modules\jsdom`（Windows 手工安装的老路径）。
`require` 是从脚本所在目录逐级向上解析的，所以**在仓库根放一份 `node_modules/jsdom`
就足以命中**，三个脚本一行都不用改。因此：

- 新增根 `package.json`（`devDependencies.jsdom` **精确锁 30.1.3**，不带 `^`/`~`）
  与入库的 `package-lock.json`（`lockfileVersion: 3`）—— 也就是路线图里那句
  "jsdom 必须锁版本并提交 lockfile"。
- `.gitignore` 增加 `node_modules/`；`package.json` / `package-lock.json` 入库。
- CI 只跑 `npm ci`（按 lockfile 精确安装），不往 `%TEMP%` 里装东西。
- 本地用法不变：仍可用 `%TEMP%\easypass-smoke` 的老办法，或者更省事地
  `npm ci` 后在仓库根跑 `npm run test:extension`
  （= check + 三个冒烟，见 `package.json` 的 scripts）。
- jsdom 30.1.3 的 `engines` 要求 node `^22.22.2 || ^24.15.0 || >=26.0.0`；
  CI 用 `actions/setup-node` 固定 **24.22.0**（当前 LTS）。本地 Node 26.x 也可。

### 为什么 check_syntax 之前要准备 ephemeral

`windows\runner\check_syntax.bat` 用与真实构建相同的开关（`/Zs`、`/W4 /WX`）解析
runner 源码，**不调用 MSBuild**；但它的 `/I` 里包含 `windows\flutter\ephemeral` ——
`flutter_windows.h` 与 `cpp_client_wrapper\include\flutter\*.h` 就在那里，而这两个
目录只由 CMake 构建里的 `flutter_assemble` 目标拷进去（`flutter pub get` 只会生成
`generated_config.cmake` 和插件符号链接，不会拷引擎头文件）。CI 不跑
`flutter build windows`，所以显式做同一件事：

```powershell
flutter precache --windows
flutter assemble --no-version-check --output=build `
  "-dTargetPlatform=windows-x64" "-dBuildMode=debug" "-dTargetFile=lib/main.dart" `
  debug_bundle_windows-x64_assets
```

两个已经踩到的坑，改这段时注意：

1. **defines 必须加引号**。不加引号时 `-dTargetFile=lib/main.dart` 传到工具里会变成
   `lib/main`，`kernel_snapshot_program` 直接失败。
2. **不要直接跑 `unpack_windows`**。这个名字在 `flutter_tools` 的 `_kDefaultTargets`
   里注册了 x64 与 arm64 两个 target，map 是按名字建的，后注册的 arm64 会覆盖 x64，
   于是它去找 `windows-arm64-release` 的产物并报
   `Unsupported file type "notFound"`。走 `debug_bundle_…_assets` 才是 CMake 走的那条路
   （先 `UnpackWindows(targetPlatform)`，平台取自 `-dTargetPlatform`）。
   代价是顺带编译一次 Dart kernel（几分钟），换来的是和真实构建完全一致的
   ephemeral 内容。

### CI 不覆盖的东西（有意为之）

- **不跑 MSBuild / 不编译 C++ 原生代码**：真正的 `flutter build windows` 只在
  release.yml 里跑。`check_syntax.bat` 只能保证源码能过 cl.exe 的解析与类型检查
  （`/Zs` 不产出文件），链接期问题仍要真机构建才能发现。
- **不跑 `check_integrity.bat`**：它检查的是工作区的强制完整性标签（agent 沙箱
  workspace-write 会打 Low 标签），对 GitHub runner 没有意义。


  代价是多机位维护。
- **不做 `dart format` 检查**：本仓库刻意不跑 `dart format`（见 AGENTS.md），
  门禁只有 `flutter analyze`。

---

## release.yml

```yaml
on:
  push:
    tags: ['v*']
```

只由 tag 触发（没有 `workflow_dispatch`：这个工作流会直接发布 Release）。
tag 里的版本（如 `v3.1.0` 的 `3.1.0`）必须与 `pubspec.yaml` 的 `version:` 一致，否则第一个任务就失败。

### 任务

| 任务 | runner | 产出 |
| --- | --- | --- |
| `verify` | ubuntu-latest | 校验 tag ↔ `pubspec.yaml`，再跑 `check_extension.mjs`（四处版本号契约） |
| `windows` | windows-latest | `flutter build windows` → `tool/build_core.ps1` → ISCC → `EasyPass-<版本>-windows-x64-setup.exe` |

| `release` | ubuntu-latest | 下载 Windows artifact、跑 `installer/release/collect_artifacts.mjs`、创建/更新 GitHub Release |

产物名带版本号是为了发布页上好认。Release 里的资产是：`EasyPass-<版本>-windows-x64-setup.exe`
（安装包本体仍是 `build\installer\EasypassSetup.exe`，只是上传前改了名）、
`SHA256SUMS.txt` 以及 `release-manifest.json`。

### 核心服务

两个平台都在 UI 构建之后多跑一步**核心服务**构建（`easypass_core.exe` /
`easypass_core`），这是与 UI 并列的独立常驻进程，独占密码库：

- **构建命令是 `dart build cli -o <目录>`，不是 `dart compile exe`**：本仓库依赖图含
  build hook（`sqlite3` / `objective_c`），`dart compile exe` 会直接报
  `'dart compile' does not support build hooks, use 'dart build' instead`。
- 入口 `bin/easypass_core.dart`，产物 `<目录>/bundle/bin/easypass_core[.exe]`
  + `<目录>/bundle/lib/sqlite3.dll`。摊平逻辑封装在 `tool/build_core.ps1`（Windows）
  两个工作流只调脚本，不重复实现。
- **核心必须放进子目录，这是 `sqlite3` 原生库决定的**：`package:sqlite3` 用
  `@ffi.DefaultAsset` 编译，运行时按 `<exe 所在目录>\..\lib\<name>` 解析（Dart 3.13.4
  实测：放在 exe 旁边的副本**不会**被加载，`native_assets.json` sidecar 也被忽略）。
  所以统一成"核心在 `core/`、库在 `lib/`"：
  - Windows：`Release\core\easypass_core.exe` + `Release\lib\sqlite3.dll`。



  Flutter 自己那份 `Release\sqlite3.dll`（UI 用）保持不动。
- **数据坐标不变**：`AppPaths._resolveDataDirectory()`（`lib/core/platform/app_paths.dart`）
  发现父目录里有 UI 二进制（`easypass.exe`）就取父目录，所以核心在 `{app}\core\` 时
  保险库与 `daemon.json` 仍是 `{app}`，不需要迁移数据。
- Windows 的 `Verify build output` 断言 `core\easypass_core.exe` 与 `lib\sqlite3.dll`。

  `source: system`）。`.iss` 里核心与它的库分别装到 `{app}\core` 与 `{app}\lib`，
  `source: system`）。`.iss` 里核心与它的库分别装到 `{app}\core` 与 `{app}\lib`，
  自启项指向 `{app}\core\easypass_core.exe --serve`，安装/卸载前先停核心。

### Windows 任务

- `flutter build windows` 是仓库固定的 Windows 构建命令。它同时产出安装包需要的大部分
  东西：`easypass.exe`、原生消息桥 `easypass_native_host.exe`
  （`windows/runner/CMakeLists.txt` 的 POST_BUILD 调
  `browser_extension/native_host/build_bridge.bat`，cl.exe，不需要 MSBuild）以及
  app-local 的 MSVC 运行时 DLL（另一个 POST_BUILD 调 `installer/copy_vc_runtime.bat`）。
  随后 `tool/build_core.ps1` 补上核心服务（见上文"核心服务"），最后用一步
  `Verify build output` 断言这些文件真的在。
- **Inno Setup 版本**：`choco install innosetup` 目前给到的是 **Inno Setup 6.7.1**
  （装在 `C:\Program Files (x86)\Inno Setup 6`），而 owner 本机是
  `C:\Program Files\Inno Setup 7\ISCC.exe`。7 对 6 的脚本向后兼容，`.iss` 里用到的
  `compiler:Languages\ChineseSimplified.isl` 自 6.5.0 起属于官方翻译、随 Inno Setup
  一起安装，所以 6.7.1 也能编过。ISCC.exe 的定位按优先级尝试：Inno Setup 7 默认目录 →
  6 默认目录 → `Program Files*` 下任何 `Inno Setup*` 目录 → PATH 上的 `ISCC`
  （choco 的 shim）→ 注册表 Uninstall 项的 `InstallLocation`；全都找不到就带着候选
  列表报错。想让 CI 与本机完全一致，就把 `Install Inno Setup` 换成 YAML 注释里给出的
  `winget install --id JRSoftware.InnoSetup.7` 或官方 `innosetup-7.1.0-x64.exe`
  静默安装（两条命令都写在注释里了）。
- 安装包**没有代码签名**，CI 也不会签名：需要签名的话得先加证书 secret。

### Release 任务

- **校验和与清单不在这里手搓**：跑 `node installer/release/collect_artifacts.mjs
  --installer incoming/<安装包> --skip extension`，
  也就是仓库里唯一一份 `SHA256SUMS.txt` 实现（本地手工发布走同一条路，见
  `installer/release/README.md`）。它把产物拷进 `dist/release/<version>/`，
  写出 `SHA256SUMS.txt`（`<hex>  <文件名>`、按文件名排序、LF、无注释行 —— `sha256sum -c` 直接可用）。
  `sha256sum -c SHA256SUMS.txt` 直接可用）与 `release-manifest.json`，并且**缺产物就失败、
  一个文件都不写**，不会出现"只覆盖一半资产的校验和"。步骤里还会再独立
  `sha256sum -c` 复核一遍。
  `--skip extension` 是因为这个工作流不出扩展商店包；要一起发的话，在 windows 任务里加
  `node browser_extension/tools/build_extension_zip.mjs`，再去掉这个参数。
- 用预装的 `gh` CLI 而不是第三方 release action：这个仓库发布的是密码管理器资产，
  发布环节只依赖 GitHub 自己的工具链更稳妥。上传的是**整个** `dist/release/<version>/`
  目录。已存在的 tag 重跑时走 `gh release upload --clobber`，
  不会因为「Release 已存在」而失败。
- 发布说明目前是 `--generate-notes` 自动生成。仓库里那支
  `installer/release/generate_release_notes.mjs` 需要 `docs/release-<版本>.md`
  （`docs/` 是本地目录、不入库），所以它是**人工发布时**的收尾步骤，CI 不跑它；
  想要 CI 也生成的话，得先决定发布说明是否入库。
- 如果想在发布前人工确认，把 `gh release create` 加上 `--draft` 即可（一行改动）。
  当前是直接发布正式 Release。

---

## 维护备忘

- **Flutter 版本**：两个工作流都用 `FLUTTER_VERSION: 3.47.5` 精确固定
  （channel `stable`，自带 Dart 3.13.4，满足 `pubspec.yaml` 的 `^3.12.2`；
  `.metadata` 记录的 revision `6a19cca5…` 就是 3.47.5，与本机一致）。
  升级 Flutter 时改这两个 `env` 里的数字即可 —— 不要改成 `channel: stable` 的
  浮动写法，那样 CI 会在某天因为上游发版而无声地换工具链。
- **Node 版本**：`NODE_VERSION: 24.22.0`，受 jsdom 的 `engines` 约束。升级 jsdom 时
  一并检查。
- **第三方 action**：用的是各大版本 tag（`actions/checkout@v7`、
  `actions/setup-node@v7`、`actions/upload-artifact@v7`、
  `actions/download-artifact@v8`、`subosito/flutter-action@v2`）。若要进一步收紧供应链，
  可以改成按 commit SHA 钉死（Dependabot 能帮忙自动更新）。
- **本地跑同样的检查**（CI 之外的自检顺序）：
  ```bash
  flutter analyze --no-pub
  flutter test --no-pub
  npm ci && npm run test:extension     # check_extension + 三个 jsdom 冒烟
  cmd /c windows\runner\check_syntax.bat
  ```
- **改完工作流先 lint**：
  ```bash
  # 任选其一，能在推送前抓出 YAML 结构/表达式/上下文错误
  actionlint .github/workflows/ci.yml .github/workflows/release.yml
  ```
  本次提交的两个文件已用 actionlint v1.7.12 校验通过（0 问题），并用 PowerShell AST
  解析器逐个检查过所有 `shell: pwsh` 的 `run:` 块、用 `bash -n` 检查过所有 bash 块；
  release 任务里"假产物 → `collect_artifacts.mjs` → `sha256sum -c`"这条链路也在本地
  用临时目录完整跑通过（跑完把临时产物删干净）。

### 尚未在真实 runner 上验证的部分

本地只能验到"语法 + 静态契约 + 纯本机可跑的片段"这一层；下面这些要点第一次真正跑 CI
才能确认，若失败请按错误信息就地调整（都是环境层的小事，不涉及仓库代码）：

- `choco install innosetup` 在 windows-latest 上的实际安装路径与耗时；
  ISCC 编译 `.iss` 时能否找到 `Languages\ChineseSimplified.isl`（预期能，见上文）。
- `subosito/flutter-action` 拉取 3.47.5 的速度，以及 `flutter test` / `flutter build
  windows` 在 runner 上的耗时（`timeout-minutes` 已给 45 / 60 分钟，按需调整）。
- ci.yml 里"准备 `windows/flutter/ephemeral`"那一步的耗时：它包含一次引擎产物下载
  （约百 MB）和一次 Dart kernel 编译。命令本身已在本机（隔离副本里）验证过，但没在
  runner 上计时。
- **`.iss` 的新增 `[Code]`（安装/卸载前停核心）没有用 ISCC 编过**：本机按约定不跑
  ISCC，语法与运行时行为（`ewNoWait` 的优雅停机 + `taskkill` 兜底）要到 `release.yml`
  或人工打包时才第一次真正执行。
- `gh release create --generate-notes` 生成的发布说明是否需要人工润色。
