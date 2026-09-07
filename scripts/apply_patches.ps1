#Requires -Version 5.1
<#
.SYNOPSIS
  Apply portable pub dependency patches (patches/*.patch) after flutter pub get.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts/apply_patches.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $Root

if (-not $env:PUB_CACHE) {
  $env:PUB_CACHE = Join-Path $env:LOCALAPPDATA 'Pub\Cache'
}

Write-Host "==> PUB_CACHE=$env:PUB_CACHE" -ForegroundColor Cyan
dart run ft_patch_package apply
if ($LASTEXITCODE -ne 0) { throw "ft_patch_package apply failed" }
Write-Host "Done." -ForegroundColor Green
