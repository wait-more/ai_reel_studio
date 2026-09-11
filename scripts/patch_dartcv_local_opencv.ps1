#Requires -Version 5.1
<#
.SYNOPSIS
  让 dartcv4 使用仓库旁 tools/opencv-full 预编译包（禁止源码编译 / GitHub 下载）。
#>
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$OpenCvRoot = Join-Path $Root 'tools\opencv-full\extract'
$OpenCvDir = Join-Path $OpenCvRoot 'x64\vc17\staticlib'
$FfmpegDir = Join-Path $OpenCvRoot 'ffmpeg\cmake'
$Cfg = Join-Path $OpenCvDir 'OpenCVConfig.cmake'
if (-not (Test-Path $Cfg)) {
  # 兼容旧布局：config 在 extract 根目录
  $alt = Join-Path $OpenCvRoot 'OpenCVConfig.cmake'
  if (Test-Path $alt) {
    $OpenCvDir = $OpenCvRoot
    $Cfg = $alt
  } else {
    throw "missing OpenCVConfig.cmake under $OpenCvRoot — run scripts/fetch_opencv_full.ps1 first"
  }
}

$PkgConfig = Join-Path $Root '.dart_tool\package_config.json'
if (-not (Test-Path $PkgConfig)) {
  throw "missing $PkgConfig — run flutter pub get first"
}

$json = Get-Content $PkgConfig -Raw | ConvertFrom-Json
$dartcv = $json.packages | Where-Object { $_.name -eq 'dartcv4' } | Select-Object -First 1
if (-not $dartcv) { throw 'dartcv4 not found in package_config.json' }

$rootUri = [Uri]$dartcv.rootUri
$pkgRoot = if ($rootUri.IsAbsoluteUri) {
  $rootUri.LocalPath
} else {
  Join-Path (Join-Path $Root '.dart_tool') ($dartcv.rootUri -replace '^\./','')
}
$pkgRoot = [IO.Path]::GetFullPath($pkgRoot)

$cmake = Join-Path $pkgRoot 'src\CMakeLists.txt'
$downloadSetup = Join-Path $pkgRoot 'src\cmake\download_setup_opencv.cmake'
$hookBuild = Join-Path $pkgRoot 'hook\build.dart'
if (-not (Test-Path $cmake)) { throw "missing $cmake" }
if (-not (Test-Path $downloadSetup)) { throw "missing $downloadSetup" }

# 1) 默认不要源码编译
$cmakeText = Get-Content $cmake -Raw
if ($cmakeText -match 'option\(DARTCV_BUILD_OPENCV_FROM_SOURCE "Build opencv from source" ON\)') {
  $cmakeText = $cmakeText -replace `
    'option\(DARTCV_BUILD_OPENCV_FROM_SOURCE "Build opencv from source" ON\)', `
    'option(DARTCV_BUILD_OPENCV_FROM_SOURCE "Build opencv from source" OFF)'
  Set-Content -Path $cmake -Value $cmakeText -NoNewline -Encoding UTF8
  Write-Host "CMake: DARTCV_BUILD_OPENCV_FROM_SOURCE default OFF" -ForegroundColor Green
}

# 2) 在 download_setup 开头强制本地路径（CMake 子进程经常读不到父 shell 的环境变量）
$openCvCmake = ($OpenCvDir -replace '\\', '/')
$ffmpegCmake = ($FfmpegDir -replace '\\', '/')
$block = @"
# >>> ai_reel_studio local opencv (scripts/patch_dartcv_local_opencv.ps1) >>>
set(DARTCV_BUILD_OPENCV_FROM_SOURCE OFF CACHE BOOL "" FORCE)
set(DARTCV_DISABLE_DOWNLOAD_OPENCV ON CACHE BOOL "" FORCE)
set(OpenCV_DIR "$openCvCmake" CACHE PATH "" FORCE)
set(FFMPEG_DIR "$ffmpegCmake" CACHE PATH "" FORCE)
message(STATUS "ai_reel_studio: using local OpenCV_DIR=`${OpenCV_DIR}")
# <<< ai_reel_studio local opencv <<<

"@

$ds = Get-Content $downloadSetup -Raw
if ($ds -match 'ai_reel_studio local opencv') {
  $ds = [regex]::Replace($ds,
    '(?s)# >>> ai_reel_studio local opencv.*?# <<< ai_reel_studio local opencv <<<\r?\n',
    $block)
} else {
  $ds = $block + $ds
}
Set-Content -Path $downloadSetup -Value $ds -NoNewline -Encoding UTF8
Write-Host "Patched download_setup_opencv.cmake -> $openCvCmake" -ForegroundColor Green

# 3) bump hook cache key
if (Test-Path $hookBuild) {
  $stamp = "// ai_reel_studio local-opencv $(Get-Date -Format 'yyyyMMddHHmmss')"
  $hb = Get-Content $hookBuild -Raw
  if ($hb -notmatch 'ai_reel_studio local-opencv') {
    Add-Content -Path $hookBuild -Value "`n$stamp"
  } else {
    $hb2 = $hb -replace '// ai_reel_studio local-opencv \d+', $stamp
    Set-Content -Path $hookBuild -Value $hb2 -NoNewline -Encoding UTF8
  }
  Write-Host "Bumped hook/build.dart cache key" -ForegroundColor Green
}

$hooksBuild = Join-Path $Root '.dart_tool\hooks_runner\shared\dartcv4\build'
if (Test-Path $hooksBuild) {
  Remove-Item $hooksBuild -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Cleared $hooksBuild"
}

Write-Host "dartcv4: $pkgRoot"
Write-Host "OpenCV:  $OpenCvDir"
