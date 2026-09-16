import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flterm/flterm.dart' hide Scrollbar;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/agent_bridge.dart';
import '../../core/config.dart';
import '../../core/opencode_sessions.dart';
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
  bool _switchingSession = false;
  final LayerLink _sessionMenuLink = LayerLink();
  OverlayEntry? _sessionMenuEntry;
  bool _sessionMenuOpen = false;

  /// 新终端默认 cwd：项目 scripts 根目录。
  String? get _projectRoot {
    final root = AppConfig.instance.projectRoot;
    return root.isNotEmpty ? root : null;
  }

  bool _isOpencodeTab(_ShellTab tab) {
    final hint = tab.launchedAgentHint?.toLowerCase() ?? '';
    if (hint.contains('opencode')) return true;
    final cmd = tab.launchCommand?.toLowerCase() ?? '';
    return containsAgentToken(cmd, 'opencode');
  }

  bool get _showSessionEntry {
    if (_tabs.isEmpty) return false;
    return _isOpencodeTab(_tabs[_activeIndex]);
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
        opencodeServerPort: parseOpenCodeServerPort(t.launchCommand),
        currentOpenCodeSessionId: parseOpenCodeSessionFlag(t.launchCommand),
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
      var cmd = tab.launchCommand?.trim();
      if (cmd == null || cmd.isEmpty) continue;
      // OpenCode：恢复时重新占端口，直接 `opencode …` 发到 PowerShell。
      if (containsAgentToken(cmd, 'opencode') ||
          (tab.launchedAgentHint?.toLowerCase().contains('opencode') ??
              false)) {
        final prepared = await prepareOpenCodeTuiLaunch(cmd);
        cmd = prepared.command;
        tab.launchCommand = prepared.command;
        tab.opencodeServerPort = prepared.port;
        tab.currentOpenCodeSessionId = prepared.sessionId;
      }
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
    _dismissSessionMenu();
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
    _dismissSessionMenu();
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
    _dismissSessionMenu();
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

  Future<void> _executeOnTab(
    _ShellTab tab,
    StartCmd cmd, {
    required bool includeCd,
  }) async {
    final session = tab.session;
    final cwd = _resolveCwd(cmd.cwd);
    tab.cwd = cwd;

    late final String launchCmd;
    if (_isAgentLaunchCmd(cmd) &&
        containsAgentToken(cmd.command, 'opencode')) {
      // 直接 `opencode --hostname/--port …`，与系统终端一致；退出靠软恢复。
      final prepared = await prepareOpenCodeTuiLaunch(
        cmd.command,
      );
      launchCmd = prepared.command;
      tab.opencodeServerPort = prepared.port;
      tab.currentOpenCodeSessionId = prepared.sessionId;
    } else if (_isAgentLaunchCmd(cmd)) {
      launchCmd = cmd.command;
      tab.opencodeServerPort = null;
      tab.currentOpenCodeSessionId = null;
    } else {
      launchCmd = cmd.command;
      tab.opencodeServerPort = null;
      tab.currentOpenCodeSessionId = null;
    }

    tab.launchCommand = launchCmd;
    if (includeCd && cwd != null && cwd.isNotEmpty) {
      final line = Platform.isWindows
          ? powershellCdAndCommand(cwd, launchCmd)
          : 'cd "$cwd" && $launchCmd';
      session.sendCommand(line);
    } else {
      session.sendCommand(launchCmd);
    }
    session.syncViewportSize();
    if (_isAgentLaunchCmd(cmd)) {
      final token = cmd.command.trim().split(RegExp(r'\s+')).first;
      tab.launchedAgentHint = token.isNotEmpty ? token : cmd.name;
      setState(() {});
      final warmCwd = cwd ?? _projectRoot;
      if (warmCwd != null &&
          warmCwd.isNotEmpty &&
          containsAgentToken(cmd.command, 'opencode')) {
        unawaited(listOpenCodeSessions(cwd: warmCwd));
      }
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
      await _executeOnTab(tab, cmd, includeCd: false);
      return;
    }

    await _executeOnTab(_tabs[_activeIndex], cmd, includeCd: true);
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
          if (_showSessionEntry || startCmds.isNotEmpty)
            _buildBottomBar(context, startCmds),
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
                    _dismissSessionMenu();
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

  /// 左下角「会话」入口：锚在按钮上方弹出，不挡终端正文。
  Widget _buildSessionEntryButton(BuildContext context) {
    final busy = _switchingSession;
    return CompositedTransformTarget(
      link: _sessionMenuLink,
      child: Tooltip(
        message: busy ? '正在切换会话…' : 'OpenCode 会话',
        waitDuration: const Duration(milliseconds: 400),
        child: TextButton.icon(
          onPressed: busy
              ? null
              : () {
                  if (_sessionMenuOpen) {
                    _dismissSessionMenu();
                  } else {
                    unawaited(_openSessionMenu(context));
                  }
                },
          style: TextButton.styleFrom(
            foregroundColor: Colors.lightGreenAccent.withValues(alpha: 0.9),
            disabledForegroundColor: Colors.white38,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          icon: Icon(
            busy ? Icons.hourglass_top : Icons.forum_outlined,
            size: 14,
          ),
          label: Text(
            busy ? '切换中' : '会话',
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ),
    );
  }

  void _dismissSessionMenu() {
    _sessionMenuEntry?.remove();
    _sessionMenuEntry = null;
    if (_sessionMenuOpen && mounted) {
      setState(() => _sessionMenuOpen = false);
    } else {
      _sessionMenuOpen = false;
    }
  }

  Future<void> _openSessionMenu(BuildContext context) async {
    _dismissSessionMenu();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null || !mounted) return;

    setState(() => _sessionMenuOpen = true);

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final tab = _tabs[_activeIndex];
        return _OpenCodeSessionMenuOverlay(
          link: _sessionMenuLink,
          cwd: tab.cwd ?? _projectRoot ?? '',
          serverPort: tab.opencodeServerPort ??
              parseOpenCodeServerPort(tab.launchCommand),
          knownSessionId: tab.currentOpenCodeSessionId ??
              parseOpenCodeSessionFlag(tab.launchCommand),
          onActiveSessionResolved: (id) {
            if (!mounted || _tabs.isEmpty) return;
            final t = _tabs[_activeIndex];
            if (t.currentOpenCodeSessionId != id) {
              t.currentOpenCodeSessionId = id;
            }
          },
          onDismiss: _dismissSessionMenu,
          onSelect: (session) {
            _dismissSessionMenu();
            unawaited(_switchToOpenCodeSession(session));
          },
          onMessage: (msg) {
            if (mounted) showGlobalToast(context, msg);
          },
        );
      },
    );
    _sessionMenuEntry = entry;
    overlay.insert(entry);
  }

  bool _looksLikeShellPrompt(String recent) {
    final lines = const LineSplitter()
        .convert(recent)
        .map((e) => e.trimRight())
        .where((e) => e.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return false;
    final last = lines.last.trim();
    // PowerShell / cmd 常见提示符；避免把 opencode 的 `>` 输入行当成 shell。
    if (RegExp(r'^PS [^\n]*>\s*$').hasMatch(last)) return true;
    if (RegExp(r'^[A-Za-z]:\\[^>]*>\s*$').hasMatch(last)) return true;
    if (last == '>' || last.endsWith('\$') || last.endsWith('%')) {
      // 过宽，仅当近期出现 Set-Location / Windows PowerShell 横幅等时才信
      final lower = recent.toLowerCase();
      if (lower.contains('powershell') || lower.contains('set-location')) {
        return true;
      }
    }
    return false;
  }

  Future<void> _leaveOpenCodeToShell(TerminalSession session, {int? port}) async {
    // 优先按端口结束 OpenCode；宿主若被带走由软恢复接手。
    if (port != null && port > 0) {
      final killed = await killOpenCodeListeningOnPort(port);
      if (killed) {
        for (var i = 0; i < 25; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 160));
          if (!mounted) return;
          if (_looksLikeShellPrompt(session.recentBufferText(maxLines: 12))) {
            return;
          }
        }
      }
    }

    session.sendInterrupt();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    session.sendInput('q');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    session.sendRaw(const [0x0d]);

    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      if (_looksLikeShellPrompt(session.recentBufferText(maxLines: 12))) {
        return;
      }
      if (i == 8 || i == 14) {
        session.sendInterrupt();
      }
    }
  }

  Future<void> _switchToOpenCodeSession(OpenCodeSessionInfo info) async {
    if (_switchingSession || _tabs.isEmpty) return;
    final tab = _tabs[_activeIndex];
    if (!_isOpencodeTab(tab)) return;

    // 已是当前会话则无需切换
    final already = tab.currentOpenCodeSessionId ??
        parseOpenCodeSessionFlag(tab.launchCommand);
    if (already != null && already == info.id) {
      showGlobalToast(context, '已在「${info.title}」');
      return;
    }

    setState(() => _switchingSession = true);
    showGlobalToast(context, '正在切换到「${info.title}」…');

    try {
      final cwd = tab.cwd ?? _projectRoot;
      final port = tab.opencodeServerPort ??
          parseOpenCodeServerPort(tab.launchCommand);

      // 方案 A：同进程 TUI 内嵌 HTTP（普通 opencode --port，不是 serve）
      if (port != null && port > 0) {
        final result = await trySelectOpenCodeTuiSession(
          port: port,
          sessionId: info.id,
          directory: info.directory ?? cwd,
        );
        if (result.ok) {
          tab.currentOpenCodeSessionId = info.id;
          invalidateOpenCodeSessionCache();
          if (mounted) {
            showGlobalToast(context, '已切换到「${info.title}」');
          }
          return;
        }
        if (mounted) {
          showGlobalToast(
            context,
            '进程内切换失败（${result.reason}），正在重启…',
          );
        }
      } else if (mounted) {
        showGlobalToast(context, '当前 OpenCode 未绑定端口，正在重启…');
      }

      // 方案 B：结束 TUI 后同标签用 -s 再发 `opencode …`
      await _leaveOpenCodeToShell(tab.session, port: port);
      if (!mounted) return;

      final prepared = await prepareOpenCodeTuiLaunch(
        'opencode',
        sessionId: info.id,
      );
      final launch = prepared.command;
      if (cwd != null && cwd.isNotEmpty) {
        final line = Platform.isWindows
            ? powershellCdAndCommand(cwd, launch)
            : 'cd "$cwd" && $launch';
        tab.session.sendCommand(line);
      } else {
        tab.session.sendCommand(launch);
      }
      tab.session.syncViewportSize();
      tab.launchCommand = launch;
      tab.opencodeServerPort = prepared.port;
      tab.currentOpenCodeSessionId = info.id;
      tab.launchedAgentHint = 'opencode';
      invalidateOpenCodeSessionCache();
      _schedulePersist();
      _registerHost();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        showGlobalToast(context, '切换会话失败：$e');
      }
    } finally {
      if (mounted) setState(() => _switchingSession = false);
    }
  }

  Widget _buildBottomBar(BuildContext context, List<StartCmd> commands) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
      color: const Color(0xFF2D2D2D),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_showSessionEntry) ...[
            _buildSessionEntryButton(context),
            if (commands.isNotEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: SizedBox(
                  height: 18,
                  child: VerticalDivider(width: 1, color: Colors.white12),
                ),
              ),
          ],
          Expanded(
            child: commands.isEmpty
                ? const SizedBox.shrink()
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final cmd in commands) ...[
                          ActionChip(
                            avatar: const Icon(Icons.play_arrow,
                                size: 14, color: Colors.white70),
                            label: Text(cmd.name,
                                style: const TextStyle(fontSize: 11)),
                            backgroundColor: const Color(0xFF3D3D3D),
                            labelStyle: const TextStyle(color: Colors.white),
                            tooltip:
                                '${cmd.command}\n${cmd.cwd == CwdStrategy.selectedDir ? "cwd: 当前选中目录" : "cwd: 项目根"}',
                            onPressed: () => _runStartCmd(cmd),
                          ),
                          const SizedBox(width: 6),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 锚在左下角「会话」按钮上方的弹出列表（不常驻遮挡终端正文）。
class _OpenCodeSessionMenuOverlay extends StatefulWidget {
  const _OpenCodeSessionMenuOverlay({
    required this.link,
    required this.cwd,
    this.serverPort,
    this.knownSessionId,
    this.onActiveSessionResolved,
    required this.onDismiss,
    required this.onSelect,
    this.onMessage,
  });

  final LayerLink link;
  final String cwd;
  final int? serverPort;
  final String? knownSessionId;
  final ValueChanged<String>? onActiveSessionResolved;
  final VoidCallback onDismiss;
  final ValueChanged<OpenCodeSessionInfo> onSelect;
  final ValueChanged<String>? onMessage;

  @override
  State<_OpenCodeSessionMenuOverlay> createState() =>
      _OpenCodeSessionMenuOverlayState();
}

class _OpenCodeSessionMenuOverlayState extends State<_OpenCodeSessionMenuOverlay> {
  List<OpenCodeSessionInfo>? _items;
  String? _error;
  bool _loading = true;
  String? _currentSessionId;
  String? _editingId;
  bool _renaming = false;
  final TextEditingController _filter = TextEditingController();
  final TextEditingController _edit = TextEditingController();
  final FocusNode _editFocus = FocusNode();
  final FocusNode _panelFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _currentSessionId = widget.knownSessionId;
    _editFocus.onKeyEvent = _onEditKeyEvent;
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _panelFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _editFocus.onKeyEvent = null;
    _filter.dispose();
    _edit.dispose();
    _editFocus.dispose();
    _panelFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  KeyEventResult _onEditKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _handleEscape();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _handleEscape() {
    if (_renaming) return;
    if (_editingId != null) {
      _cancelInlineRename();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _panelFocus.requestFocus();
      });
      return;
    }
    widget.onDismiss();
  }

  void _toast(String msg) => widget.onMessage?.call(msg);

  void _beginInlineRename(OpenCodeSessionInfo session) {
    if (_renaming) return;
    setState(() {
      _editingId = session.id;
      _edit.text = session.title;
      _edit.selection = TextSelection(
        baseOffset: 0,
        extentOffset: session.title.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _cancelInlineRename() {
    if (_renaming) return;
    if (_editingId == null) return;
    _editFocus.unfocus();
    setState(() => _editingId = null);
  }

  Future<void> _commitInlineRename(OpenCodeSessionInfo session) async {
    if (_renaming) return;
    final next = _edit.text.trim();
    if (next.isEmpty) {
      _toast('标题不能为空');
      return;
    }
    if (next == session.title) {
      setState(() => _editingId = null);
      return;
    }

    setState(() => _renaming = true);
    try {
      final updated = await renameOpenCodeSession(
        sessionId: session.id,
        title: next,
        port: widget.serverPort,
      );
      if (!mounted) return;
      final title =
          updated.title.trim().isEmpty ? next : updated.title.trim();
      setState(() {
        final list = List<OpenCodeSessionInfo>.of(_items ?? const []);
        final idx = list.indexWhere((e) => e.id == session.id);
        if (idx >= 0) {
          list[idx] = list[idx].copyWith(
            title: title,
            updated: updated.updated ?? DateTime.now(),
          );
        }
        _items = list;
        _editingId = null;
        _renaming = false;
      });
      _toast('已重命名为「$title」');
    } catch (e) {
      if (!mounted) return;
      setState(() => _renaming = false);
      _toast('重命名失败：$e');
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      _editingId = null;
    });
    try {
      final port = widget.serverPort;
      final liveFuture = (port != null && port > 0)
          ? fetchOpenCodeActiveSessionId(
              port: port,
              directory: widget.cwd.isEmpty ? null : widget.cwd,
            )
          : Future<String?>.value(null);
      final results = await Future.wait<Object?>([
        listOpenCodeSessions(cwd: widget.cwd, forceRefresh: forceRefresh),
        liveFuture,
      ]);
      if (!mounted) return;
      final list = results[0] as List<OpenCodeSessionInfo>;
      final liveId = results[1] as String?;
      final current = liveId ?? widget.knownSessionId ?? _currentSessionId;
      if (liveId != null && liveId.isNotEmpty) {
        widget.onActiveSessionResolved?.call(liveId);
      }
      setState(() {
        _items = list;
        _currentSessionId = current;
        _loading = false;
      });
      _scrollCurrentIntoView();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _scrollCurrentIntoView() {
    final id = _currentSessionId;
    if (id == null || id.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final items = _visible;
      final idx = items.indexWhere((s) => s.id == id);
      if (idx <= 0) return;
      final offset = (idx * 52.0).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(offset);
    });
  }

  List<OpenCodeSessionInfo> get _visible {
    final all = _items ?? const <OpenCodeSessionInfo>[];
    final q = _filter.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? List<OpenCodeSessionInfo>.of(all)
        : [
            for (final s in all)
              if (s.title.toLowerCase().contains(q) ||
                  s.id.toLowerCase().contains(q))
                s,
          ];
    final current = _currentSessionId;
    if (current == null || current.isEmpty) return filtered;
    final idx = filtered.indexWhere((s) => s.id == current);
    if (idx <= 0) return filtered;
    final cur = filtered.removeAt(idx);
    filtered.insert(0, cur);
    return filtered;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final editing = _editingId != null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
      },
      child: Focus(
        focusNode: _panelFocus,
        autofocus: true,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (editing) {
                    _cancelInlineRename();
                    return;
                  }
                  widget.onDismiss();
                },
                child: const ColoredBox(color: Colors.transparent),
              ),
            ),
            CompositedTransformFollower(
              link: widget.link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topLeft,
              followerAnchor: Alignment.bottomLeft,
              offset: const Offset(0, -4),
              child: Material(
                elevation: 10,
                color: const Color(0xFF2B2B2B),
                borderRadius: BorderRadius.circular(8),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: 280,
                    maxWidth: 340,
                    maxHeight: (size.height * 0.55).clamp(220.0, 420.0),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '项目会话',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  if (widget.cwd.trim().isNotEmpty)
                                    Text(
                                      widget.cwd,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white30,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '刷新',
                              onPressed: (_loading || _renaming || editing)
                                  ? null
                                  : () => _load(forceRefresh: true),
                              icon: const Icon(Icons.refresh, size: 16),
                              color: Colors.white54,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 28,
                                minHeight: 28,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                        child: TextField(
                          controller: _filter,
                          enabled: !editing && !_renaming,
                          onChanged: (_) => setState(() {}),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: '筛选会话名称…',
                            hintStyle: const TextStyle(
                              fontSize: 12,
                              color: Colors.white38,
                            ),
                            filled: true,
                            fillColor: Colors.black26,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white12),
                      Expanded(child: _buildBody()),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _error!,
          style: const TextStyle(fontSize: 12, color: Colors.redAccent),
        ),
      );
    }
    final items = _visible;
    if (items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            widget.cwd.trim().isEmpty
                ? '当前项目暂无会话'
                : '当前目录下暂无 OpenCode 会话',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.white38),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final s = items[index];
        final time = formatOpenCodeSessionTime(s.updated);
        final isCurrent =
            _currentSessionId != null && s.id == _currentSessionId;
        final isEditing = _editingId == s.id;
        return Material(
          color: isCurrent || isEditing
              ? Colors.lightGreenAccent.withValues(alpha: 0.12)
              : Colors.transparent,
          child: InkWell(
            onTap: _renaming
                ? null
                : () {
                    if (_editingId != null) {
                      // 编辑中点其它行：只取消编辑，不立刻切换会话。
                      if (_editingId != s.id) _cancelInlineRename();
                      return;
                    }
                    widget.onSelect(s);
                  },
            onLongPress: (_renaming || _editingId != null)
                ? null
                : () => _beginInlineRename(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: isEditing
                            ? TextField(
                                controller: _edit,
                                focusNode: _editFocus,
                                enabled: !_renaming,
                                autofocus: true,
                                maxLength: 120,
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  counterText: '',
                                  hintText: '会话标题',
                                  hintStyle: TextStyle(color: Colors.white38),
                                  filled: true,
                                  fillColor: Colors.black38,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) =>
                                    unawaited(_commitInlineRename(s)),
                                onTapOutside: (_) => _cancelInlineRename(),
                              )
                            : Text(
                                s.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                      ),
                      if (isCurrent && !isEditing) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.lightGreenAccent
                                .withValues(alpha: 0.22),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '当前',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.lightGreenAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      if (isEditing)
                        TextFieldTapRegion(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                onPressed: _renaming
                                    ? null
                                    : () => unawaited(_commitInlineRename(s)),
                                icon: _renaming
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.check, size: 16),
                                color: Colors.lightGreenAccent,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                              ),
                              IconButton(
                                onPressed:
                                    _renaming ? null : _cancelInlineRename,
                                icon: const Icon(Icons.close, size: 16),
                                color: Colors.white54,
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        // 不用 Tooltip：Overlay 内 Tooltip 移出时会触发 layout 断言闪红屏。
                        IconButton(
                          onPressed:
                              _renaming ? null : () => _beginInlineRename(s),
                          icon: const Icon(Icons.edit_outlined, size: 14),
                          color: Colors.white38,
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                        ),
                    ],
                  ),
                  if (!isEditing && time.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white38,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
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

  /// 当前 OpenCode TUI 内嵌 HTTP 端口（`opencode --port`，非 serve）。
  int? opencodeServerPort;

  /// 我们已知的当前会话（启动 `-s` / 切换成功 / HTTP 探活回写）。
  String? currentOpenCodeSessionId;

  _ShellTab({
    required this.session,
    this.cwd,
    this.launchCommand,
    this.launchedAgentHint,
    this.opencodeServerPort,
    this.currentOpenCodeSessionId,
  }) {
    session.onHostExited = () {
      opencodeServerPort = null;
      currentOpenCodeSessionId = null;
      launchedAgentHint = null;
    };
  }

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
