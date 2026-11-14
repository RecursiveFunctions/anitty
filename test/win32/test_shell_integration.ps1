Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $repoRoot 'src/shell-integration/powershell/ghostty.ps1'

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "Shell integration script not found at $scriptPath"
}

function Invoke-IsolatedCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    Write-Host "[TEST] $Name"
    & $Body
}

function Capture-ConsoleAndPrompt {
    $origOut = [Console]::Out
    $sw = [System.IO.StringWriter]::new()
    try {
        [Console]::SetOut($sw)
        $promptRet = & global:prompt
        $written = $sw.ToString()
        return [pscustomobject]@{
            ConsoleOut = $written
            PromptRet  = [string]$promptRet
            Combined   = ($written + [string]$promptRet)
        }
    } finally {
        [Console]::SetOut($origOut)
        $sw.Dispose()
    }
}

function Reset-GhosttyIntegration {
    param(
        [string]$Features = 'cursor,path,title'
    )
    Remove-Variable -Name __GhosttyState -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -Path Function:global:ssh -ErrorAction SilentlyContinue
    Remove-Item -Path Function:global:PSConsoleHostReadLine -ErrorAction SilentlyContinue
    function global:prompt { 'PS> ' }
    $env:GHOSTTY_SHELL_INTEGRATION_NO_PWSH = $null
    $env:TERM_PROGRAM = 'ghostty'
    $env:GHOSTTY_SHELL_FEATURES = $Features
    . $scriptPath
}

Invoke-IsolatedCase -Name 'Prompt markers, OSC 7 CWD URL, OSC 2 title, and blinking cursor' -Body {
    Reset-GhosttyIntegration -Features 'cursor,path,title'
    $res = Capture-ConsoleAndPrompt
    $esc = [string][char]27
    $bel = [string][char]7

    if (-not $res.PromptRet.Contains("$esc]133;A;redraw=0$bel")) {
        throw "Expected OSC 133;A;redraw=0 marker in prompt output"
    }
    if (-not $res.PromptRet.Contains("$esc]133;B$bel")) {
        throw "Expected OSC 133;B marker in prompt output"
    }
    if (-not $res.ConsoleOut.Contains("$esc[5 q")) {
        throw "Expected blinking bar cursor sequence DECSCUSR 5"
    }
    if (-not $res.ConsoleOut.Contains("$esc]7;file://")) {
        throw "Expected OSC 7 working directory URL"
    }
    if (-not $res.ConsoleOut.Contains("$esc]2;")) {
        throw "Expected OSC 2 window title sequence"
    }
}

Invoke-IsolatedCase -Name 'Steady cursor feature (cursor:steady -> DECSCUSR 6)' -Body {
    Reset-GhosttyIntegration -Features 'cursor:steady,title'
    $res = Capture-ConsoleAndPrompt
    $esc = [string][char]27
    if (-not $res.ConsoleOut.Contains("$esc[6 q")) {
        throw "Expected steady bar cursor sequence DECSCUSR 6"
    }
}

Invoke-IsolatedCase -Name 'PSConsoleHostReadLine preexec OSC 133;C and command exit code OSC 133;D' -Body {
    function global:PSConsoleHostReadLine { "echo `"hello`"" }
    Reset-GhosttyIntegration -Features 'cursor,title'

    # First prompt wraps PSConsoleHostReadLine
    $null = Capture-ConsoleAndPrompt

    $origOut = [Console]::Out
    $sw = [System.IO.StringWriter]::new()
    try {
        [Console]::SetOut($sw)
        $line = & global:PSConsoleHostReadLine
        $preexec = $sw.ToString()
    } finally {
        [Console]::SetOut($origOut)
        $sw.Dispose()
    }

    $esc = [string][char]27
    $bel = [string][char]7
    if ($line -ne 'echo "hello"') {
        throw "Expected wrapped PSConsoleHostReadLine to return input line"
    }
    if (-not $preexec.Contains("$esc]133;C;$bel")) {
        throw "Expected preexec to emit OSC 133;C"
    }
    if (-not $preexec.Contains("$esc[0 q")) {
        throw "Expected preexec to reset cursor with DECSCUSR 0"
    }

    # Simulate failed native command with LASTEXITCODE = 42 immediately before prompt
    $origOut = [Console]::Out
    $sw = [System.IO.StringWriter]::new()
    try {
        [Console]::SetOut($sw)
        cmd.exe /c "exit 42" 2>$null
        $null = & global:prompt
        $postexec = $sw.ToString()
    } finally {
        [Console]::SetOut($origOut)
        $sw.Dispose()
    }
    if (-not $postexec.Contains("$esc]133;D;42$bel")) {
        throw "Expected postexec prompt to emit OSC 133;D;42, got: $postexec"
    }
    if ($global:LASTEXITCODE -ne 42) {
        throw "Expected LASTEXITCODE to be preserved as 42, got $global:LASTEXITCODE"
    }
}

Invoke-IsolatedCase -Name 'SSH wrapper registration when ssh-env or ssh-terminfo is enabled' -Body {
    Reset-GhosttyIntegration -Features 'ssh-env,ssh-terminfo'
    if (-not (Test-Path -Path Function:global:ssh)) {
        throw "Expected global:ssh function to be defined when ssh features are enabled"
    }
}

Write-Host 'All PowerShell shell integration checks passed.'
