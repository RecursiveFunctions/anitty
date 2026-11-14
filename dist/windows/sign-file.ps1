[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [string]$TimestampServer = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $FilePath)) {
    throw "File to sign does not exist: $FilePath"
}
$FilePath = (Resolve-Path -LiteralPath $FilePath).Path

$hasAzureSigning = (
    -not [string]::IsNullOrWhiteSpace($env:AZURE_SIGNING_ENDPOINT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_SIGNING_ACCOUNT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CERT_PROFILE)
)
$hasPfxSigning = -not [string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_BASE64)

if (-not $hasAzureSigning -and -not $hasPfxSigning) {
    Write-Host "Skipping Authenticode signing for '$FilePath' (neither Azure Trusted Signing nor WINDOWS_PFX_BASE64 is configured)."
    if ($env:GITHUB_ENV -and -not $env:CODESIGNED) {
        [IO.File]::AppendAllText($env:GITHUB_ENV, "CODESIGNED=false`n")
    }
    exit 0
}

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path $kitsRoot) {
        $found = Get-ChildItem -Path $kitsRoot -Filter "signtool.exe" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    throw "Could not locate signtool.exe in PATH or Windows Kits\10\bin."
}

$signtool = Find-SignTool
Write-Host "Using signtool: $signtool"

if ($hasAzureSigning) {
    Write-Host "Signing '$FilePath' with Azure Trusted Signing ($($env:AZURE_SIGNING_ACCOUNT)/$($env:AZURE_CERT_PROFILE))..."

    $workDir = if ($env:RUNNER_TEMP) {
        Join-Path $env:RUNNER_TEMP "trusted-signing"
    } else {
        Join-Path $env:TEMP "ghostty-trusted-signing"
    }
    New-Item -ItemType Directory -Force $workDir | Out-Null

    $dlibPath = $env:AZURE_DLIB_PATH
    if (-not $dlibPath -or -not (Test-Path -LiteralPath $dlibPath)) {
        $existingDlib = Get-ChildItem -Path $workDir -Filter "Azure.CodeSigning.Dlib.dll" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\Azure\.CodeSigning\.Dlib\.dll$' } |
            Select-Object -First 1
        if (-not $existingDlib) {
            $nupkg = Join-Path $workDir "Microsoft.Trusted.Signing.Client.nupkg"
            $extractDir = Join-Path $workDir "pkg"
            Invoke-WebRequest -UseBasicParsing -OutFile $nupkg "https://www.nuget.org/api/v2/package/Microsoft.Trusted.Signing.Client"
            if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extractDir)
            $existingDlib = Get-ChildItem -Path $extractDir -Filter "Azure.CodeSigning.Dlib.dll" -Recurse |
                Where-Object { $_.FullName -match '\\x64\\Azure\.CodeSigning\.Dlib\.dll$' } |
                Select-Object -First 1
        }
        if (-not $existingDlib) {
            throw "Could not find x64 Azure.CodeSigning.Dlib.dll in Microsoft.Trusted.Signing.Client package."
        }
        $dlibPath = $existingDlib.FullName
    }

    $metadataPath = Join-Path $workDir "metadata.json"
    $metadata = @{
        Endpoint               = $env:AZURE_SIGNING_ENDPOINT
        CodeSigningAccountName = $env:AZURE_SIGNING_ACCOUNT
        CertificateProfileName = $env:AZURE_CERT_PROFILE
    } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $metadataPath -Value $metadata -Encoding utf8

    & $signtool sign /v /fd SHA256 /tr "http://timestamp.acs.microsoft.com" /td SHA256 /dlib $dlibPath /dmdf $metadataPath $FilePath
    if ($LASTEXITCODE -ne 0) {
        throw "Azure Trusted Signing failed with exit code $LASTEXITCODE"
    }
} elseif ($hasPfxSigning) {
    Write-Host "Signing '$FilePath' with PFX certificate..."
    $pfxPath = Join-Path $env:TEMP ("ghostty-sign-" + [Guid]::NewGuid().ToString("N") + ".pfx")
    try {
        $pfxBytes = [Convert]::FromBase64String($env:WINDOWS_PFX_BASE64)
        [IO.File]::WriteAllBytes($pfxPath, $pfxBytes)

        $signArgs = @(
            "sign",
            "/fd", "SHA256",
            "/tr", $TimestampServer,
            "/td", "SHA256",
            "/f", $pfxPath
        )
        if (-not [string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_PASSWORD)) {
            $signArgs += @("/p", $env:WINDOWS_PFX_PASSWORD)
        }
        $signArgs += $FilePath

        & $signtool @signArgs
        if ($LASTEXITCODE -ne 0) {
            throw "signtool PFX signing failed with exit code $LASTEXITCODE"
        }
    } finally {
        if (Test-Path -LiteralPath $pfxPath) {
            Remove-Item -LiteralPath $pfxPath -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host "Verifying Authenticode signature on '$FilePath'..."
& $signtool verify /pa /v $FilePath
if ($LASTEXITCODE -ne 0) {
    throw "signtool verify failed for '$FilePath' with exit code $LASTEXITCODE"
}

if ($env:GITHUB_ENV) {
    [IO.File]::AppendAllText($env:GITHUB_ENV, "CODESIGNED=true`n")
}
Write-Host "Successfully signed and verified '$FilePath'."
