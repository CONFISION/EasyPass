# installer/release —— 发布产物收集与发布说明生成

发布时的产物清单、`SHA256SUMS.txt`、以及发布说明里那张"文件 / 大小 / SHA-256"表，都由这里的
两支脚本产出，不再靠人回忆（早期发布说明里那句 `SHA256  <构建后填这里>` 一直没人填，
就是流程没固定下来的后果）。

零依赖：只用 Node 内置模块（`node:fs` / `node:crypto` / `node:path`），CI 里不需要 `npm install`；
大文件流式哈希，不整份读进内存。两支脚本本身**不构建任何东西** —— 构建永远是用户 / CI 的事。

```
installer/release/
├── collect_artifacts.mjs        找产物 → SHA-256 → SHA256SUMS.txt + release-manifest.json
├── generate_release_notes.mjs   读 manifest → 发布说明 Markdown（人工段落保留）
├── release_notes.template.md    发布说明模板（含生成标记与 TODO(人工) 段落）
└── lib/release_common.mjs       共用：pubspec 版本号读取、参数解析、输出
```

版本号只有一个来源：`pubspec.yaml` 的 `version:`（读法与 `installer/deb/build_deb.sh`
一致：取 `x.y.z+build` 里的 `x.y.z`）。脚本里不写死版本号。

## 发布时跑什么

```bash
# 1) 构建 —— 由用户 / CI 执行（脚本不替你构建）
flutter build windows
"C:\Program Files\Inno Setup 7\ISCC.exe" installer\easypass_setup.iss
#   → build\installer\EasypassSetup.exe
flutter build linux --release
bash installer/deb/build_deb.sh build/linux/x64/release/bundle dist/easypass_<version>_amd64.deb
#   → release/EasyPass-<version>-linux-x86_64..deb（名字里带版本号，脚本才认得出）

# 2) 收集：拷进 dist/release/<version>/，写出 SHA256SUMS.txt + release-manifest.json
node installer/release/collect_artifacts.mjs

# 3) 生成发布说明：docs/release-<version>.md
node installer/release/generate_release_notes.mjs
```

- 只想预检、不写文件：`node installer/release/collect_artifacts.mjs --dry-run`
  （会**真的算一遍** SHA-256 并列出将写入的内容，但一个文件都不写；机器上还没构建过产物时它以 0 退出，
  加 `--strict` 就可以像正式运行一样以非零码失败）。
- 这一版只发 Windows：`node installer/release/collect_artifacts.mjs --skip linux`。
- 扩展商店包也要一起发（默认它是可选项，存在就收）：加 `--require extension`。
- 产物不在默认位置：`--installer <path>` / `--deb <path>` / `--extension <path>` / `--extra <path>`。

## 产物与默认路径

| 产物 | 默认路径 | 必需 | 由谁产出 |
| --- | --- | --- | --- |
| Windows 安装包 | `build/installer/EasypassSetup.exe` | 是 | `ISCC.exe installer/easypass_setup.iss` |
| Linux .deb | 自动发现（`release/` `dist/` `dist/release/` `build/` 仓库根，各一层，优先文件名含版本号的那个） | 是 | `installer/deb/build_deb.sh` |
| 扩展商店包 | `dist/easypass-extension-<version>.zip` | 否 | `node browser_extension/tools/build_extension_zip.mjs` |

## 产出（默认 `dist/release/<version>/`）

| 文件 | 说明 |
| --- | --- |
| 产物本体 | 从构建目录**拷贝**进来 —— 校验和与文件同目录，整目录直接上传 Release |
| `SHA256SUMS.txt` | `<hex>  <文件名>`（两空格），按文件名排序，**固定 LF 换行、不含注释行、不含时间戳** |
| `release-manifest.json` | 机器可读清单：版本、名称、字节数、sha256、来源命令 —— 发布说明由它渲染 |

`SHA256SUMS.txt` 只取决于产物字节本身（排序固定、LF、无时间戳），所以同样的产物永远得到同样的
文件；`release-manifest.json` 里有生成时间戳，需要完全可复现时用 `SOURCE_DATE_EPOCH=<unix 秒>` 固定。

## 校验

Linux（在 `dist/release/<version>/` 目录里）：

```bash
sha256sum -c SHA256SUMS.txt
```

Windows（PowerShell，同样在该目录里；`sha256sum` 不是 Windows 自带命令）：

```powershell
Get-Content SHA256SUMS.txt | ForEach-Object {
  $hash, $name = $_ -split '\s+', 2
  $actual = (Get-FileHash -Algorithm SHA256 -Path $name).Hash.ToLower()
  if ($actual -eq $hash) { "OK   $name" } else { "FAIL $name" }
}
```

单个文件也可以用 `certutil -hashfile <文件> SHA256` 或 `Get-FileHash <文件> -Algorithm SHA256`。

装了 Git for Windows 的话，还能直接借它的 GNU coreutils（与 Linux 上同一份实现）：
`& "$(Split-Path (Get-Command git).Source)\..\usr\bin\sha256sum.exe" -c SHA256SUMS.txt`。

## 退出码

| 码 | 含义 |
| --- | --- |
| 0 | 通过（`--dry-run` 表示"可以收集 / 可以生成"） |
| 1 | 产物缺失、哈希不一致、或目标发布说明没有生成标记（拒绝覆盖手写内容） |
| 2 | 参数 / 环境错误（未知参数、`pubspec.yaml` 读不出 `version`、缺少 manifest 等） |

## 行为约定（有意为之）

- **缺产物就失败，且不写半份清单**：正式收集时任何"应有却没有"的产物都让脚本以 1 退出，
  并且一个文件都不写 —— 不允许生成只覆盖一半产物的 `SHA256SUMS.txt`。
- **拷贝后重新哈希核对**：拷贝过程中产物被并行重建（exe 被覆盖）会立刻失败，而不是写出一份
  与实际要上传的文件对不上的校验和。
- **输出目录里的旧文件会被告警**：上一轮留下的产物会让"整目录上传"变成事故，脚本只提醒不删除。
- **发布说明只替换生成区块**：`generate_release_notes.mjs` 只重写
  `BEGIN GENERATED:artifacts` 与 `END GENERATED:artifacts` 两行标记之间的内容；人工段落原样保留，
  可以反复跑。目标文件已存在却没有标记时它**拒绝覆盖**（除非显式 `--force`）。
- **不编造**：脚本只写它能算出来的事实（版本、大小、SHA-256、清单时间）。亮点、升级须知、
  英文摘要这些只有人知道的内容留成 `TODO(人工)`，脚本只在最后提醒还有几处没写。

