#Requires -Version 5.1
<#
.SYNOPSIS
  Build Windows Release, zip portable package, optionally compile Inno Setup installer.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1
#>
$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $Root

function Get-PubspecVersion {
  $line = Get-Content (Join-Path $Root 'pubspec.yaml') |
    Where-Object { $_ -match '^\s*version\s*:' } |
    Select-Object -First 1
  if (-not $line) { return '0.1.0' }
  $raw = ($line -split ':', 2)[1].Trim()
  # strip build number: 0.1.0+1 -> 0.1.0
  return ($raw -split '\+', 2)[0].Trim()
}

$Version = Get-PubspecVersion
$Dist = Join-Path $Root 'dist'
$ReleaseDir = Join-Path $Root 'build\windows\x64\runner\Release'
$ZipName = "AIReelStudio-$Version-windows-x64.zip"
$ZipPath = Join-Path $Dist $ZipName

Write-Host "==> Flutter pub get" -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host "==> flutter build windows --release (v$Version)" -ForegroundColor Cyan
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }

if (-not (Test-Path (Join-Path $ReleaseDir 'ai_reel_studio.exe'))) {
  throw "Release exe not found: $ReleaseDir"
}

New-Item -ItemType Directory -Force -Path $Dist | Out-Null

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }

Write-Host "==> Zip portable package -> $ZipPath" -ForegroundColor Cyan
# Compress-Archive needs a folder name inside zip; stage a clean copy
$Stage = Join-Path $Dist "AIReelStudio-$Version"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item -Path (Join-Path $ReleaseDir '*') -Destination $Stage -Recurse -Force
Compress-Archive -Path $Stage -DestinationPath $ZipPath -Force
Remove-Item -Recurse -Force $Stage

$InstallerBuilt = $false
$IsccCandidates = @(
  "${env:LocalAppData}\Programs\Inno Setup 6\ISCC.exe",
  'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
  'C:\Program Files\Inno Setup 6\ISCC.exe'
)
$Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($Iscc) {
  Write-Host "==> Inno Setup: $Iscc" -ForegroundColor Cyan
  $Iss = Join-Path $Root 'installer\windows\ai_reel_studio.iss'
  & $Iscc `
    "/DMyAppVersion=$Version" `
    "/DMyReleaseDir=$ReleaseDir" `
    "/DMyOutputDir=$Dist" `
    $Iss
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
  $InstallerBuilt = $true
} else {
  Write-Host "==> Inno Setup 6 not found — skip installer (zip only)" -ForegroundColor Yellow
  Write-Host "    Install from https://jrsoftware.org/isinfo.php then re-run." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Portable: $ZipPath"
if ($InstallerBuilt) {
  Write-Host "  Setup:    $(Join-Path $Dist "AIReelStudio-$Version-Setup.exe")"
}
