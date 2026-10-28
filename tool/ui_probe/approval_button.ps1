# 截屏并自动识别审批弹窗的「同意」(蓝) / 「拒绝」(鲑红) 按钮，然后用真实鼠标点击。
#
# 说明：这是启发式颜色识别（Material 3 填充按钮），针对 3.1.0 的深/浅主题做过校准；
# 三按钮读操作的中间键「本会话内允许读取」是 tonal 样式，自动识别不可靠 ——
# 先用 ui_driver.ps1 -Action shot 截图，再用 -Action clickwin -X <x> -Y <y> 手动点。
param(
    [Parameter(Mandatory = $true)][ValidateSet('approve', 'deny')][string]$Button,
    [string]$ProcessName = 'easypass',
    [string]$Shot = '',
    [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class EasyPassApprovalClicker {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
[EasyPassApprovalClicker]::SetProcessDPIAware() | Out-Null
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'easypass-ui-probe' }
New-Item -ItemType Directory -Force $OutDir | Out-Null
if (-not $Shot) { $Shot = Join-Path $OutDir ("approval_{0}.png" -f $Button) }

$proc = Get-Process $ProcessName -ErrorAction Stop | Select-Object -First 1
$hwnd = $proc.MainWindowHandle
[EasyPassApprovalClicker]::ShowWindow($hwnd, 9) | Out-Null
[EasyPassApprovalClicker]::SetForegroundWindow($hwnd) | Out-Null
if ([EasyPassApprovalClicker]::GetForegroundWindow() -ne $hwnd) {
    [EasyPassApprovalClicker]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
    [EasyPassApprovalClicker]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [EasyPassApprovalClicker]::SetForegroundWindow($hwnd) | Out-Null
}
Start-Sleep -Milliseconds 300

$rect = New-Object EasyPassApprovalClicker+RECT
[EasyPassApprovalClicker]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
$bmp.Save($Shot, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose()

function Test-ApproveColor([System.Drawing.Color]$c) {
    return (($c.B -gt 120) -and (($c.B - $c.R) -gt 25) -and (($c.B - $c.G) -gt 10))
}
function Test-DenyColor([System.Drawing.Color]$c) {
    return (($c.R -gt 140) -and (($c.R - $c.G) -gt 35) -and (($c.R - $c.B) -gt 25))
}

# 在窗口下半部横向扫描，找按钮色块（面积足够大的连续段）
$candidates = @()
for ($y = [int]($h * 0.62); $y -lt [int]($h * 0.95); $y += 3) {
    $x = [int]($w * 0.20)
    while ($x -lt [int]($w * 0.90)) {
        $c = $bmp.GetPixel($x, $y)
        $match = if ($Button -eq 'approve') { Test-ApproveColor $c } else { Test-DenyColor $c }
        if ($match) {
            $x0 = $x
            while ($x -lt [int]($w * 0.90)) {
                $c2 = $bmp.GetPixel($x, $y)
                $m2 = if ($Button -eq 'approve') { Test-ApproveColor $c2 } else { Test-DenyColor $c2 }
                if (-not $m2) { break }
                $x++
            }
            if (($x - $x0) -ge 55) {
                $candidates += [pscustomobject]@{
                    Y = $y; X0 = $x0; X1 = $x - 1
                    CX = [int](($x0 + $x - 1) / 2); CY = $y
                }
            }
        } else { $x++ }
    }
}
$bmp.Dispose()
if ($candidates.Count -eq 0) {
    throw "未找到 $Button 按钮（截图：$Shot）。弹窗可能不存在，或主题配色已变化。"
}

# 按 x 聚合候选；同意取最左、拒绝取最右（三按钮弹窗中间键是 tonal，可能被误判为 approve）
$clusters = $candidates | Group-Object { [int]($_.CX / 40) }
$best = if ($Button -eq 'approve') {
    $clusters | Sort-Object { ($_.Group | Measure-Object CX -Minimum).Minimum } | Select-Object -First 1
} else {
    $clusters | Sort-Object { ($_.Group | Measure-Object CX -Maximum).Maximum } -Descending | Select-Object -First 1
}
$cx = [int](($best.Group | Measure-Object CX -Average).Average)
$cy = [int](($best.Group | Measure-Object CY -Average).Average)

$old = New-Object EasyPassApprovalClicker+POINT
[EasyPassApprovalClicker]::GetCursorPos([ref]$old) | Out-Null
[EasyPassApprovalClicker]::SetCursorPos(($rect.Left + $cx), ($rect.Top + $cy)) | Out-Null
Start-Sleep -Milliseconds 120
[EasyPassApprovalClicker]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[EasyPassApprovalClicker]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 250
[EasyPassApprovalClicker]::SetCursorPos($old.X, $old.Y) | Out-Null
Write-Host ("clicked {0} window=({1},{2}) screen=({3},{4}) shot={5}" -f `
    $Button, $cx, $cy, ($rect.Left + $cx), ($rect.Top + $cy), $Shot)
