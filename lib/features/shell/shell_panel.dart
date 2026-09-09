import 'dart:async';
import 'dart:io';

import 'package:flterm/flterm.dart' hide Scrollbar;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent_bridge.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/shell_session_memory.dart';
import '../../core/toast.dart';
import 'terminal_session.dart';

/// Shell 面板：真实 PTY 终端，支持多 Tab、快捷启动与会话级恢复（一期）。
class ShellPanel extends ConsumerStatefulWidget {
  const ShellPanel({super.key});

  @override
  ConsumerState<ShellPanel> createState() => _ShellPanelState();
}

class _ShellPanelState extends ConsumerState<ShellPanel> {
  final List<_ShellTab> _tabs = [];
  int _activeIndex = 0;
  bool _bootstrapped = false;
  bool _restoring = false;

  /// 新终端默认 cwd：项目 scripts 根目录。
  String? get _projectRoot {
    final root = AppConfig.instance.projectRoot;
    return root.isNotEmpty ? root : null;
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final root = _projectRoot ?? '';
    final snap = await ShellSessionMemory.instance.loadFor(root);
    if (!mounted) return;

    ref.read(shellVisibleProvider.notifier).state = snap.shellVisible;

    if (snap.tabs.isEmpty) {
      _tabs.add(_ShellTab(
        session: TerminalSession()..start(workingDirectory: _projectRoot),
        cwd: _projectRoot,
      ));
      _activeIndex = 0;
      setState(() => _bootstrapped = true);
      _registerHost();
      _schedulePersist();
      return;
    }

    _restoring = true;
    for (final t in List.of(_tabs)) {
      t.dispose();
    }
    _tabs.clear();

    for (final t in snap.tabs) {
      final cwd = (t.cwd != null && t.cwd!.isNotEmpty) ? t.cwd : _projectRoot;
      _tabs.add(_ShellTab(
        session: TerminalSession()..start(workingDirectory: cwd),
        cwd: cwd,
        launchCommand: t.launchCommand,
        launchedAgentHint: t.agentHint,
      ));
    }
    _activeIndex = snap.activeIndex.clamp(0, _tabs.length - 1);
    setState(() => _bootstrapped = true);
    _registerHost();

    // 等各 Tab 的 cwd 切入完成后再重拉启动命令
    await Future<void>.delayed(const Duration(milliseconds: 750));
    if (!mounted) return;

    var relaunched = 0;
    for (final tab in _tabs) {
      final cmd = tab.launchCommand?.trim();
      if (cmd == null || cmd.isEmpty) continue;
      final label = tab.launchedAgentHint ?? cmd.split(RegExp(r'\s+')).first;
      tab.session.writeText(
        '\r\n\x1b[90m[已恢复会话：$label'
        '${tab.cwd != null && tab.cwd!.isNotEmpty ? ' @ ${tab.cwd}' : ''}]'
        '\x1b[0m\r\n',
      );
      tab.session.sendCommand(cmd);
      relaunched++;
    }
    _restoring = false;
    _schedulePersist();

    if (relaunched > 0 && mounted) {
      showGlobalToast(context, '已恢复 $relaunched 个 Shell/智能体会话');
    } else if (snap.tabs.length > 1 && mounted) {
      showGlobalToast(context, '已恢复 ${snap.tabs.length} 个终端标签');
    }
  }

  @override
  void dispose() {
    _persistNow();
    ref.read(shellAgentHostProvider.notifier).state = null;
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }

  void _registerHost() {
    if (!mounted) return;
    ref.read(shellAgentHostProvider.notifier).state = ShellAgentHost(
      isAgentActive: _isActiveTabAgent,
      agentHint: _activeAgentHint,
      inject: _injectToActive,
      focusInput: _focusActiveTerminal,
    );
  }

  bool _isActiveTabAgent() {
    if (_tabs.isEmpty) return false;
    final tab = _tabs[_activeIndex];
    final recent = tab.session.recentBufferText();
    if (terminalTextLooksLikeAgent(recent)) return true;
    final hint = tab.launchedAgentHint;
    if (hint != null && hint.isNotEmpty) {
      // 会话恢复后缓冲里可能还没刷出关键字，有启动命令则仍视为智能体 Tab
      if (tab.launchCommand != null && tab.launchCommand!.trim().isNotEmpty) {
        return true;
      }
      if (recent.toLowerCase().contains(hint.toLowerCase())) return true;
    }
    return false;
  }

  String? _activeAgentHint() {
    if (_tabs.isEmpty) return null;
    return _tabs[_activeIndex].launchedAgentHint;
  }

  bool _injectToActive(String text) {
    if (_tabs.isEmpty || text.isEmpty) return false;
    if (!_isActiveTabAgent()) return false;
    _tabs[_activeIndex].session.sendInput(text);
    return true;
  }

  void _focusActiveTerminal() {
    if (_tabs.isEmpty) return;
    final tab = _tabs[_activeIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_tabs.contains(tab)) return;
      tab.focusNode.requestFocus();
    });
  }

  ShellSessionSnapshot _captureSnapshot() {
    return ShellSessionSnapshot(
      projectRoot: _projectRoot ?? '',
      activeIndex: _activeIndex,
      shellVisible: ref.read(shellVisibleProvider),
      tabs: [
        for (final t in _tabs)
          ShellTabSnapshot(
            kind: (t.launchedAgentHint != null &&
                    t.launchedAgentHint!.isNotEmpty)
                ? 'agent'
                : 'shell',
            cwd: t.cwd ?? t.session.workingDirectory,
            launchCommand: t.launchCommand,
            agentHint: t.launchedAgentHint,
          ),
      ],
    );
  }

  void _schedulePersist() {
    if (!_bootstrapped || _restoring) return;
    ShellSessionMemory.instance.scheduleSave(_captureSnapshot());
  }

  void _persistNow() {
    if (!_bootstrapped) return;
    unawaited(ShellSessionMemory.instance.saveNow(_captureSnapshot()));
  }

  void _newTab({String? workingDirectory}) {
    final cwd = workingDirectory ?? _projectRoot;
    setState(() {
      _tabs.add(_ShellTab(
        session: TerminalSession()..start(workingDirectory: cwd),
        cwd: cwd,
      ));
      _activeIndex = _tabs.length - 1;
    });
    _registerHost();
    _schedulePersist();
  }

  void _closeTab(int index) {
    if (_tabs.length == 1) return;
    final closed = _tabs.removeAt(index);
    setState(() {
      if (_activeIndex >= _tabs.length) {
        _activeIndex = _tabs.length - 1;
      } else if (index < _activeIndex) {
        _activeIndex--;
      }
    });
    _registerHost();
    _schedulePersist();
    // 等本帧树上的 TerminalView 先卸下 FocusNode，再 dispose，避免
    // IndexedStack 无 Key 复用 Element 时访问已 dispose 的节点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      closed.dispose();
    });
  }

  String? _resolveCwd(CwdStrategy strategy) {
    switch (strategy) {
      case CwdStrategy.projectRoot:
        return _projectRoot;
      case CwdStrategy.selectedDir:
        final selected = ref.read(selectedDirProvider);
        if (selected != null &&
            selected.isNotEmpty &&
            Directory(selected).existsSync()) {
          return selected;
        }
        return _projectRoot;
    }
  }

  bool _isAgentLaunchCmd(StartCmd cmd) =>
      commandLooksLikeAgent(cmd.command) || commandLooksLikeAgent(cmd.name);

  void _executeOnTab(_ShellTab tab, StartCmd cmd, {required bool includeCd}) {
    final session = tab.session;
    final cwd = _resolveCwd(cmd.cwd);
    tab.cwd = cwd;
    tab.launchCommand = cmd.command;
    if (includeCd && cwd != null && cwd.isNotEmpty) {
      final line = Platform.isWindows
          ? 'Set-Location -LiteralPath "$cwd"; ${cmd.command}'
          : 'cd "$cwd" && ${cmd.command}';
      session.sendCommand(line);
    } else {
      session.sendCommand(cmd.command);
    }
    if (_isAgentLaunchCmd(cmd)) {
      final token = cmd.command.trim().split(RegExp(r'\s+')).first;
      tab.launchedAgentHint = token.isNotEmpty ? token : cmd.name;
      setState(() {});
    }
    _schedulePersist();
  }

  Future<void> _runStartCmd(StartCmd cmd) async {
    if (_isAgentLaunchCmd(cmd) && _isActiveTabAgent()) {
      final openNew = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('已在智能体中'),
          content: Text(
            '当前终端已在智能体会话中。是否打开新标签页启动「${cmd.name}」？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('打开新标签页'),
            ),
          ],
        ),
      );
      if (openNew != true || !mounted) return;
      final cwd = _resolveCwd(cmd.cwd);
      _newTab(workingDirectory: cwd ?? _projectRoot);
      final tab = _tabs[_activeIndex];
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      _executeOnTab(tab, cmd, includeCd: false);
      return;
    }

    _executeOnTab(_tabs[_activeIndex], cmd, includeCd: true);
  }

  @override
  Widget build(BuildContext context) {
    final terminalFontSize = ref.watch(terminalFontSizeProvider);
    final startCmds = ref.watch(startCmdsProvider);

    ref.listen(shellVisibleProvider, (_, __) => _schedulePersist());
    ref.listen(shellOpenCwdRequestProvider, (prev, next) {
      if (next == null || next.isEmpty) return;
      final dir = Directory(next);
      final cwd = dir.existsSync() ? next : _projectRoot;
      _newTab(workingDirectory: cwd);
      ref.read(shellOpenCwdRequestProvider.notifier).state = null;
    });

    if (!_bootstrapped) {
      return const ColoredBox(
        color: Color(0xFF1E1E1E),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Column(
        children: [
          _buildTabBar(context),
          const Divider(height: 1, color: Colors.white12),
          Expanded(
            child: _tabs.isEmpty
                ? const SizedBox.shrink()
                : IndexedStack(
                    index: _activeIndex,
                    children: [
                      for (final tab in _tabs)
                        _TerminalViewClient(
                          key: ObjectKey(tab),
                          tab.session,
                          focusNode: tab.focusNode,
                          fontSize: terminalFontSize,
                          autofocus: identical(tab, _tabs[_activeIndex]),
                        ),
                    ],
                  ),
          ),
          _buildQuickLaunch(context, startCmds),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return Container(
      height: 34,
      color: const Color(0xFF2D2D2D),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) {
                final isActive = index == _activeIndex;
                final tab = _tabs[index];
                final agentish = tab.launchedAgentHint != null;
                return InkWell(
                  onTap: () {
                    setState(() => _activeIndex = index);
                    _registerHost();
                    _schedulePersist();
                  },
                  child: Container(
                    margin: const EdgeInsets.symmetric(
                        vertical: 4, horizontal: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: isActive
                          ? const Color(0xFF1E1E1E)
                          : const Color(0xFF2D2D2D),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (agentish) ...[
                          const Icon(Icons.smart_toy_outlined,
                              size: 12, color: Colors.lightGreenAccent),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          agentish
                              ? (tab.launchedAgentHint ?? 'Agent')
                              : '终端 ${index + 1}',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => _closeTab(index),
                          child: const Icon(Icons.close,
                              size: 13, color: Colors.white38),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 16, color: Colors.white54),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: '新建终端',
            onPressed: _newTab,
          ),
        ],
      ),
    );
  }

  Widget _buildQuickLaunch(BuildContext context, List<StartCmd> commands) {
    if (commands.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(8),
      color: const Color(0xFF2D2D2D),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final cmd in commands)
            ActionChip(
              avatar:
                  const Icon(Icons.play_arrow, size: 14, color: Colors.white70),
              label: Text(cmd.name, style: const TextStyle(fontSize: 11)),
              backgroundColor: const Color(0xFF3D3D3D),
              labelStyle: const TextStyle(color: Colors.white),
              tooltip:
                  '${cmd.command}\n${cmd.cwd == CwdStrategy.selectedDir ? "cwd: 当前选中目录" : "cwd: 项目根"}',
              onPressed: () => _runStartCmd(cmd),
            ),
        ],
      ),
    );
  }
}

/// 单个终端页签。
class _ShellTab {
  final TerminalSession session;
  final FocusNode focusNode = FocusNode();
  String? cwd;
  String? launchCommand;
  String? launchedAgentHint;

  _ShellTab({
    required this.session,
    this.cwd,
    this.launchCommand,
    this.launchedAgentHint,
  });

  void dispose() {
    focusNode.dispose();
    session.dispose();
  }
}

/// 渲染单个会话的 TerminalView 并监听会话变更。
class _TerminalViewClient extends StatefulWidget {
  final TerminalSession session;
  final FocusNode focusNode;
  final double fontSize;
  final bool autofocus;
  const _TerminalViewClient(
    this.session, {
    super.key,
    required this.focusNode,
    required this.fontSize,
    this.autofocus = false,
  });

  @override
  State<_TerminalViewClient> createState() => _TerminalViewClientState();
}

class _TerminalViewClientState extends State<_TerminalViewClient> {
  late final TerminalScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = TerminalScrollController();
    widget.session.addListener(_onSessionChanged);
  }

  @override
  void didUpdateWidget(covariant _TerminalViewClient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_onSessionChanged);
      widget.session.addListener(_onSessionChanged);
    }
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_onSessionChanged);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onSecondaryPointer(PointerDownEvent event) async {
    if (event.buttons & kSecondaryMouseButton == 0) return;
    final controller = widget.session.controller;
    if (controller.hasSelection) {
      final text = controller.selectedText();
      controller.clearSelection();
      if (text.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: text));
      }
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      controller.paste(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = TerminalTheme.dark().copyWith(
      fontSize: widget.fontSize,
      fontFamily: 'Cascadia Mono',
      fontFamilyFallback: const [
        'Consolas',
        'Microsoft YaHei',
        'Segoe UI Emoji',
        'Noto Color Emoji',
      ],
      palette: ColorPalette(
        ansiColors: TerminalTheme.dark().palette.ansiColors,
        background: const Color(0xFF1E1E1E),
        foreground: TerminalTheme.dark().palette.foreground,
      ),
    );

    return Container(
      color: const Color(0xFF1E1E1E),
      child: Listener(
        onPointerDown: _onSecondaryPointer,
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          child: TerminalView(
            controller: widget.session.controller,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            showKeyboard: false,
            scrollController: _scrollController,
            padding: const EdgeInsets.all(4),
            theme: theme,
          ),
        ),
      ),
    );
  }
}
