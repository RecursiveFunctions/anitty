param(
    [string]$GhosttyExe = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'zig-out/bin/anitty.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $GhosttyExe)) {
    throw "anitty.exe not found at $GhosttyExe"
}

Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;

public static class Win32ResizeTest {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int left, top, right, bottom;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, UIntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);

    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOZORDER = 0x0004;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SMTO_ABORTIFHUNG = 0x0002;
    public const uint WM_NULL = 0x0000;
}
"@

function Assert-OwnedWindow([IntPtr]$Hwnd, [int]$ExpectedPid) {
    if ($Hwnd -eq [IntPtr]::Zero) { throw 'HWND is zero' }
    [uint32]$ownerPid = 0
    [void][Win32ResizeTest]::GetWindowThreadProcessId($Hwnd, [ref]$ownerPid)
    if ([int]$ownerPid -ne $ExpectedPid) {
        throw "HWND 0x$($Hwnd.ToString('X')) belongs to PID $ownerPid, expected $ExpectedPid"
    }
}

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ghostty-resize-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
$childScript = Join-Path $tempDir 'child.ps1'
$readyFile = Join-Path $tempDir 'ready.txt'
$stepFile = Join-Path $tempDir 'step.txt'
$doneFile = Join-Path $tempDir 'done.txt'

@"
`$ErrorActionPreference = 'Stop'
Set-Content -LiteralPath '$readyFile' -Value 'ready'
while (-not (Test-Path -LiteralPath '$stepFile')) { Start-Sleep -Milliseconds 30 }
[Console]::Write("`$([char]27)[8;36;110t")
Set-Content -LiteralPath '$doneFile' -Value 'sent'
Start-Sleep -Seconds 30
"@ | Set-Content -LiteralPath $childScript -Encoding UTF8

function Run-ResizeScenario([bool]$AllowResize) {
    Remove-Item -LiteralPath $readyFile, $stepFile, $doneFile -ErrorAction SilentlyContinue
    $flag = if ($AllowResize) { 'true' } else { 'false' }
    $proc = Start-Process -FilePath $GhosttyExe -ArgumentList @(
        '--config-default-files=false',
        '--window-step-resize=false',
        "--vt-window-resize-allowed=$flag",
        "-e",
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $childScript
    ) -PassThru

    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline) {
            $proc.Refresh()
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero -and (Test-Path -LiteralPath $readyFile)) { break }
            Start-Sleep -Milliseconds 50
        }
        $hwnd = $proc.MainWindowHandle
        Assert-OwnedWindow -Hwnd $hwnd -ExpectedPid $proc.Id

        $before = New-Object Win32ResizeTest+RECT
        [void][Win32ResizeTest]::GetWindowRect($hwnd, [ref]$before)
        $bw = $before.right - $before.left
        $bh = $before.bottom - $before.top

        Set-Content -LiteralPath $stepFile -Value 'go'
        while (-not (Test-Path -LiteralPath $doneFile) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 40
        }
        Start-Sleep -Milliseconds 250

        $after = New-Object Win32ResizeTest+RECT
        [void][Win32ResizeTest]::GetWindowRect($hwnd, [ref]$after)
        $aw = $after.right - $after.left
        $ah = $after.bottom - $after.top

        if (-not $AllowResize) {
            if ($aw -ne $bw -or $ah -ne $bh) {
                throw "Window resized despite vt-window-resize-allowed=false: ${bw}x${bh} -> ${aw}x${ah}"
            }
        } else {
            if ($aw -eq $bw -and $ah -eq $bh) {
                throw "Window did not resize when vt-window-resize-allowed=true: ${bw}x${bh} -> ${aw}x${ah}"
            }
        }

        # Host-driven non-activating resize via SetWindowPos
        $targetW = $aw + 80
        $targetH = $ah + 60
        [void][Win32ResizeTest]::SetWindowPos(
            $hwnd,
            [IntPtr]::Zero,
            0,
            0,
            $targetW,
            $targetH,
            [Win32ResizeTest]::SWP_NOMOVE -bor [Win32ResizeTest]::SWP_NOZORDER -bor [Win32ResizeTest]::SWP_NOACTIVATE
        )
        Start-Sleep -Milliseconds 150

        [UIntPtr]$msgRes = [UIntPtr]::Zero
        $ping = [Win32ResizeTest]::SendMessageTimeoutW(
            $hwnd,
            [Win32ResizeTest]::WM_NULL,
            [UIntPtr]::Zero,
            [IntPtr]::Zero,
            [Win32ResizeTest]::SMTO_ABORTIFHUNG,
            2000,
            [ref]$msgRes
        )
        if ($ping -eq [IntPtr]::Zero) {
            throw 'AnittyWindow did not respond to SendMessageTimeoutW after resize'
        }
    } finally {
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Write-Host '[TEST] CSI 8;r;c t blocked when vt-window-resize-allowed=false'
    Run-ResizeScenario -AllowResize $false
    Write-Host '[TEST] CSI 8;r;c t and host SetWindowPos when vt-window-resize-allowed=true'
    Run-ResizeScenario -AllowResize $true
    Write-Host 'All program resize tests passed.'
} finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
