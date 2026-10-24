# installer/languages —— 随仓库分发的 Inno Setup 语言文件

## 为什么放在仓库里

Inno Setup 的**官方安装包只带少数官方语言**；**简体中文属于"非官方翻译"
（Unofficial Translations）**，不在安装包里。于是：

- 本机装了 Inno Setup 7 且手动放过翻译文件 → `compiler:Languages\ChineseSimplified.isl` 能编过；
- CI 上用 `choco install innosetup` 装出来的 `Languages\` 目录里**没有**这个文件
  → `Error on line 92: Couldn't open include file "...\ChineseSimplified.isl"`，
  整个 Release 流程中止（2026-10-18 实测）。

把 `.isl` 随仓库分发，本地与 CI 就用**同一份**翻译，不再依赖"机器上装没装中文"。

## 文件来源

| 项 | 值 |
| --- | --- |
| 文件 | `ChineseSimplified.isl`（21 KB，UTF-8 **带 BOM**） |
| 文件头标注 | `; *** Inno Setup version 6.5.0+ Chinese Simplified messages ***` |
| 维护者 | Zhenghan Yang (Kira) — <https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation> |
| 取自 | Inno Setup 官方发行包 `Languages\ChineseSimplified.isl`（本机 Inno Setup 7 的副本） |
| 兼容性 | 6.5.0+，即 **Inno Setup 6 与 7 都能用** |

## 编码要求（重要）

**必须是 UTF-8 带 BOM。** 无 BOM 时 Inno Setup 会按系统 ANSI（本机 936/GBK）解码，
中文会变成乱码。CI 的 `Assert vendored Chinese language file` 步骤会检查这三字节
（`EF BB BF`），不满足就明确失败。

## 在 `.iss` 里的用法

`installer/easypass_setup.iss` 的 `[Languages]` 段用的是 **条件 include**：

```iss
#define ChineseIsl AddBackslash(SourcePath) + "languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(ChineseIsl)
Name: "chinesesimplified"; MessagesFile: "{#ChineseIsl}"
#endif
```

- 文件在 → 安装向导有简体中文可选；
- 文件不在 → **退化为只有英文，仍能编译**（本地开发不必为了打个包去装翻译）。
  CI 上则会被断言拦住，因为**发布产物必须带中文**。

## 更新方式

Inno Setup 升级后（例如 7.x 新版新增了消息键），把新版发行包里的
`Languages\ChineseSimplified.isl` 覆盖到这里即可，记得**确认仍带 BOM**。
若将来新增语言，同样放在本目录并按上面的模式加 `#if` 分支。
