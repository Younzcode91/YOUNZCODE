[CmdletBinding()]
param(
    [string]$DestinationDirectory = (Join-Path $env:TEMP "YOUNZCODE\open-generative-ai")
)

$ErrorActionPreference = "Stop"
$Version = "1.0.9"
$ExpectedSha256 = "f445033534e59332ca9a46310dbc4230acf282c42b3d0bfe11fbe09a6985c144"
$AssetName = "Open.Generative.AI.Setup.$Version.exe"
$DownloadUrl = "https://github.com/Anil-matcha/Open-Generative-AI/releases/download/v$Version/$AssetName"
$InstallerPath = Join-Path $DestinationDirectory $AssetName

New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
Write-Host "Downloading Open Generative AI v$Version..."
Invoke-WebRequest -Uri $DownloadUrl -OutFile $InstallerPath -UseBasicParsing

$ActualSha256 = (Get-FileHash -Path $InstallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualSha256 -ne $ExpectedSha256) {
    Remove-Item -Force -Path $InstallerPath -ErrorAction SilentlyContinue
    throw "SHA256 mismatch for $AssetName. Expected $ExpectedSha256, got $ActualSha256."
}

Write-Host "SHA-256 verified. Opening the upstream installer..."
Start-Process -FilePath $InstallerPath -Wait
