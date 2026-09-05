import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

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
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.session.dispose();
    }
    super.dispose();
  }

  void _newTab() {
    setState(() {
      _tabs.add(_ShellTab(
        session: TerminalSession()..start(workingDirectory: _projectRoot),
      ));
      _activeIndex = _tabs.length - 1;
    });
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

  void _runStartCmd(StartCmd cmd) {
    final session = _tabs[_activeIndex].session;
    final cwd = _resolveCwd(cmd.cwd);
    if (cwd != null && cwd.isNotEmpty) {
      final cd = Platform.isWindows
          ? 'Set-Location -LiteralPath "$cwd"; ${cmd.command}'
          : 'cd "$cwd" && ${cmd.command}';
      session.sendCommand(cd);
    } else {
      session.sendCommand(cmd.command);
    }
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
                return InkWell(
                  onTap: () => setState(() => _activeIndex = index),
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
                        Text(
                          '终端 ${index + 1}',
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
              tooltip: '${cmd.command}\n${cmd.cwd == CwdStrategy.selectedDir ? "cwd: 当前选中目录" : "cwd: 项目根"}',
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
