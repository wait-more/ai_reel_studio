import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flterm/flterm.dart';
import 'package:flutter/widgets.dart';
import 'package:kyroon_pty/kyroon_pty.dart';

import '../../core/opencode_sessions.dart';

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
  bool _respawning = false;
  String? _preferredExecutable;
  int _liveCols = 0;
  int _liveRows = 0;
  int _ptyGen = 0;

  /// 宿主被带走并软恢复前回调（清 Tab 上的智能体标记）。
  VoidCallback? onHostExited;

  bool get isRunning => _pty != null;

  String? _workingDirectory;
  String? get workingDirectory => _workingDirectory;

  (int cols, int rows) get _spawnSize {
    final cols = _liveCols > 0 ? _liveCols : controller.config.cols;
    final rows = _liveRows > 0 ? _liveRows : controller.config.rows;
    return (cols < 2 ? 80 : cols, rows < 2 ? 24 : rows);
  }

  /// 启动底层 shell（Windows：优先 PowerShell，失败则回退 cmd）。
  void start({String? executable, String? workingDirectory}) {
    if (_pty != null || _disposed) return;
    _workingDirectory = workingDirectory ?? _workingDirectory;
    if (executable != null && executable.isNotEmpty) {
      _preferredExecutable = executable;
    }
    final targetDir = _workingDirectory;

    final size = _spawnSize;
    final cols = size.$1;
    final rows = size.$2;
    final env = Map<String, String>.from(Platform.environment);

    if (Platform.isWindows) {
      _startWindows(
        preferredExecutable: executable ?? _preferredExecutable,
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
      final args =
          attempt.powerShell ? powerShellHostLaunchArguments() : const <String>[];
      try {
        _usePowerShell = attempt.powerShell;
        _pty = Pty.start(
          attempt.exe,
          arguments: args,
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
        if (ptyCwd != null) {
          try {
            _pty = Pty.start(
              attempt.exe,
              arguments: args,
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
    _applyPtySize();
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
    _applyPtySize();
    notifyListeners();
  }

  void _attachPtyStreams() {
    final pty = _pty;
    if (pty == null) return;
    final gen = _ptyGen;

    _ptyOutputSub?.cancel();
    _ptyOutputSub = pty.output.listen(
      controller.write,
      onDone: () {},
      onError: (Object e) {
        if (!_disposed) writeText('\r\n[终端输出错误: $e]\r\n');
      },
    );

    pty.exitCode.then((code) {
      if (_disposed || gen != _ptyGen) return;
      _handleHostExit(code);
    });
  }

  /// OpenCode 退出常带走宿主：静默软恢复（不刷「进程已退出」）。
  void _handleHostExit(int code) {
    if (_disposed || _respawning) return;
    final gen = ++_ptyGen;
    _ptyOutputSub?.cancel();
    _ptyOutputSub = null;
    _pty = null;
    onHostExited?.call();
    _respawnHostShell(expectedGen: gen);
  }

  void _respawnHostShell({required int expectedGen}) {
    if (_disposed || _respawning) return;
    _respawning = true;
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (_disposed || expectedGen != _ptyGen) {
        _respawning = false;
        return;
      }
      try {
        start(workingDirectory: _workingDirectory);
        if (_pty != null) {
          _applyPtySize();
          syncViewportSize();
        }
      } finally {
        _respawning = false;
        notifyListeners();
      }
    });
  }

  void _scheduleEnterDirectory(String? targetDir) {
    if (targetDir == null || targetDir.isEmpty) return;
    Future<void>.delayed(const Duration(milliseconds: 400), () {
      if (_pty == null || _disposed) return;
      if (Platform.isWindows) {
        if (_usePowerShell) {
          sendCommand(powershellSetLocationCommand(targetDir));
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
      if (cols > 0 && rows > 0) {
        _liveCols = cols;
        _liveRows = rows;
      }
      _applyPtySize();
    };
  }

  void _applyPtySize() {
    final pty = _pty;
    if (pty == null) return;
    final cols = _liveCols > 0 ? _liveCols : controller.config.cols;
    final rows = _liveRows > 0 ? _liveRows : controller.config.rows;
    if (cols < 2 || rows < 2) return;
    try {
      pty.resize(rows, cols);
    } catch (_) {}
  }

  void syncViewportSize({int attempts = 6}) {
    void poke(int left) {
      if (_disposed || left < 0) return;
      _applyPtySize();
      if (left == 0) return;
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        poke(left - 1);
      });
    }

    poke(attempts);
  }

  void writeText(String text) {
    if (text.isEmpty) return;
    controller.write(Uint8List.fromList(utf8.encode(text)));
  }

  void sendCommand(String command) {
    _pty?.write(Uint8List.fromList(utf8.encode('$command\r')));
  }

  void sendInput(String text) {
    if (text.isEmpty) return;
    _pty?.write(Uint8List.fromList(utf8.encode(text)));
  }

  void sendRaw(List<int> bytes) {
    if (bytes.isEmpty) return;
    _pty?.write(Uint8List.fromList(bytes));
  }

  void sendInterrupt() => sendRaw(const [0x03]);

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

  void kill() {
    _ptyGen++;
    _ptyOutputSub?.cancel();
    _ptyOutputSub = null;
    final pty = _pty;
    _pty = null;
    if (pty != null) {
      try {
        pty.kill();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _disposed = true;
    onHostExited = null;
    kill();
    controller.dispose();
    super.dispose();
  }
}
