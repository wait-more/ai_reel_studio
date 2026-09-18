import 'dart:io';

import 'package:path/path.dart' as p;

/// dsh-tui profile 在 `autoInstallPeers: false` 时，peer 依赖不会进
/// `profiles/dsh-tui/node_modules/@deepseek-ai/`。正常应靠
/// `~/.dsh/profiles/node_modules` 父级回退解析；若该层缺失/损坏，嵌入式
/// 终端里就会报 `Cannot find package '@deepseek-ai/schemastery'`。
///
/// 启动 dsh-tui 前尽力补齐关键 junction，避免要求用户手动修 profile。
Future<void> ensureDshTuiLaunchReady() async {
  try {
    await _ensureSchemasteryPeerLink();
  } catch (_) {
    // best-effort：补链失败仍尝试启动，把真实错误留给 TUI。
  }
}

bool _commandLooksLikeDshTui(String command) {
  final lower = command.toLowerCase();
  return RegExp(r'(^|[^\w-])dsh-tui([^\w-]|$)').hasMatch(lower);
}

/// 快捷启动命令是否应先做 dsh profile 预检。
bool shouldHealDshProfileForCommand(String command) =>
    _commandLooksLikeDshTui(command);

Future<void> _ensureSchemasteryPeerLink() async {
  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'])
      : Platform.environment['HOME'];
  if (home == null || home.trim().isEmpty) return;

  final profileRoot = p.join(home, '.dsh', 'profiles', 'dsh-tui');
  if (!Directory(profileRoot).existsSync()) return;

  final scopeDir = p.join(profileRoot, 'node_modules', '@deepseek-ai');
  final linkPath = p.join(scopeDir, 'schemastery');
  if (_entityExists(linkPath)) return;

  final target = _resolveSchemasteryTarget(home);
  if (target == null) return;

  await Directory(scopeDir).create(recursive: true);
  if (_entityExists(linkPath)) return;

  if (Platform.isWindows) {
    // Directory junction（与 dsh 自己的 ensureSymlink 一致）。
    final result = await Process.run(
      'cmd.exe',
      ['/c', 'mklink', '/J', linkPath, target],
      runInShell: false,
    );
    if (result.exitCode != 0 && !_entityExists(linkPath)) {
      throw StateError('mklink failed: ${result.stderr}');
    }
  } else {
    await Link(linkPath).create(target);
  }
}

String? _resolveSchemasteryTarget(String home) {
  final candidates = <String>[
    p.join(home, '.dsh', 'profiles', 'node_modules', '@deepseek-ai',
        'schemastery'),
  ];

  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      candidates.add(p.join(
        appData,
        'npm',
        'node_modules',
        '@deepseek-ai',
        'dsh',
        'node_modules',
        '@deepseek-ai',
        'schemastery',
      ));
    }
  } else {
    candidates.add(p.join(
      home,
      '.npm-global',
      'lib',
      'node_modules',
      '@deepseek-ai',
      'dsh',
      'node_modules',
      '@deepseek-ai',
      'schemastery',
    ));
  }

  for (final c in candidates) {
    final pkg = p.join(c, 'package.json');
    if (File(pkg).existsSync()) return c;
  }
  return null;
}

bool _entityExists(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.notFound;
  } catch (_) {
    return false;
  }
}
