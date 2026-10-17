import 'dart:convert';
import 'dart:io';

/// 解码 CLI 标准输出/错误。
///
/// 中文 Windows + `runInShell` 时，stdout 可能是 UTF-8 或系统码页（GBK）。
/// [preferJson] 为 true 时，在多种解码结果里优先选「能 jsonDecode」的那份，
/// 避免误用 GBK 去解 UTF-8（或反过来）导致列表变空/解析失败。
String decodeProcessOutput(Object? data, {bool preferJson = false}) {
  if (data == null) return '';
  if (data is String) return _stripBom(data);
  if (data is! List<int>) return data.toString();
  final bytes = data;
  if (bytes.isEmpty) return '';

  final trials = <String>[];
  void tryDecode(String Function(List<int>) decode) {
    try {
      trials.add(_stripBom(decode(bytes)));
    } catch (_) {}
  }

  tryDecode(utf8.decode);
  tryDecode(systemEncoding.decode);
  tryDecode((b) => utf8.decode(b, allowMalformed: true));
  if (trials.isEmpty) return '';

  if (preferJson) {
    for (final t in trials) {
      final s = t.trim();
      if (s.isEmpty) continue;
      if (!(s.startsWith('[') || s.startsWith('{'))) continue;
      try {
        jsonDecode(s);
        return s;
      } catch (_) {}
    }
  }
  return trials.first;
}

String _stripBom(String s) {
  if (s.isNotEmpty && s.codeUnitAt(0) == 0xfeff) {
    return s.substring(1);
  }
  return s;
}

/// Windows cmd 参数转义：空格/`" `&|<>()` 等需包双引号；内部 `"` 写成 `""`。
String _quoteCmdArg(String arg) {
  if (arg.isEmpty) return '""';
  if (!RegExp(r'''[\s"^&|<>()%!^]''').hasMatch(arg)) return arg;
  return '"${arg.replaceAll('"', '""')}"';
}

/// 跑 `opencode` 并拿原始字节。Windows 先 `chcp 65001`，减少 GBK 管道。
Future<ProcessResult> runOpenCodeRaw(
  List<String> args, {
  String? workingDirectory,
}) async {
  if (Platform.isWindows) {
    final cmdline = StringBuffer('chcp 65001>nul & opencode');
    for (final a in args) {
      cmdline.write(' ');
      cmdline.write(_quoteCmdArg(a));
    }
    return Process.run(
      'cmd',
      ['/c', cmdline.toString()],
      workingDirectory: workingDirectory,
      runInShell: false,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
  }
  return Process.run(
    'opencode',
    args,
    workingDirectory: workingDirectory,
    runInShell: true,
    stdoutEncoding: null,
    stderrEncoding: null,
  );
}

String? _cachedOpenCodeExe;
Future<String?>? _resolvingOpenCodeExe;

/// 直接启动 opencode 可执行文件，参数按 argv 传递。
///
/// 优先真实 `.exe`（避免 cmd 拆 JSON/`-d`）。若本机只有 npm 的 `.cmd` 包装
///（常见于部分 V1 安装），则回退 [runOpenCodeRaw]（已用 cmd `""` 转义）。
Future<ProcessResult> runOpenCodeDirect(
  List<String> args, {
  String? workingDirectory,
}) async {
  final exe = await resolveOpenCodeExecutable();
  if (exe == null) {
    return runOpenCodeRaw(args, workingDirectory: workingDirectory);
  }
  try {
    return await Process.run(
      exe,
      args,
      workingDirectory: workingDirectory,
      runInShell: false,
      stdoutEncoding: null,
      stderrEncoding: null,
    );
  } on ProcessException {
    // 解析到的路径失效时再走 PATH/shim。
    return runOpenCodeRaw(args, workingDirectory: workingDirectory);
  }
}

/// 解析本机可直接 CreateProcess 的 opencode.exe；找不到返回 null。
Future<String?> resolveOpenCodeExecutable({bool force = false}) {
  if (!Platform.isWindows) return Future.value('opencode');
  if (!force && _cachedOpenCodeExe != null) {
    return Future.value(_cachedOpenCodeExe);
  }
  if (!force && _resolvingOpenCodeExe != null) return _resolvingOpenCodeExe!;
  _resolvingOpenCodeExe = _resolveOpenCodeExecutableUncached().whenComplete(() {
    _resolvingOpenCodeExe = null;
  });
  return _resolvingOpenCodeExe!;
}

Future<String?> _resolveOpenCodeExecutableUncached() async {
  final candidates = <String>{};

  void addCandidate(String? path) {
    final p = path?.trim() ?? '';
    if (p.isEmpty) return;
    candidates.add(p);
  }

  Future<void> collectWhere(String name) async {
    try {
      final where = await Process.run(
        'where.exe',
        [name],
        runInShell: false,
        stdoutEncoding: systemEncoding,
      );
      for (final line in '${where.stdout}'.split(RegExp(r'\r?\n'))) {
        addCandidate(line.trim());
      }
    } catch (_) {}
  }

  await collectWhere('opencode.exe');
  await collectWhere('opencode');

  // 从 npm/cmd 包装旁推断真实二进制。
  final derived = <String>[];
  for (final line in candidates) {
    final lower = line.toLowerCase();
    if (lower.endsWith('.exe')) continue;
    final slash = line.lastIndexOf(RegExp(r'[\\/]'));
    if (slash < 0) continue;
    final dir = line.substring(0, slash);
    derived.addAll([
      '$dir\\opencode.exe',
      '$dir\\node_modules\\@opencode\\cli\\bin\\opencode.exe',
      '$dir\\node_modules\\opencode\\bin\\opencode.exe',
      '$dir\\node_modules\\opencode-ai\\bin\\opencode.exe',
    ]);
    if (lower.endsWith('.cmd') || lower.endsWith('.ps1')) {
      try {
        final text = await File(line).readAsString();
        for (final m in RegExp(
          r'''["']([^"']*opencode\.exe)["']''',
          caseSensitive: false,
        ).allMatches(text)) {
          var hit = m.group(1)!;
          if (hit.contains('%~dp0') || hit.contains('%dp0%')) {
            hit = hit
                .replaceAll('%~dp0', '$dir\\')
                .replaceAll('%dp0%', '$dir\\');
          }
          derived.add(hit);
        }
      } catch (_) {}
    }
  }
  candidates.addAll(derived);

  for (final path in candidates) {
    if (!path.toLowerCase().endsWith('.exe')) continue;
    if (File(path).existsSync()) {
      _cachedOpenCodeExe = path;
      return path;
    }
  }
  _cachedOpenCodeExe = null;
  return null;
}

/// 测试用：清空可执行文件缓存。
void debugResetOpenCodeExecutableCache() {
  _cachedOpenCodeExe = null;
  _resolvingOpenCodeExe = null;
}
