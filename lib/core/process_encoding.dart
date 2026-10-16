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

String _quoteCmdArg(String arg) {
  if (arg.isEmpty) return '""';
  if (!RegExp(r'''[\s"^&|<>()]''').hasMatch(arg)) return arg;
  return '"${arg.replaceAll('"', r'\"')}"';
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

/// 直接启动 opencode 可执行文件，参数按 argv 传递。
///
/// 含 JSON 的 `-d` 必须走这里。`runOpenCodeRaw` 经 cmd 拼命令行时会拆掉引号，
/// 服务端收到字符串后报 Expected object。
Future<ProcessResult> runOpenCodeDirect(
  List<String> args, {
  String? workingDirectory,
}) async {
  final exe = await _resolveOpenCodeExecutable();
  return Process.run(
    exe,
    args,
    workingDirectory: workingDirectory,
    runInShell: false,
    stdoutEncoding: null,
    stderrEncoding: null,
  );
}

Future<String> _resolveOpenCodeExecutable() async {
  if (!Platform.isWindows) return 'opencode';
  final where = await Process.run(
    'where.exe',
    ['opencode'],
    runInShell: false,
    stdoutEncoding: systemEncoding,
  );
  final lines = '${where.stdout}'
      .split(RegExp(r'\r?\n'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty);
  for (final line in lines) {
    if (line.toLowerCase().endsWith('.exe') && File(line).existsSync()) {
      return line;
    }
  }
  for (final line in lines) {
    final slash = line.lastIndexOf(RegExp(r'[\\/]'));
    if (slash < 0) continue;
    final dir = line.substring(0, slash);
    final candidate = '$dir\\node_modules\\@opencode\\cli\\bin\\opencode.exe';
    if (File(candidate).existsSync()) return candidate;
  }
  return 'opencode';
}
