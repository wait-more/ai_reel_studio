import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/agent_bridge.dart';
import '../../core/providers.dart';
import '../../core/workspace_memory.dart';
import '../settings/settings_page.dart';
import '../tree/project_tree.dart';
import '../editor/markdown_editor.dart';
import '../asset/asset_grid.dart';
import '../comfy/comfy_panel.dart';
import '../search/global_search.dart';
import '../shell/shell_panel.dart';

class MainLayout extends ConsumerStatefulWidget {
  const MainLayout({super.key});

  @override
  ConsumerState<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends ConsumerState<MainLayout> {
  double _treeWidth = 280;
  double? _shellWidth; // null = 未初始化，首次布局时默认中间栏/Shell = 6/4
  WorkspaceSnapshot? _lastWorkspaceSnap;
  int _fsShortcutNonce = 0;

  void _persistWorkspace() {
    final snap = WorkspaceSnapshot(
      expandedPaths: ref.read(expandedTreePathsProvider),
      openTabs: ref.read(openTabsProvider),
      selectedFile: ref.read(selectedFileProvider),
      selectedDir: ref.read(selectedDirProvider),
      contentMode: ref.read(contentModeProvider),
      fileViews: ref.read(editorViewStatesProvider),
    );
    _lastWorkspaceSnap = snap;
    WorkspaceMemory.instance.scheduleSave(snap);
  }

  @override
  void dispose() {
    final snap = _lastWorkspaceSnap;
    if (snap != null) {
      // 关闭前立刻落盘，避免去抖窗口内退出丢失最后一次状态
      WorkspaceMemory.instance.saveNow(snap);
    }
    super.dispose();
  }

  void _sendAgentReference() {
    sendAgentReferenceToShell(context, ref);
  }

  bool _isTypingInTextField() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText ||
        ctx.widget is TextField ||
        ctx.widget is TextFormField) {
      return true;
    }
    var typing = false;
    ctx.visitAncestorElements((element) {
      final w = element.widget;
      if (w is EditableText || w is TextField || w is TextFormField) {
        typing = true;
        return false;
      }
      return true;
    });
    return typing;
  }

  bool _isInModalDialog() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorWidgetOfExactType<Dialog>() != null ||
        ctx.findAncestorWidgetOfExactType<AlertDialog>() != null;
  }

  /// 文件操作快捷键：在 [Focus.onKeyEvent] 里处理。
  /// 打字/弹窗时必须返回 [KeyEventResult.ignored]，否则会吞掉事件，
  /// 导致文档编辑器的 Ctrl+C/V/A、Delete、Enter 等默认快捷键失效。
  KeyEventResult _handleFsKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_isTypingInTextField() || _isInModalDialog()) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (key == LogicalKeyboardKey.delete) {
      _dispatchFsShortcut('delete');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      _dispatchFsShortcut('rename');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _dispatchFsShortcut('open');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _dispatchFsShortcut('escape');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _dispatchFsShortcut('backspace');
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyC) {
      _dispatchFsShortcut('copy');
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyX) {
      _dispatchFsShortcut('cut');
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyV) {
      _dispatchFsShortcut('paste');
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyA) {
      _dispatchFsShortcut('selectAll');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 文件操作快捷键由主布局统一发出，避免焦点不在树/物料子树时收不到键。
  void _dispatchFsShortcut(String action) {
    if (_isTypingInTextField()) return;
    // 确认框等弹窗打开时，把 Enter/快捷键留给弹窗按钮。
    if (_isInModalDialog()) return;
    var pane = ref.read(fsShortcutPaneProvider);
    if (pane == FsShortcutPane.none) {
      if (ref.read(treeSelectionProvider).isNotEmpty) {
        pane = FsShortcutPane.tree;
      } else if (ref.read(contentModeProvider) == 'assets') {
        pane = FsShortcutPane.assets;
      } else {
        return;
      }
    }
    ref.read(fsShortcutRequestProvider.notifier).state = FsShortcutRequest(
      action: action,
      pane: pane,
      nonce: ++_fsShortcutNonce,
    );
  }

  @override
  Widget build(BuildContext context) {
    final shellVisible = ref.watch(shellVisibleProvider);
    final agentChord = ref.watch(sendAgentRefChordProvider);

    // 中间栏 + 目录树展开状态变更 → 去抖持久化
    ref.listen(openTabsProvider, (_, __) => _persistWorkspace());
    ref.listen(selectedFileProvider, (_, __) => _persistWorkspace());
    ref.listen(selectedDirProvider, (_, __) => _persistWorkspace());
    ref.listen(contentModeProvider, (_, __) => _persistWorkspace());
    ref.listen(expandedTreePathsProvider, (_, __) => _persistWorkspace());
    ref.listen(editorViewStatesProvider, (_, __) => _persistWorkspace());

    return CallbackShortcuts(
      bindings: {
        // Ctrl+P：全局搜索（编辑器内也可用）
        const SingleActivator(LogicalKeyboardKey.keyP, control: true):
            (() {
          showGlobalSearch(context);
        }),
        // 当前文件/选区引用 → 智能体输入区（不回车）；组合键可在设置中改
        agentChord.toActivator(): _sendAgentReference,
      },
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleFsKeyEvent,
        child: LayoutBuilder(
      builder: (context, constraints) {
        // 首次布局：中间栏 / Shell = 6 / 4
        if (_shellWidth == null) {
          const dividerW = 6.0; // 两处分隔条
          final avail = constraints.maxWidth - _treeWidth - dividerW;
          _shellWidth = avail * 0.4;
          if (_shellWidth! < 280) _shellWidth = 280;
        }

        return Scaffold(
          body: Row(
            children: [
              // Left panel: Project tree
              SizedBox(
                width: _treeWidth,
                child: const ProjectTree(),
              ),
              _buildDivider(resizeTree: true),
              // Center panel: Editor tabs OR asset grid (both kept alive)
              Expanded(
                child: Column(
                  children: [
                    _buildTopBar(context),
                    _buildModeBar(context),
                    Expanded(
                      child: IndexedStack(
                        index: switch (ref.watch(contentModeProvider)) {
                          'editor' => 1,
                          'comfy' => 2,
                          _ => 0,
                        },
                        children: const [
                          AssetGridView(),
                          MarkdownEditor(),
                          ComfyPanel(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (shellVisible) _buildDivider(resizeTree: false),
              // 始终挂载 ShellPanel，折叠时宽度为 0，避免销毁 PTY / 智能体会话
              SizedBox(
                width: shellVisible ? _shellWidth : 0,
                child: const ShellPanel(),
              ),
            ],
          ),
        );
      },
        ),
      ),
    );
  }

  Widget _buildModeBar(BuildContext context) {
    final mode = ref.watch(contentModeProvider);
    final tabCount = ref.watch(openTabsProvider).length;
    return Container(
      height: 34,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _modeChip(context, 'assets', '素材', mode, ''),
          const SizedBox(width: 8),
          _modeChip(context, 'editor', '文档', mode, tabCount > 0 ? ' $tabCount' : ''),
          const SizedBox(width: 8),
          _modeChip(context, 'comfy', '生成', mode, ''),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _modeChip(BuildContext context, String value, String label,
      String current, String badge) {
    final active = current == value;
    return InkWell(
      onTap: () =>
          ref.read(contentModeProvider.notifier).state = value,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Theme.of(context).colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$label$badge',
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 40,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () {},
            tooltip: '菜单',
          ),
          const SizedBox(width: 4),
          Text(
            'AIReelStudio',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.search, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => showGlobalSearch(context),
            tooltip: '全局搜索 (Ctrl+P)',
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: Icon(
              ref.watch(shellVisibleProvider)
                  ? Icons.terminal
                  : Icons.terminal_outlined,
              size: 18,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () =>
                ref.read(shellVisibleProvider.notifier).state =
                    !ref.read(shellVisibleProvider),
            tooltip: '终端',
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.settings, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            onPressed: () => _openSettings(context),
            tooltip: '设置',
          ),
        ],
      ),
    );
  }

  Widget _buildDivider({required bool resizeTree}) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          if (resizeTree) {
            _treeWidth = (_treeWidth + details.delta.dx).clamp(180.0, 500.0);
          } else {
            // Shell 面板只限制最小宽度，允许无限放大到占满窗口
            _shellWidth = (_shellWidth ?? 400) - details.delta.dx;
            if (_shellWidth! < 280) _shellWidth = 280;
          }
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: Container(
          width: 3,
          color: Theme.of(context).dividerColor.withOpacity(0.2),
        ),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const SettingsPage(),
    );
  }
}
