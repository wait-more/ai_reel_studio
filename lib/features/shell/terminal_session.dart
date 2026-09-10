import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/widgets.dart';
import 'package:kyroon_pty/kyroon_pty.dart';

/// 单个终端会话：连接一个 Pty (ConPTY/forkpty) 与 flterm/Ghostty VT 引擎。
class TerminalSession extends ChangeNotifier {
  TerminalSession({String? workingDirectory}) {
    _workingDirectory = workingDirectory;
    controller = TerminalController(
      config: const TerminalConfig(
        cols: 120,
        rows: 32,
        scrollbackLimit: 8 * 1024 * 1024,
      ),
    );
  }

  /// 供 [TerminalView] 使用的控制器。
  late final TerminalController controller;

  Pty? _pty;
  StreamSubscription<Uint8List>? _ptyOutputSub;
  bool _disposed = false;
  bool _wired = false;
  bool _usePowerShell = true;

  /// 会话是否已启动（PTY 已 spawn）。
  bool get isRunning => _pty != null;

  String? _workingDirectory;
  String? get workingDirectory => _workingDirectory;

  /// 启动底层 shell（Windows：优先 PowerShell，失败则回退 cmd）。
  void start({String? executable, String? workingDirectory}) {
    if (_pty != null || _disposed) return;
    _workingDirectory = workingDirectory ?? _workingDirectory;
    final targetDir = _workingDirectory;

    final cols = controller.config.cols;
    final rows = controller.config.rows;
    final env = Map<String, String>.from(Platform.environment);

    if (Platform.isWindows) {
      _startWindows(
        preferredExecutable: executable,
        targetDir: targetDir,
        cols: cols,
        rows: rows,
        env: env,
      );
    } else {
      final exe = executable ??
          (Platform.environment['SHELL'] ?? '/bin/bash');
      _spawnPty(
        exe: exe,
        ptyCwd: _unixPtyCwd(targetDir),
        cols: cols,
        rows: rows,
        env: env,
      );
      if (_pty != null) {
        _scheduleEnterDirectory(targetDir);
      }
    }
  }

  void _startWindows({
    required String? preferredExecutable,
    required String? targetDir,
    required int cols,
    required int rows,
    required Map<String, String> env,
  }) {
    // kyroon_pty on Windows used to widen UTF-8 byte-by-byte; non-ASCII
    // cwd then broke CreateProcess. Prefer a safe cwd and always cd after.
    final ptyCwd = _windowsSafePtyCwd(targetDir);

    final attempts = <({String exe, bool powerShell})>[];
    if (preferredExecutable != null && preferredExecutable.isNotEmpty) {
      final ps = preferredExecutable.toLowerCase().contains('powershell') ||
          preferredExecutable.toLowerCase().endsWith('pwsh.exe');
      attempts.add((exe: preferredExecutable, powerShell: ps));
    } else {
      final ps = _windowsPowerShellPath();
      final cmd = _windowsCmdPath();
      if (ps != null) attempts.add((exe: ps, powerShell: true));
      attempts.add((exe: cmd, powerShell: false));
    }

    Object? lastError;
    for (final attempt in attempts) {
      try {
        _usePowerShell = attempt.powerShell;
        _pty = Pty.start(
          attempt.exe,
          columns: cols,
          rows: rows,
          environment: env,
          workingDirectory: ptyCwd,
        );
        lastError = null;
        break;
      } catch (e) {
        lastError = e;
        _pty = null;
        // 若带 cwd 失败，再试一次不带 cwd（仍用同一 shell）
        if (ptyCwd != null) {
          try {
            _pty = Pty.start(
              attempt.exe,
              columns: cols,
              rows: rows,
              environment: env,
              workingDirectory: null,
            );
            lastError = null;
            break;
          } catch (e2) {
            lastError = e2;
            _pty = null;
          }
        }
      }
    }

    if (_pty == null) {
      writeText(
        '无法启动终端。\r\n'
        '原因: $lastError\r\n'
        '请确认系统已安装 PowerShell 或命令提示符，'
        '且项目目录可访问。\r\n',
      );
      return;
    }

    _wireController();
    _attachPtyStreams();
    _scheduleEnterDirectory(targetDir);
    notifyListeners();
  }

  void _spawnPty({
    required String exe,
    required String? ptyCwd,
    required int cols,
    required int rows,
    required Map<String, String> env,
  }) {
    try {
      _pty = Pty.start(
        exe,
        columns: cols,
        rows: rows,
        environment: env,
        workingDirectory: ptyCwd,
      );
    } catch (e) {
      writeText('无法启动终端: $e\r\n');
      return;
    }
    _wireController();
    _attachPtyStreams();
    notifyListeners();
  }

  void _attachPtyStreams() {
    final pty = _pty;
    if (pty == null) return;

    _ptyOutputSub = pty.output.listen(
      controller.write,
      onDone: () {
        if (!_disposed) writeText('\r\n[进程已退出]\r\n');
      },
      onError: (Object e) {
        if (!_disposed) writeText('\r\n[终端输出错误: $e]\r\n');
      },
    );

    pty.exitCode.then((code) {
      if (!_disposed) writeText('\r\n[进程已退出: $code]\r\n');
    });
  }

  void _scheduleEnterDirectory(String? targetDir) {
    if (targetDir == null || targetDir.isEmpty) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (_pty == null || _disposed) return;
      if (Platform.isWindows) {
        if (_usePowerShell) {
          final literal = "'${targetDir.replaceAll("'", "''")}'";
          sendCommand('Set-Location -LiteralPath $literal');
        } else {
          final escaped = targetDir.replaceAll('"', '""');
          if (targetDir.startsWith(r'\\')) {
            sendCommand('pushd "$escaped"');
          } else {
            sendCommand('cd /d "$escaped"');
          }
        }
      } else {
        final escaped = targetDir.replaceAll('"', r'\"');
        sendCommand('cd "$escaped"');
      }
    });
  }

  /// Only pass CreateProcess a cwd that survives the PTY layer.
  static String? _windowsSafePtyCwd(String? targetDir) {
    if (targetDir == null || targetDir.isEmpty) return null;
    if (targetDir.startsWith(r'\\')) return null;
    if (targetDir.codeUnits.any((c) => c > 127)) return null;
    try {
      final dir = Directory(targetDir);
      if (!dir.existsSync()) return null;
      return dir.absolute.path;
    } catch (_) {
      return null;
    }
  }

  static String? _unixPtyCwd(String? targetDir) {
    if (targetDir == null || targetDir.isEmpty) return null;
    try {
      final dir = Directory(targetDir);
      if (!dir.existsSync()) return null;
      return dir.absolute.path;
    } catch (_) {
      return null;
    }
  }

  static String? _windowsPowerShellPath() {
    final root = Platform.environment['SystemRoot'] ??
        Platform.environment['windir'] ??
        r'C:\Windows';
    final candidates = [
      '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
      '$root\\SysWOW64\\WindowsPowerShell\\v1.0\\powershell.exe',
    ];
    for (final path in candidates) {
      try {
        if (File(path).existsSync()) return path;
      } catch (_) {}
    }
    return null;
  }

  static String _windowsCmdPath() {
    final root = Platform.environment['SystemRoot'] ??
        Platform.environment['windir'] ??
        r'C:\Windows';
    final system32 = '$root\\System32\\cmd.exe';
    try {
      if (File(system32).existsSync()) return system32;
    } catch (_) {}
    final comspec = Platform.environment['COMSPEC'];
    if (comspec != null && comspec.isNotEmpty) return comspec;
    return 'cmd.exe';
  }

  void _wireController() {
    if (_wired) return;
    _wired = true;
    controller.onOutput = (bytes) {
      _pty?.write(bytes);
    };
    controller.onResize = (cols, rows) {
      _pty?.resize(rows, cols);
    };
  }

  /// 向终端缓冲区写入纯文本（含 ANSI）。
  void writeText(String text) {
    if (text.isEmpty) return;
    controller.write(Uint8List.fromList(utf8.encode(text)));
  }

  /// 向当前终端发送一段命令作为输入（常用于快捷启动）。
  void sendCommand(String command) {
    _pty?.write(Uint8List.fromList(utf8.encode('$command\r')));
  }

  /// 向终端写入文本，不加回车（用于填入智能体输入区）。
  void sendInput(String text) {
    if (text.isEmpty) return;
    _pty?.write(Uint8List.fromList(utf8.encode(text)));
  }

  /// 读取终端活动屏纯文本（供智能体检测），取末尾若干行。
  String recentBufferText({int maxLines = 48}) {
    final formatter = controller.createFormatter(
      format: FormatterFormat.plain,
      unwrap: true,
      trim: true,
    );
    try {
      final text = formatter.format();
      if (maxLines <= 0) return text;
      final lines = const LineSplitter().convert(text);
      if (lines.length <= maxLines) return text;
      return lines.sublist(lines.length - maxLines).join('\n');
    } finally {
      formatter.dispose();
    }
  }

  /// 结束并清理底层 PTY。
  void kill() {
    _ptyOutputSub?.cancel();
    _ptyOutputSub = null;
    final pty = _pty;
    if (pty != null) {
      try {
        pty.write(Uint8List.fromList(utf8.encode('exit\r')));
      } catch (_) {
        // 管道已关闭则直接强杀
      }
      _pty = null;
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        pty.kill();
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    kill();
    controller.dispose();
    super.dispose();
  }
}
