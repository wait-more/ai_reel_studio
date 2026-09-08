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

  /// 会话是否已启动（PTY 已 spawn）。
  bool get isRunning => _pty != null;

  String? _workingDirectory;
  String? get workingDirectory => _workingDirectory;

  /// 启动底层 shell（Windows 默认 PowerShell）。
  void start({String? executable, String? workingDirectory}) {
    if (_pty != null || _disposed) return;
    _workingDirectory = workingDirectory ?? _workingDirectory;
    final targetDir = _workingDirectory;
    final isWindows = Platform.isWindows;

    // Windows 默认用 PowerShell：它原生支持 UNC 作为当前位置，
    // Set-Location 可直接切入共享目录且不创建网络盘符映射（无残留）。
    final exe = executable ??
        (Platform.isWindows
            ? 'powershell.exe'
            : (Platform.environment['SHELL'] ?? '/bin/bash'));

    final env = Map<String, String>.from(Platform.environment);

    // 布局前用 config 默认尺寸；视图就绪后 onResize 会更新 PTY。
    final cols = controller.config.cols;
    final rows = controller.config.rows;

    // Windows 的进程启动工作目录不支持 UNC 路径（会回退到系统盘）。
    // 对 UNC，先以系统目录启动，再在 shell 就绪后通过 Set-Location 切入。
    final isUnc = isWindows && (targetDir?.startsWith('\\\\') ?? false);
    final ptyCwd = isUnc ? null : targetDir;

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

    // 等 shell 就绪后，把工作目录切到目标目录。
    if (targetDir != null && targetDir.isNotEmpty) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (_pty == null || _disposed) return;
        final cmd = Platform.isWindows
            ? 'Set-Location "$targetDir"'
            : 'cd "$targetDir"';
        sendCommand(cmd);
      });
    }

    // PTY 输出 → VT 引擎（原始字节，避免二次解码破坏序列）
    _ptyOutputSub = _pty!.output.listen(
      controller.write,
      onDone: () {
        if (!_disposed) writeText('\r\n[进程已退出]\r\n');
      },
      onError: (Object e) {
        if (!_disposed) writeText('\r\n[终端输出错误: $e]\r\n');
      },
    );

    _pty!.exitCode.then((code) {
      if (!_disposed) writeText('\r\n[进程已退出: $code]\r\n');
    });

    notifyListeners();
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
