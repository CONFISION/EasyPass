# Windows 真机验收工具（UI 驱动 + MCP 冒烟）

本目录是一套**只在本机真实运行的应用上使用**的验收工具，主要用来验证智能体访问（MCP）与审批 UI
的端到端行为。它不是自动化测试套件，不参与 `flutter test` / CI；官方门禁仍是 `flutter analyze` +
`flutter test` + `check_extension.mjs`。

## 为什么需要它

单元测试覆盖不到的东西：真实窗口/真实鼠标点击、系统剪贴板、真实 HTTP 栈、真实进程间行为
（例如"审批弹窗是否真的出现""同意后条目是否实时出现在 UI""超时后弹窗是否消失"）。
本套工具在 3.1.0 安全评审修复的真机验收中实际使用过（2026-10-28）。

CI **只做这些脚本的 PowerShell 语法检查**（见 `.github/workflows/ci.yml`），不会执行它们；
真机验收仍由人在本机按需运行。

## 前提

1. 已用 `flutter build windows` 构建并**启动** `build\windows\x64\runner\Release\easypass.exe`
   （MCP 总开关已开；`%LOCALAPPDATA%\EasyPass\daemon.json` 里有 `mcpPort`）。
2. MCP 客户端配置里已有该配对的 Bearer 密钥（默认从 DSH 配置读：
   `%USERPROFILE%\.dsh\profiles\desktop\cordis.patch.yml` 的 `Authorization` 头；可用 `-KeyFile` 指向别的文件）。
3. Windows + PowerShell 7（`pwsh`）。本机 150% DPI 的情况工具已做 DPI aware 处理。

## 文件

| 文件 | 作用 |
|---|---|
| `ui_driver.ps1` | 把 EasyPass 窗口置前、截图、按窗口坐标真实点击、滚轮、按键、读光标。 |
| `mcp_client.ps1` | 发一条已认证的 `tools/call`，结果写到 `%TEMP%\easypass-ui-probe\mcp_result.json`。 |
| `mcp_smoke.ps1` | MCP 传输层负向用例（无 Bearer/Origin/坏 Host/GET/错密钥）+ initialize/tools/list/status。 |
| `approval_button.ps1` | 截图并自动识别审批弹窗的「同意」（蓝）/「拒绝」（鲑红）按钮，真实点击。 |
| `README.md` | 本文件。 |

输出目录默认 `%TEMP%\easypass-ui-probe`，不会在仓库里留文件。

## 快速使用

```powershell
cd <repo>

# 1) 看窗口/截当前界面
pwsh -File tool\ui_probe\ui_driver.ps1 -Action info
pwsh -File tool\ui_probe\ui_driver.ps1 -Action shot -Out "$env:TEMP\before.png"

# 2) 传输层冒烟（不修改数据）
pwsh -File tool\ui_probe\mcp_smoke.ps1

# 3) 发起一次写操作（会弹审批；先别点，另开终端截图/点击）
Start-Job { pwsh -File .\tool\ui_probe\mcp_client.ps1 -Tool create_entry -ArgsJson '{"type":"secure_note","name":"ui-probe 临时条目"}' }
pwsh -File tool\ui_probe\ui_driver.ps1 -Action shot -Out "$env:TEMP\approval.png"
pwsh -File tool\ui_probe\approval_button.ps1 -Button approve

# 4) 读回结果
Get-Content "$env:TEMP\easypass-ui-probe\mcp_result.json" -Raw
```

三按钮（读操作）弹窗的中间键「本会话内允许读取」是 tonal 样式，颜色与「同意」接近，自动识别不可靠：
先 `shot` 截图，再用 `ui_driver.ps1 -Action clickwin -X <窗口内x> -Y <窗口内y>` 按坐标点。

## 安全纪律（重要）

- **真实输入**：会移动真实鼠标/前台窗口。尽量在副屏/不占用主屏时使用；脚本会先把窗口置前。
- **剪贴板**：`copy_to_clipboard` 用例会写入真实剪贴板。测试前自行备份、测试后恢复：
  `$bak = Get-Clipboard -Raw; ...; Set-Clipboard -Value $bak`（空剪贴板时 `-Raw` 可能返回 $null）。
- **用一次性条目**：写/删用例请用专门创建的测试条目（如名字带 `ui-probe`），测完在 UI 回收站里彻底删除；
  **不要**对真实条目点同意。
- **别点破坏性按钮**：本工具只点审批弹窗；"彻底删除/清空回收站"等确认框需要你手动读截图后再点。
- 密钥只在脚本内存里使用，不会打印；结果 JSON 也可能含条目元数据，用完删除。

## 已知限制

- 颜色识别针对当前 Material 3 深/浅主题的填充按钮做了通用谓词；主题大改后需重新校准
  `approval_button.ps1` 里的 `isApprove` / `isDeny` 判定。
- 只支持 Windows；窗口最小化/被其它窗口完全遮挡时先 `-Action focus`。
- MCP 端点固定 47821；core 未启动/端口被占时 `mcp_smoke.ps1` 会快速失败并给出状态码。
- 本工具不替代 `flutter test`；它验证的是"真机集成行为"，用例可重复但需要人工判断截图。
