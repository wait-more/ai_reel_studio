import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/agent_bridge.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import 'terminal_session.dart';

/// Shell 面板：真实 PTY 终端，支持多 Tab 与快捷启动。
class ShellPanel extends ConsumerStatefulWidget {
  const ShellPanel({super.key});

  @override
  ConsumerState<ShellPanel> createState() => _ShellPanelState();
}

class _ShellPanelState extends ConsumerState<ShellPanel> {
  final List<_ShellTab> _tabs = [];
  int _activeIndex = 0;

  /// 新终端默认 cwd：项目 scripts 根目录。
  String? get _projectRoot {
    final root = AppConfig.instance.projectRoot;
    return root.isNotEmpty ? root : null;
  }

  @override
  void initState() {
    super.initState();
    _tabs.add(_ShellTab(
      session: TerminalSession()..start(workingDirectory: _projectRoot),
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) => _registerHost());
  }

  @override
  void dispose() {
    ref.read(shellAgentHostProvider.notifier).state = null;
    for (final t in _tabs) {
      t.session.dispose();
    }
    super.dispose();
  }

  void _registerHost() {
    if (!mounted) return;
    ref.read(shellAgentHostProvider.notifier).state = ShellAgentHost(
      isAgentActive: _isActiveTabAgent,
      agentHint: _activeAgentHint,
      inject: _injectToActive,
    );
  }

  bool _isActiveTabAgent() {
    if (_tabs.isEmpty) return false;
    final tab = _tabs[_activeIndex];
    final recent = tab.session.recentBufferText();
    if (terminalTextLooksLikeAgent(recent)) return true;
    // 快捷启动打过标记，且近期缓冲仍能对上关键字时才算（避免纯 PS 误放行）
    final hint = tab.launchedAgentHint;
    if (hint != null &&
        hint.isNotEmpty &&
        recent.toLowerCase().contains(hint.toLowerCase())) {
      return true;
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

  void _newTab({String? workingDirectory}) {
    setState(() {
      _tabs.add(_ShellTab(
        session: TerminalSession()
          ..start(workingDirectory: workingDirectory ?? _projectRoot),
      ));
      _activeIndex = _tabs.length - 1;
    });
    _registerHost();
  }

  void _closeTab(int index) {
    if (_tabs.length == 1) return; // 至少保留一个终端
    setState(() {
      _tabs.removeAt(index).session.dispose();
      if (_activeIndex >= _tabs.length) {
        _activeIndex = _tabs.length - 1;
      } else if (index < _activeIndex) {
        _activeIndex--;
      }
    });
    _registerHost();
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

  /// 在指定 Tab 执行快捷启动（cwd 已由会话启动目录处理时可只发命令）。
  void _executeOnTab(_ShellTab tab, StartCmd cmd, {required bool includeCd}) {
    final session = tab.session;
    final cwd = _resolveCwd(cmd.cwd);
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
  }

  Future<void> _runStartCmd(StartCmd cmd) async {
    // 已在智能体（非纯 PowerShell）中再点智能体按钮：勿往当前输入框塞命令，
    // 询问是否新开标签页启动。
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
      // 等新 Shell 就绪（start 内对 UNC/cwd 约有 400ms 延迟）后再发命令
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
                          tab.session,
                          fontSize: terminalFontSize,
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
              avatar: const Icon(Icons.play_arrow, size: 14, color: Colors.white70),
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
  /// 通过快捷启动打上的智能体线索（命令首词），供检测与 Tab 标题使用。
  String? launchedAgentHint;
  _ShellTab({required this.session});
}

/// 渲染单个会话的 TerminalView 并监听会话变更。
class _TerminalViewClient extends StatefulWidget {
  final TerminalSession session;
  final double fontSize;
  const _TerminalViewClient(this.session, {required this.fontSize});

  @override
  State<_TerminalViewClient> createState() => _TerminalViewClientState();
}

class _TerminalViewClientState extends State<_TerminalViewClient> {
  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: TerminalView(
        widget.session.terminal,
        hardwareKeyboardOnly: true,
        autofocus: true,
        textStyle: TerminalStyle(
          fontSize: widget.fontSize,
          fontFamily: 'Cascadia Mono, Consolas, Microsoft YaHei',
        ),
      ),
    );
  }
}
