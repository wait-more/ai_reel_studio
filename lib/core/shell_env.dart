import 'dart:io';

/// 构建嵌入式 PTY 使用的环境变量，尽量贴近「用户日常终端」。
///
/// Flutter / Windows GUI 进程常见问题：
/// - Dart 会同时暴露 `Path` 与 `PATH`，原样塞进 CreateProcess 环境块会重复；
/// - 安装器/开始菜单启动时 PATH 可能偏旧，缺 npm 全局目录；
/// - 缺 `HOME` / `DSH_HOME` 时，部分 Node CLI 的家目录解析与系统终端不一致。
Map<String, String> buildPtyEnvironment({String? preferredPath}) {
  final env = <String, String>{};
  for (final e in Platform.environment.entries) {
    env[e.key] = e.value;
  }

  if (Platform.isWindows) {
    _normalizeWindowsPath(env, preferredPath: preferredPath);
    _ensureWindowsHomeVars(env);
  } else {
    if (preferredPath != null && preferredPath.trim().isNotEmpty) {
      env['PATH'] = preferredPath;
    }
    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      final dshHome = '$home/.dsh';
      if (Directory(dshHome).existsSync()) {
        env.putIfAbsent('DSH_HOME', () => dshHome);
      }
    }
  }

  return env;
}

void _normalizeWindowsPath(Map<String, String> env, {String? preferredPath}) {
  final raw = (preferredPath != null && preferredPath.trim().isNotEmpty)
      ? preferredPath
      : (env['Path'] ?? env['PATH'] ?? '');
  // CreateProcess 环境块里 Path/PATH 只能留一份（Windows 大小写不敏感）。
  env.remove('PATH');
  env.remove('Path');
  env['Path'] = raw;
}

void _ensureWindowsHomeVars(Map<String, String> env) {
  var userProfile = env['USERPROFILE']?.trim() ?? '';
  if (userProfile.isEmpty) {
    final drive = env['HOMEDRIVE']?.trim() ?? '';
    final homePath = env['HOMEPATH']?.trim() ?? '';
    if (drive.isNotEmpty && homePath.isNotEmpty) {
      userProfile = '$drive$homePath';
      env['USERPROFILE'] = userProfile;
    }
  }
  if (userProfile.isEmpty) return;

  env.putIfAbsent('HOME', () => userProfile);

  final appData = env['APPDATA']?.trim() ?? '';
  if (appData.isEmpty) {
    env['APPDATA'] = '$userProfile${Platform.pathSeparator}AppData'
        '${Platform.pathSeparator}Roaming';
  }
  final localAppData = env['LOCALAPPDATA']?.trim() ?? '';
  if (localAppData.isEmpty) {
    env['LOCALAPPDATA'] = '$userProfile${Platform.pathSeparator}AppData'
        '${Platform.pathSeparator}Local';
  }

  final dshHome = '$userProfile${Platform.pathSeparator}.dsh';
  if (Directory(dshHome).existsSync()) {
    env.putIfAbsent('DSH_HOME', () => dshHome);
  }
}

/// 从注册表合并 Machine+User PATH（缓存），供 GUI 启动的进程补齐 npm 等目录。
class WindowsPathCache {
  WindowsPathCache._();
  static final WindowsPathCache instance = WindowsPathCache._();

  String? _path;
  Future<String?>? _loading;

  String? get cached => _path;

  Future<String?> refresh() {
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<String?> _load() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NoLogo',
          '-Command',
          r'''
$m = [Environment]::GetEnvironmentVariable('Path','Machine')
$u = [Environment]::GetEnvironmentVariable('Path','User')
if ($null -eq $m) { $m = '' }
if ($null -eq $u) { $u = '' }
Write-Output (($m.TrimEnd(';') + ';' + $u.TrimStart(';')).Trim(';'))
''',
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) return _path;
      final text = '${result.stdout}'.trim();
      if (text.isEmpty) return _path;
      _path = text;
      return _path;
    } catch (_) {
      return _path;
    }
  }
}
