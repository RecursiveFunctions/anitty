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

$hasSignPath = (
    -not [string]::IsNullOrWhiteSpace($env:SIGNPATH_API_TOKEN) -and
    -not [string]::IsNullOrWhiteSpace($env:SIGNPATH_ORGANIZATION_ID) -and
    -not [string]::IsNullOrWhiteSpace($env:SIGNPATH_PROJECT_SLUG) -and
    -not [string]::IsNullOrWhiteSpace($env:SIGNPATH_SIGNING_POLICY_SLUG)
)
$hasAzureSigning = (
    -not [string]::IsNullOrWhiteSpace($env:AZURE_SIGNING_ENDPOINT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_SIGNING_ACCOUNT) -and
    -not [string]::IsNullOrWhiteSpace($env:AZURE_CERT_PROFILE)
)
$hasPfxSigning = -not [string]::IsNullOrWhiteSpace($env:WINDOWS_PFX_BASE64)

if (-not $hasSignPath -and -not $hasAzureSigning -and -not $hasPfxSigning) {
    Write-Host "Skipping Authenticode signing for '$FilePath' (SignPath, Azure Trusted Signing, and WINDOWS_PFX_BASE64 are not configured)."
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

if ($hasSignPath) {
    Write-Host "Signing '$FilePath' with SignPath ($($env:SIGNPATH_PROJECT_SLUG)/$($env:SIGNPATH_SIGNING_POLICY_SLUG))..."
    $workDir = Join-Path $env:TEMP ("ghostty-signpath-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force $workDir | Out-Null
    try {
        $fileName = Split-Path -Leaf $FilePath
        $inputZip = Join-Path $workDir "unsigned.zip"
        $outputZip = Join-Path $workDir "signed.zip"
        $extractDir = Join-Path $workDir "extracted"

        Compress-Archive -LiteralPath $FilePath -DestinationPath $inputZip -Force

        $baseUrl = "https://app.signpath.io/API/v1/$($env:SIGNPATH_ORGANIZATION_ID)/SigningRequests"
        $authHeader = "Authorization: Bearer $($env:SIGNPATH_API_TOKEN)"
        $curlArgs = @(
            "-sS", "-f", "-X", "POST",
            "-H", $authHeader,
            "-F", "ProjectSlug=$($env:SIGNPATH_PROJECT_SLUG)",
            "-F", "SigningPolicySlug=$($env:SIGNPATH_SIGNING_POLICY_SLUG)",
            "-F", "Artifact=@$inputZip"
        )
        if (-not [string]::IsNullOrWhiteSpace($env:SIGNPATH_ARTIFACT_CONFIGURATION_SLUG)) {
            $curlArgs += @("-F", "ArtifactConfigurationSlug=$($env:SIGNPATH_ARTIFACT_CONFIGURATION_SLUG)")
        }
        $curlArgs += $baseUrl

        $submitJson = & curl.exe @curlArgs
        if ($LASTEXITCODE -ne 0) {
            throw "SignPath submission failed with exit code $LASTEXITCODE"
        }
        $submitObj = $submitJson | ConvertFrom-Json
        $reqId = $submitObj.signingRequestId
        Write-Host "Submitted SignPath signing request: $reqId"

        $statusUrl = "$baseUrl/$reqId"
        $headers = @{ Authorization = "Bearer $($env:SIGNPATH_API_TOKEN)" }
        $signedUrl = $null
        for ($i = 0; $i -lt 120; $i++) {
            Start-Sleep -Seconds 3
            $statusObj = Invoke-RestMethod -Uri $statusUrl -Headers $headers -Method Get
            Write-Host "  SignPath status: $($statusObj.status) ($($statusObj.workflowStatus))"
            if ($statusObj.isFinalStatus) {
                if ($statusObj.status -ne "Completed") {
                    throw "SignPath signing request $reqId finished with status $($statusObj.status) ($($statusObj.workflowStatus))"
                }
                $signedUrl = $statusObj.signedArtifactLink
                break
            }
        }
        if (-not $signedUrl) {
            throw "Timed out waiting for SignPath signing request $reqId"
        }

        Invoke-WebRequest -UseBasicParsing -Uri $signedUrl -Headers $headers -OutFile $outputZip
        Expand-Archive -LiteralPath $outputZip -DestinationPath $extractDir -Force
        Copy-Item -LiteralPath (Join-Path $extractDir $fileName) -Destination $FilePath -Force
    } finally {
        if (Test-Path -LiteralPath $workDir) {
            Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
} elseif ($hasAzureSigning) {
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
            $tsVersion = "1.0.95"
            $tsSha256 = "3bfcf1e0a3cb42af1692f0a8ed45c15de070c2de86f28a59b2795d904d8a920f"
            $nupkg = Join-Path $workDir "Microsoft.Trusted.Signing.Client.$tsVersion.nupkg"
            $extractDir = Join-Path $workDir "pkg"
            Invoke-WebRequest -UseBasicParsing -OutFile $nupkg "https://api.nuget.org/v3-flatcontainer/microsoft.trusted.signing.client/$tsVersion/microsoft.trusted.signing.client.$tsVersion.nupkg"
            $actualHash = (Get-FileHash -Algorithm SHA256 $nupkg).Hash.ToLowerInvariant()
            if ($actualHash -ne $tsSha256) {
                Remove-Item -Force $nupkg -ErrorAction SilentlyContinue
                throw "SHA-256 mismatch for Microsoft.Trusted.Signing.Client.$tsVersion.nupkg: expected $tsSha256, got $actualHash"
            }
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
$authSig = Get-AuthenticodeSignature -LiteralPath $FilePath
if ($null -eq $authSig.SignerCertificate -or $authSig.Status -eq "NotSigned" -or $authSig.Status -eq "HashMismatch") {
    throw "Authenticode signature verification failed for '$FilePath': status=$($authSig.Status)"
}
Write-Host "Authenticode signature present: Subject='$($authSig.SignerCertificate.Subject)' Thumbprint='$($authSig.SignerCertificate.Thumbprint)' Status='$($authSig.Status)'"

if ($env:GITHUB_ENV) {
    [IO.File]::AppendAllText($env:GITHUB_ENV, "CODESIGNED=true`n")
}
Write-Host "Successfully signed and verified '$FilePath'."
