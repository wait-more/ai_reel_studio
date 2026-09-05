import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:kyroon_pty/kyroon_pty.dart';
import 'package:xterm/xterm.dart';

/// 单个终端会话：连接一个 Pty (ConPTY/forkpty) 与一个 xterm Terminal 仿真器。
class TerminalSession extends ChangeNotifier {
  TerminalSession({String? workingDirectory}) {
    _workingDirectory = workingDirectory;
  }

  /// 供 TerminalView 渲染的终端仿真器。
  final Terminal terminal = Terminal(maxLines: 12000);

  Pty? _pty;
  StreamSubscription<String>? _ptyOutputSub;
  bool _disposed = false;

  /// 会话是否已启动（PTY 已 spawn）。
  bool get isRunning => _pty != null;

  String? _workingDirectory;
  String? get workingDirectory => _workingDirectory;

  /// 启动底层 shell（Windows 用 cmd，其它平台用用户默认 shell）。
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

    // viewWidth/viewHeight 在终端未布局时可能为 0，需兜底为合理尺寸
    final cols = terminal.viewWidth > 0 ? terminal.viewWidth : 120;
    final rows = terminal.viewHeight > 0 ? terminal.viewHeight : 32;

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
      terminal.write('无法启动终端: $e\r\n');
      return;
    }

    // 等 shell 就绪后，把工作目录切到目标目录。
    // PowerShell 的 Set-Location 对 UNC 与本地路径均可靠，且 UNC 不创建盘符映射。
    if (targetDir != null && targetDir.isNotEmpty) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        if (_pty == null || _disposed) return;
        final cmd = Platform.isWindows
            ? 'Set-Location "$targetDir"'
            : 'cd "$targetDir"';
        sendCommand(cmd);
      });
    }

    // PTY 输出 → 终端仿真器（xterm 负责 ANSI/VT 解析）
    _ptyOutputSub = _pty!.output
        .cast<List<int>>()
        .transform(const Utf8Decoder())
        .listen(terminal.write, onDone: () {
      if (!_disposed) {
        terminal.write('\r\n[进程已退出]\r\n');
      }
    });

    _pty!.exitCode.then((code) {
      if (!_disposed) {
        terminal.write('\r\n[进程已退出: $code]\r\n');
      }
    });

    // 键盘/粘贴 → PTY stdin（注意 Enter 用 \r）
    terminal.onOutput = (data) {
      _pty?.write(const Utf8Encoder().convert(data));
    };

    // 视口尺寸变化 → 转发给 PTY（注意 rows, cols 顺序）
    terminal.onResize = (w, h, pw, ph) {
      _pty?.resize(h, w);
    };

    notifyListeners();
  }

  /// 向当前终端发送一段命令作为输入（常用于快捷启动）。
  void sendCommand(String command) {
    _pty?.write(const Utf8Encoder().convert('$command\r'));
  }

  /// 结束并清理底层 PTY。
  ///
  /// 先给 shell 发 exit 让它正常退出（PowerShell/cmd 退出时会自动回收其
  /// 临时状态，例如 UNC 上下文，避免残留网络盘符映射）；短暂等待后仍不退
  /// 再强杀兜底。
  void kill() {
    _ptyOutputSub?.cancel();
    _ptyOutputSub = null;
    final pty = _pty;
    if (pty != null) {
      try {
        pty.write(const Utf8Encoder().convert('exit\r'));
      } catch (_) {
        // 管道已关闭则直接强杀
      }
      _pty = null;
      // 给 shell 一个正常退出的机会，超时后再强杀
      Future<void>.delayed(const Duration(milliseconds: 1500), () {
        pty.kill();
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    kill();
    super.dispose();
  }
}
