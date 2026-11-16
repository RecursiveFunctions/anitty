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

public static class SplitTestNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int left, top, right, bottom;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PostMessageW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam);

    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const uint VK_F4 = 0x73;
    public const uint VK_F5 = 0x74;
    public const uint VK_F6 = 0x75;
    public const uint VK_F7 = 0x76;
    public const uint VK_F8 = 0x77;
    public const uint VK_F9 = 0x78;
    public const uint VK_F10 = 0x79;

    public static string ClassName(IntPtr hWnd) {
        var sb = new StringBuilder(256);
        GetClassNameW(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static List<IntPtr> VisibleSurfaces(IntPtr parent, uint expectedPid) {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, (hWnd, _) => {
            uint pid = 0;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid == expectedPid &&
                IsWindowVisible(hWnd) &&
                string.Equals(ClassName(hWnd), "AnittySurface", StringComparison.OrdinalIgnoreCase))
            {
                list.Add(hWnd);
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
"@

function Send-Vk([IntPtr]$Hwnd, [uint32]$ExpectedPid, [uint32]$Vk) {
    if ($Hwnd -eq [IntPtr]::Zero) { throw 'Target surface HWND is zero' }
    [uint32]$pidOut = 0
    [void][SplitTestNative]::GetWindowThreadProcessId($Hwnd, [ref]$pidOut)
    if ($pidOut -ne $ExpectedPid) {
        throw "HWND owned by PID $pidOut, expected $ExpectedPid"
    }
    [void][SplitTestNative]::PostMessageW($Hwnd, [SplitTestNative]::WM_KEYDOWN, [UIntPtr]::new($Vk), [IntPtr]::Zero)
    [void][SplitTestNative]::PostMessageW($Hwnd, [SplitTestNative]::WM_KEYUP, [UIntPtr]::new($Vk), [IntPtr]::Zero)
}

$proc = Start-Process -FilePath $GhosttyExe -ArgumentList @(
    '--config-default-files=false',
    '--confirm-close-surface=false',
    '--keybind=f9=new_split:right',
    '--keybind=f10=new_split:down',
    '--keybind=f7=goto_split:previous',
    '--keybind=f8=goto_split:next',
    '--keybind=f6=toggle_split_zoom',
    '--keybind=f5=equalize_splits',
    '--keybind=f4=close_surface'
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
    Start-Sleep -Milliseconds 500

    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 1) { throw "Expected 1 initial visible AnittySurface, got $($vis.Count)" }

    Write-Host '[TEST] Creating right split (1 -> 2 visible surfaces)'
    Send-Vk -Hwnd $vis[0] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F9)
    Start-Sleep -Milliseconds 600
    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 2) { throw "Expected 2 visible surfaces after new_split:right, got $($vis.Count)" }

    $r0 = New-Object SplitTestNative+RECT
    $r1 = New-Object SplitTestNative+RECT
    [void][SplitTestNative]::GetWindowRect($vis[0], [ref]$r0)
    [void][SplitTestNative]::GetWindowRect($vis[1], [ref]$r1)
    if ($r0.left -eq $r1.left -and $r0.right -eq $r1.right) {
        throw 'Expected horizontal split surfaces to have distinct horizontal rects'
    }

    Write-Host '[TEST] Creating down split (2 -> 3 visible surfaces)'
    Send-Vk -Hwnd $vis[1] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F10)
    Start-Sleep -Milliseconds 600
    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 3) { throw "Expected 3 visible surfaces after new_split:down, got $($vis.Count)" }

    Write-Host '[TEST] Toggling split zoom hides non-zoomed sibling surfaces'
    Send-Vk -Hwnd $vis[2] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F6)
    Start-Sleep -Milliseconds 300
    $zoomedVis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($zoomedVis.Count -ne 1) { throw "Expected 1 visible surface while split zoomed, got $($zoomedVis.Count)" }

    Write-Host '[TEST] Unzooming and equalizing splits restores 3 visible surfaces'
    Send-Vk -Hwnd $zoomedVis[0] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F6)
    Start-Sleep -Milliseconds 300
    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 3) { throw "Expected 3 visible surfaces after unzoom, got $($vis.Count)" }
    Send-Vk -Hwnd $vis[0] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F5)
    Start-Sleep -Milliseconds 200

    Write-Host '[TEST] Closing split panes returns cleanly to 1 surface'
    Send-Vk -Hwnd $vis[2] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F4)
    Start-Sleep -Milliseconds 400
    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 2) { throw "Expected 2 visible surfaces after closing 1 split, got $($vis.Count)" }

    Send-Vk -Hwnd $vis[1] -ExpectedPid $expectedPid -Vk ([SplitTestNative]::VK_F4)
    Start-Sleep -Milliseconds 400
    $vis = [SplitTestNative]::VisibleSurfaces($winHwnd, $expectedPid)
    if ($vis.Count -ne 1) { throw "Expected 1 visible surface after closing second split, got $($vis.Count)" }

    Write-Host 'All Win32 split tests passed.'
} finally {
    if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    }
}
