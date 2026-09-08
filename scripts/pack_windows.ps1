#Requires -Version 5.1
<#
.SYNOPSIS
  Build Windows package (default Release), zip portable, and compile Inno Setup installer.

.PARAMETER Configuration
  Flutter build configuration: Release (default) or Debug.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/pack_windows.ps1 -Configuration Debug
#>
param(
  [ValidateSet('Release', 'Debug')]
  [string]$Configuration = 'Release'
)

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

function Find-InnoSetupCompiler {
  # 1) PATH / where.exe
  $fromPath = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
  if ($fromPath -and (Test-Path $fromPath.Source)) {
    return $fromPath.Source
  }
  try {
    $whereOut = & where.exe ISCC.exe 2>$null
    if ($LASTEXITCODE -eq 0 -and $whereOut) {
      $first = ($whereOut | Select-Object -First 1).ToString().Trim()
      if ($first -and (Test-Path $first)) { return $first }
    }
  } catch {}

  # 2) Uninstall registry (InstallLocation)
  $uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($root in $uninstallRoots) {
    $apps = Get-ItemProperty $root -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -match '^\s*Inno Setup\b' }
    foreach ($app in $apps) {
      $loc = $app.InstallLocation
      if (-not $loc -and $app.UninstallString) {
        # UninstallString 形如 "D:\Program Files\Inno Setup 7\unins000.exe"
        $u = $app.UninstallString.Trim().Trim('"')
        if ($u) { $loc = Split-Path $u -Parent }
      }
      if (-not $loc) { continue }
      $candidate = Join-Path $loc 'ISCC.exe'
      if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }
  }

  # 3) 常见根目录下扫描 "Inno Setup *" 文件夹
  $searchRoots = @(
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)},
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    'D:\Program Files',
    'D:\Program Files (x86)',
    'E:\Program Files',
    'E:\Program Files (x86)'
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

  $found = foreach ($base in $searchRoots) {
    Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match '^Inno Setup\b' } |
      ForEach-Object {
        $exe = Join-Path $_.FullName 'ISCC.exe'
        if (Test-Path $exe) { $exe }
      }
  }
  if ($found) {
    # 优先版本号更高的目录名（Inno Setup 7 > 6）
    $best = $found |
      Sort-Object {
        if ($_ -match 'Inno Setup\s+(\d+)') { [int]$Matches[1] } else { 0 }
      } -Descending |
      Select-Object -First 1
    return (Resolve-Path $best).Path
  }

  return $null
}

$Version = Get-PubspecVersion
$Dist = Join-Path $Root 'dist'
$BuildDir = Join-Path $Root "build\windows\x64\runner\$Configuration"
$ZipName = "AIReelStudio-$Version-windows-x64.zip"
$ZipPath = Join-Path $Dist $ZipName
$FlutterBuildFlag = if ($Configuration -eq 'Debug') { '--debug' } else { '--release' }

Write-Host "==> Flutter pub get" -ForegroundColor Cyan
flutter pub get
if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }

Write-Host "==> flutter build windows $FlutterBuildFlag (v$Version, $Configuration)" -ForegroundColor Cyan
flutter build windows $FlutterBuildFlag
if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed" }

if (-not (Test-Path (Join-Path $BuildDir 'ai_reel_studio.exe'))) {
  throw "App exe not found: $BuildDir"
}

New-Item -ItemType Directory -Force -Path $Dist | Out-Null

if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }

Write-Host "==> Zip portable package -> $ZipPath" -ForegroundColor Cyan
# Compress-Archive needs a folder name inside zip; stage a clean copy
$Stage = Join-Path $Dist "AIReelStudio-$Version"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null
Copy-Item -Path (Join-Path $BuildDir '*') -Destination $Stage -Recurse -Force
Compress-Archive -Path $Stage -DestinationPath $ZipPath -Force
Remove-Item -Recurse -Force $Stage

$Iscc = Find-InnoSetupCompiler
if (-not $Iscc) {
  throw @"
Inno Setup compiler (ISCC.exe) not found.
Install Inno Setup from https://jrsoftware.org/isinfo.php then re-run.
Looked in: PATH, uninstall registry, and common Program Files folders.
"@
}

Write-Host "==> Inno Setup: $Iscc" -ForegroundColor Cyan
Write-Host "==> Source: $BuildDir" -ForegroundColor Cyan
$Iss = Join-Path $Root 'installer\windows\ai_reel_studio.iss'
& $Iscc `
  "/DMyAppVersion=$Version" `
  "/DMyReleaseDir=$BuildDir" `
  "/DMyOutputDir=$Dist" `
  $Iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Portable: $ZipPath"
Write-Host "  Setup:    $(Join-Path $Dist "AIReelStudio-$Version-Setup.exe")"
