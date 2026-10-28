# EasyPass 真机 UI 驱动：窗口置前 / 截图 / 真实鼠标键盘（SendInput）。
#
# 只在本地真实运行的应用上使用；不参与 flutter test / CI。
# 用法（在仓库根目录）：
#   pwsh -File tool\ui_probe\ui_driver.ps1 -Action info
#   pwsh -File tool\ui_probe\ui_driver.ps1 -Action shot -Out "$env:TEMP\shot.png"
#   pwsh -File tool\ui_probe\ui_driver.ps1 -Action clickwin -X 1165 -Y 800   # 窗口内坐标
#   pwsh -File tool\ui_probe\ui_driver.ps1 -Action wheel -Delta -720
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('info', 'focus', 'shot', 'clickwin', 'wheel', 'key', 'cursor')]
    [string]$Action,
    [string]$Out = '',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$Delta = -120,
    [int]$Vk = 0,
    [string]$ProcessName = 'easypass'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class EasyPassUiDriver {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
}
"@
[EasyPassUiDriver]::SetProcessDPIAware() | Out-Null

$outDir = Join-Path $env:TEMP 'easypass-ui-probe'
New-Item -ItemType Directory -Force $outDir | Out-Null

$proc = Get-Process $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $proc) { throw "进程不存在：$ProcessName（先启动 Release 构建）" }
$hwnd = $proc.MainWindowHandle
if ($hwnd -eq [IntPtr]::Zero) { throw '拿不到主窗口句柄（窗口可能尚未创建）' }
$rect = New-Object EasyPassUiDriver+RECT
[EasyPassUiDriver]::GetWindowRect($hwnd, [ref]$rect) | Out-Null

function Focus-EasyPass {
    [EasyPassUiDriver]::ShowWindow($hwnd, 9) | Out-Null          # SW_RESTORE
    Start-Sleep -Milliseconds 120
    [EasyPassUiDriver]::SetForegroundWindow($hwnd) | Out-Null
    Start-Sleep -Milliseconds 120
    if ([EasyPassUiDriver]::GetForegroundWindow() -ne $hwnd) {
        # 前台锁：按一下 Alt 再抢（Windows 常见 workaround）
        [EasyPassUiDriver]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
        [EasyPassUiDriver]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 80
        [EasyPassUiDriver]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 150
    }
    return ([EasyPassUiDriver]::GetForegroundWindow() -eq $hwnd)
}

function Save-WindowShot([string]$path) {
    [EasyPassUiDriver]::ShowWindow($hwnd, 9) | Out-Null
    if (-not (Focus-EasyPass)) { Write-Host 'WARN: 无法把 EasyPass 置前，截图可能被遮挡' }
    Start-Sleep -Milliseconds 250
    [EasyPassUiDriver]::GetWindowRect($hwnd, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    $fg = [EasyPassUiDriver]::GetForegroundWindow() -eq $hwnd
    Write-Host ("saved {0} ({1}x{2}) at ({3},{4}) foregroundIsApp={5}" -f $path, $w, $h, $rect.Left, $rect.Top, $fg)
}

switch ($Action) {
    'info' {
        Write-Host ("hwnd={0} title='{1}' rect=({2},{3})-({4},{5}) size={6}x{7}" -f `
            $hwnd, $proc.MainWindowTitle, $rect.Left, $rect.Top, $rect.Right, $rect.Bottom,
            ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
    }
    'focus' {
        $ok = Focus-EasyPass
        Write-Host ("focus={0} foregroundIsApp={1}" -f $proc.MainWindowTitle, $ok)
    }
    'shot' {
        if (-not $Out) { $Out = Join-Path $outDir 'shot.png' }
        Save-WindowShot $Out
    }
    'clickwin' {
        # 坐标是窗口内像素（截图坐标），自动加窗口原点
        $ax = $rect.Left + $X
        $ay = $rect.Top + $Y
        $old = New-Object EasyPassUiDriver+POINT
        [EasyPassUiDriver]::GetCursorPos([ref]$old) | Out-Null
        [EasyPassUiDriver]::SetCursorPos($ax, $ay) | Out-Null
        Start-Sleep -Milliseconds 150
        [EasyPassUiDriver]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)  # 左键按下
        Start-Sleep -Milliseconds 90
        [EasyPassUiDriver]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)  # 左键抬起
        Start-Sleep -Milliseconds 300
        [EasyPassUiDriver]::SetCursorPos($old.X, $old.Y) | Out-Null
        Write-Host ("clicked window({0},{1}) => screen({2},{3}); cursor restored ({4},{5})" -f `
            $X, $Y, $ax, $ay, $old.X, $old.Y)
    }
    'wheel' {
        $old = New-Object EasyPassUiDriver+POINT
        [EasyPassUiDriver]::GetCursorPos([ref]$old) | Out-Null
        # 滚轮作用在鼠标位置：先把鼠标放到窗口中心
        [EasyPassUiDriver]::SetCursorPos($rect.Left + [int](($rect.Right - $rect.Left) / 2),
            $rect.Top + [int](($rect.Bottom - $rect.Top) / 2)) | Out-Null
        Start-Sleep -Milliseconds 100
        [EasyPassUiDriver]::mouse_event(0x0800, 0, 0, [uint32]([int64]4294967296 + $Delta), [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 350
        [EasyPassUiDriver]::SetCursorPos($old.X, $old.Y) | Out-Null
        Write-Host ("wheel delta={0}" -f $Delta)
    }
    'key' {
        if ($Vk -le 0) { throw '需要 -Vk（虚拟键码，例如 0x1B=Esc、0x0D=Enter）' }
        [EasyPassUiDriver]::keybd_event([byte]$Vk, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 80
        [EasyPassUiDriver]::keybd_event([byte]$Vk, 0, 2, [UIntPtr]::Zero)
        Write-Host ("key vk={0} (0x{0:X})" -f $Vk)
    }
    'cursor' {
        $p = New-Object EasyPassUiDriver+POINT
        [EasyPassUiDriver]::GetCursorPos([ref]$p) | Out-Null
        Write-Host ("cursor=({0},{1})" -f $p.X, $p.Y)
    }
}
