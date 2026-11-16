param(
    [string]$GhosttyExe = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'zig-out/bin/anitty.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $GhosttyExe)) {
    throw "anitty.exe not found at $GhosttyExe"
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class TabBarTestNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int left, top, right, bottom;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SetWindowTextW(IntPtr hWnd, string lpString);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetDpiForWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_LBUTTONUP = 0x0202;
    public const uint WM_LBUTTONDBLCLK = 0x0203;
    public const uint MK_LBUTTON = 0x0001;
    public const uint VK_RETURN = 0x0D;
    public const uint VK_F8 = 0x77;

    public static IntPtr MakeLParam(int x, int y) {
        int packed = ((y & 0xFFFF) << 16) | (x & 0xFFFF);
        return new IntPtr(packed);
    }

    public static string ClassName(IntPtr hWnd) {
        var sb = new StringBuilder(256);
        GetClassNameW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string WindowText(IntPtr hWnd) {
        var sb = new StringBuilder(512);
        GetWindowTextW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<IntPtr> FindChildren(IntPtr parent, string className, uint expectedPid) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, (hWnd, _) => {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == expectedPid && string.Equals(ClassName(hWnd), className, StringComparison.OrdinalIgnoreCase)) {
                list.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
"@

function Assert-Owned([IntPtr]$Hwnd, [uint32]$ExpectedPid) {
    if ($Hwnd -eq [IntPtr]::Zero) { throw 'Target HWND is zero' }
    [uint32]$pidOut = 0
    [void][TabBarTestNative]::GetWindowThreadProcessId($Hwnd, [ref]$pidOut)
    if ($pidOut -ne $ExpectedPid) {
        throw "HWND 0x$($Hwnd.ToString('X')) owned by PID $pidOut, expected $ExpectedPid"
    }
}

function Get-TabLayout([IntPtr]$TabBarHwnd, [int]$Count) {
    $rect = New-Object TabBarTestNative+RECT
    [void][TabBarTestNative]::GetClientRect($TabBarHwnd, [ref]$rect)
    $dpi = [int][TabBarTestNative]::GetDpiForWindow($TabBarHwnd)
    $h = $rect.bottom - $rect.top
    $avail = [Math]::Max(0, ($rect.right - $rect.left) - $h)
    $n = [Math]::Max($Count, 1)
    $minW = [int][Math]::Truncate((48 * $dpi) / 96)
    $maxW = [int][Math]::Truncate((240 * $dpi) / 96)
    $rawW = [int][Math]::Truncate($avail / $n)
    $tabW = [Math]::Min([Math]::Max($rawW, $minW), $maxW)
    return [pscustomobject]@{
        TabWidth = $tabW
        Height   = $h
        Dpi      = $dpi
        Count    = $Count
    }
}

function Click-ClientPoint([IntPtr]$Hwnd, [uint32]$Pid, [int]$X, [int]$Y) {
    Assert-Owned -Hwnd $Hwnd -ExpectedPid $Pid
    $lp = [TabBarTestNative]::MakeLParam($X, $Y)
    [void][TabBarTestNative]::PostMessageW($Hwnd, [TabBarTestNative]::WM_LBUTTONDOWN, [UIntPtr]::new([TabBarTestNative]::MK_LBUTTON), $lp)
    [void][TabBarTestNative]::PostMessageW($Hwnd, [TabBarTestNative]::WM_LBUTTONUP, [UIntPtr]::Zero, $lp)
}

function DoubleClick-ClientPoint([IntPtr]$Hwnd, [uint32]$Pid, [int]$X, [int]$Y) {
    Assert-Owned -Hwnd $Hwnd -ExpectedPid $Pid
    $lp = [TabBarTestNative]::MakeLParam($X, $Y)
    [void][TabBarTestNative]::PostMessageW($Hwnd, [TabBarTestNative]::WM_LBUTTONDBLCLK, [UIntPtr]::new([TabBarTestNative]::MK_LBUTTON), $lp)
    [void][TabBarTestNative]::PostMessageW($Hwnd, [TabBarTestNative]::WM_LBUTTONUP, [UIntPtr]::Zero, $lp)
}

$proc = Start-Process -FilePath $GhosttyExe -ArgumentList @(
    '--config-default-files=false',
    '--confirm-close-surface=false',
    '--window-show-tab-bar=always',
    '--keybind=f8=new_tab'
) -PassThru

try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while ([DateTime]::UtcNow -lt $deadline) {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 50
    }
    $winHwnd = $proc.MainWindowHandle
    $expectedPid = [uint32]$proc.Id
    Assert-Owned -Hwnd $winHwnd -ExpectedPid $expectedPid
    Start-Sleep -Milliseconds 500

    $tabBars = [TabBarTestNative]::FindChildren($winHwnd, 'AnittyTabBar', $expectedPid)
    if ($tabBars.Count -ne 1) { throw "Expected 1 AnittyTabBar child, found $($tabBars.Count)" }
    $tabBarHwnd = $tabBars[0]

    $surfaces = [TabBarTestNative]::FindChildren($winHwnd, 'AnittySurface', $expectedPid)
    if ($surfaces.Count -lt 1) { throw 'Expected initial AnittySurface child' }

    Write-Host '[TEST] Creating second tab via F8 keybinding on AnittySurface'
    $activeSurf = $surfaces | Where-Object { [TabBarTestNative]::IsWindowVisible($_) } | Select-Object -First 1
    Assert-Owned -Hwnd $activeSurf -ExpectedPid $expectedPid
    [void][TabBarTestNative]::PostMessageW($activeSurf, [TabBarTestNative]::WM_KEYDOWN, [UIntPtr]::new([TabBarTestNative]::VK_F8), [IntPtr]::Zero)
    [void][TabBarTestNative]::PostMessageW($activeSurf, [TabBarTestNative]::WM_KEYUP, [UIntPtr]::new([TabBarTestNative]::VK_F8), [IntPtr]::Zero)
    Start-Sleep -Milliseconds 600

    $surfaces = [TabBarTestNative]::FindChildren($winHwnd, 'AnittySurface', $expectedPid)
    if ($surfaces.Count -ne 2) { throw "Expected 2 AnittySurface children after F8, got $($surfaces.Count)" }

    Write-Host '[TEST] Creating third tab via + button on AnittyTabBar'
    $layout2 = Get-TabLayout -TabBarHwnd $tabBarHwnd -Count 2
    $plusX = ($layout2.TabWidth * 2) + [int]($layout2.Height / 2)
    $plusY = [int]($layout2.Height / 2)
    Click-ClientPoint -Hwnd $tabBarHwnd -Pid $expectedPid -X $plusX -Y $plusY
    Start-Sleep -Milliseconds 600

    $surfaces = [TabBarTestNative]::FindChildren($winHwnd, 'AnittySurface', $expectedPid)
    if ($surfaces.Count -ne 3) { throw "Expected 3 AnittySurface children after + click, got $($surfaces.Count)" }

    Write-Host '[TEST] Double-click inline tab rename on Tab 0'
    $layout3 = Get-TabLayout -TabBarHwnd $tabBarHwnd -Count 3
    $tab0CenterX = [int]($layout3.TabWidth / 3)
    $tab0CenterY = [int]($layout3.Height / 2)
    Click-ClientPoint -Hwnd $tabBarHwnd -Pid $expectedPid -X $tab0CenterX -Y $tab0CenterY
    Start-Sleep -Milliseconds 200
    DoubleClick-ClientPoint -Hwnd $tabBarHwnd -Pid $expectedPid -X $tab0CenterX -Y $tab0CenterY
    Start-Sleep -Milliseconds 200

    $edits = [TabBarTestNative]::FindChildren($tabBarHwnd, 'Edit', $expectedPid)
    if ($edits.Count -ne 1) { throw "Expected 1 Edit child inside AnittyTabBar, found $($edits.Count)" }
    $editHwnd = $edits[0]
    if (-not [TabBarTestNative]::IsWindowVisible($editHwnd)) {
        throw 'Expected inline rename Edit control to be visible after double-click'
    }
    [void][TabBarTestNative]::SetWindowTextW($editHwnd, 'CustomRenamedTab')
    [void][TabBarTestNative]::SendMessageW($editHwnd, [TabBarTestNative]::WM_KEYDOWN, [UIntPtr]::new([TabBarTestNative]::VK_RETURN), [IntPtr]::Zero)
    Start-Sleep -Milliseconds 250

    $winTitle = [TabBarTestNative]::WindowText($winHwnd)
    if (-not $winTitle.Contains('CustomRenamedTab')) {
        throw "Expected window title to reflect renamed active tab 'CustomRenamedTab', got '$winTitle'"
    }

    Write-Host '[TEST] Closing Tab 2 via close button on AnittyTabBar'
    $closeSize = [int][Math]::Truncate((16 * $layout3.Dpi) / 96)
    $tabPad = [int][Math]::Truncate((10 * $layout3.Dpi) / 96)
    $glyphSize = [int][Math]::Truncate((8 * $layout3.Dpi) / 96)
    $tab2Right = $layout3.TabWidth * 3
    $closeRight = $tab2Right - $tabPad + [int][Math]::Truncate(($closeSize - $glyphSize) / 2)
    $closeCenterX = $closeRight - [int]($closeSize / 2)
    $closeCenterY = [int]($layout3.Height / 2)
    Click-ClientPoint -Hwnd $tabBarHwnd -Pid $expectedPid -X $closeCenterX -Y $closeCenterY
    Start-Sleep -Milliseconds 500

    Write-Host 'All Win32 tab bar tests passed.'
} finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}
