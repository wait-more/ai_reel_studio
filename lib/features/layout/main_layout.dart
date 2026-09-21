import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flterm/flterm.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';
import '../../core/agent_bridge.dart';
import '../../core/editor_tab_menu.dart';
import '../../core/fs_context_menu.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
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

class _MainLayoutState extends ConsumerState<MainLayout> with WindowListener {
  double _treeWidth = 280;
  double? _shellWidth; // null = 未初始化，首次布局时默认中间栏/Shell = 6/4
  WorkspaceSnapshot? _lastWorkspaceSnap;
  int _fsShortcutNonce = 0;
  bool _closePromptOpen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    final snap = _lastWorkspaceSnap;
    if (snap != null) {
      // 关闭前立刻落盘，避免去抖窗口内退出丢失最后一次状态
      WorkspaceMemory.instance.saveNow(snap);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _allowWindowClose() async {
    final snap = _lastWorkspaceSnap;
    if (snap != null) {
      try {
        await WorkspaceMemory.instance.saveNow(snap);
      } catch (_) {}
    }
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  Future<void> _handleWindowClose() async {
    // setPreventClose(false) 后再 close 会再次触发本回调，直接放行。
    final preventClose = await windowManager.isPreventClose();
    if (!preventClose) return;
    if (!mounted || _closePromptOpen) return;

    final dirty = ref.read(dirtyFilesProvider);
    if (dirty.isEmpty) {
      await _allowWindowClose();
      return;
    }

    _closePromptOpen = true;
    try {
      final paths = dirty.toList()..sort();
      final names = paths.map(p.basename).toList();

      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          final scheme = Theme.of(ctx).colorScheme;
          final show = names.length <= 4 ? names : names.take(3).toList();
          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
            actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            title: Text(
              names.length == 1 ? '文档未保存' : '${names.length} 个文档未保存',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final name in show)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (names.length > 4)
                    Text(
                      '另有 ${names.length - 3} 个…',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.outline,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'discard'),
                child: const Text('不保存'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, 'save'),
                child: Text(names.length == 1 ? '保存' : '全部保存'),
              ),
            ],
          );
        },
      );

      if (!mounted) return;
      if (action == 'save') {
        await _saveAllDirty();
        if (!mounted) return;
        if (ref.read(dirtyFilesProvider).isEmpty) {
          await _allowWindowClose();
        } else {
          showGlobalToast(context, '部分文档保存失败');
        }
      } else if (action == 'discard') {
        // 放弃修改并留在程序内；脏标记清掉后再次关闭即可退出。
        ref.read(discardUnsavedEditsTickProvider.notifier).state++;
        ref.read(dirtyFilesProvider.notifier).state = {};
        ref.read(draftContentsProvider.notifier).state = {};
        await Future<void>.delayed(const Duration(milliseconds: 120));
        if (!mounted) return;
        ref.read(dirtyFilesProvider.notifier).state = {};
        showGlobalToast(context, '已放弃修改');
      }
    } finally {
      _closePromptOpen = false;
    }
  }

  Future<void> _saveAllDirty() async {
    final dirty = ref.read(dirtyFilesProvider).toList();
    final saves = ref.read(saveActionsProvider);
    for (final path in dirty) {
      final save = saves[path];
      if (save != null) {
        try {
          await save();
        } catch (_) {}
        continue;
      }
      final draft = ref.read(draftContentsProvider)[path];
      if (draft == null) {
        ref.read(dirtyFilesProvider.notifier).update((s) {
          if (!s.contains(path)) return s;
          return {...s}..remove(path);
        });
        continue;
      }
      try {
        await File(path).writeAsString(draft);
        ref.read(dirtyFilesProvider.notifier).update((s) {
          if (!s.contains(path)) return s;
          return {...s}..remove(path);
        });
        ref.read(draftContentsProvider.notifier).update((m) {
          if (!m.containsKey(path)) return m;
          return {...m}..remove(path);
        });
      } catch (_) {}
    }
  }

  void _persistWorkspace() {
    final snap = WorkspaceSnapshot(
      expandedPaths: ref.read(expandedTreePathsProvider),
      openTabs: ref.read(openTabsProvider),
      previewTabPath: ref.read(previewTabPathProvider),
      selectedFile: ref.read(selectedFileProvider),
      selectedDir: ref.read(selectedDirProvider),
      contentMode: ref.read(contentModeProvider),
      fileViews: ref.read(editorViewStatesProvider),
    );
    _lastWorkspaceSnap = snap;
    WorkspaceMemory.instance.scheduleSave(snap);
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

  /// 终端里的 Ctrl+C 必须进 PTY，不能被文件「复制」吃掉。
  bool _isInTerminal() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is TerminalView) return true;
    return ctx.findAncestorWidgetOfExactType<TerminalView>() != null;
  }

  /// 文件操作快捷键：在 [Focus.onKeyEvent] 里处理。
  /// 打字/弹窗时必须返回 [KeyEventResult.ignored]，否则会吞掉事件，
  /// 导致文档编辑器的 Ctrl+C/V/A、Delete、Enter 等默认快捷键失效。
  KeyEventResult _handleFsKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_isTypingInTextField() || _isInModalDialog() || _isInTerminal()) {
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
      if (dismissFsContextMenu() || dismissEditorTabMenu()) {
        return KeyEventResult.handled;
      }
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
    ref.listen(previewTabPathProvider, (_, __) => _persistWorkspace());
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
        final maxWidth = constraints.maxWidth;
        // 首次布局：中间栏 / Shell = 6 / 4，并保证中间栏不低于最小宽度。
        if (_shellWidth == null) {
          final dividers = shellVisible ? _dividerWidth * 2 : _dividerWidth;
          final avail = maxWidth - _treeWidth - dividers;
          _shellWidth = avail * 0.4;
        }
        _ensurePanelWidths(maxWidth, shellVisible: shellVisible);
        final shellW = shellVisible ? (_shellWidth ?? 0) : 0.0;
        final dividers = shellVisible ? _dividerWidth * 2 : _dividerWidth;
        final centerW = (maxWidth - _treeWidth - shellW - dividers)
            .clamp(kCenterPanelMinWidth, maxWidth);

        return Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: _treeWidth,
                child: const ProjectTree(),
              ),
              _buildDivider(
                resizeTree: true,
                maxWidth: maxWidth,
              ),
              SizedBox(
                width: centerW,
                child: Column(
                  children: [
                    _buildTopBar(context),
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
              if (shellVisible)
                _buildDivider(
                  resizeTree: false,
                  maxWidth: maxWidth,
                ),
              SizedBox(
                width: shellW,
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

  static const double _treeMinWidth = 180;
  static const double _treeMaxWidth = 500;
  static const double _shellMinWidth = 280;
  static const double _dividerWidth = 3;

  /// 拖拽与窗口缩放后，保证中间栏宽度 ≥ 左右按钮块贴齐时的宽度。
  void _ensurePanelWidths(double maxWidth, {required bool shellVisible}) {
    final dividers = shellVisible ? _dividerWidth * 2 : _dividerWidth;
    _treeWidth = _treeWidth.clamp(_treeMinWidth, _treeMaxWidth);

    if (!shellVisible) {
      // 仅目录树 + 中间栏：目录树不能把中间栏压穿。
      final maxTree = maxWidth - _dividerWidth - kCenterPanelMinWidth;
      _treeWidth = _treeWidth.clamp(
        _treeMinWidth,
        maxTree < _treeMinWidth ? _treeMinWidth : maxTree,
      );
      return;
    }

    var shell = _shellWidth ?? _shellMinWidth;
    // 先按当前目录树，算出 Shell 上限。
    var maxShell = maxWidth - _treeWidth - dividers - kCenterPanelMinWidth;
    if (maxShell < _shellMinWidth) {
      // Shell 已顶到最小，再压目录树。
      final maxTree =
          maxWidth - _shellMinWidth - dividers - kCenterPanelMinWidth;
      _treeWidth = _treeWidth.clamp(
        _treeMinWidth,
        maxTree < _treeMinWidth ? _treeMinWidth : maxTree,
      );
      maxShell = maxWidth - _treeWidth - dividers - kCenterPanelMinWidth;
    }
    if (maxShell <= 0) {
      shell = 0;
    } else if (maxShell < _shellMinWidth) {
      shell = maxShell;
    } else {
      shell = shell.clamp(_shellMinWidth, maxShell);
    }
    _shellWidth = shell;
  }

  Widget _buildModeSwitcher(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mode = ref.watch(contentModeProvider);
    final tabCount = ref.watch(openTabsProvider).length;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _modeSegment(
              context,
              value: 'assets',
              label: '素材',
              icon: Icons.photo_library_outlined,
              current: mode,
            ),
            _modeSegment(
              context,
              value: 'editor',
              label: '文档',
              icon: Icons.article_outlined,
              current: mode,
              count: tabCount > 0 ? tabCount : null,
            ),
            _modeSegment(
              context,
              value: 'comfy',
              label: '生成',
              icon: Icons.auto_awesome_outlined,
              current: mode,
            ),
          ],
        ),
      ),
    );
  }

  Widget _modeSegment(
    BuildContext context, {
    required String value,
    required String label,
    required IconData icon,
    required String current,
    int? count,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final active = current == value;
    final fg = active ? scheme.primary : scheme.onSurfaceVariant;
    final badgeBg = active
        ? scheme.primary.withValues(alpha: 0.14)
        : scheme.surfaceContainerHighest;
    final badgeFg = active ? scheme.primary : scheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          ref.read(contentModeProvider.notifier).state = value;
          if (value == 'editor') {
            final tabs = ref.read(openTabsProvider);
            final sel = ref.read(selectedFileProvider);
            if (tabs.isNotEmpty && (sel == null || !tabs.contains(sel))) {
              ref.read(selectedFileProvider.notifier).state = tabs.last;
            }
          }
        },
        mouseCursor: SystemMouseCursors.click,
        borderRadius: BorderRadius.circular(6),
        hoverColor: scheme.onSurface.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: active ? scheme.surfaceContainerLowest : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? scheme.primary : Colors.transparent,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.1,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: badgeBg,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    '$count',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.15,
                      fontWeight: FontWeight.w700,
                      color: badgeFg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget topBtn({
      required Widget icon,
      required VoidCallback? onPressed,
      required String tooltip,
    }) {
      final enabled = onPressed != null;
      return Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            borderRadius: BorderRadius.circular(6),
            hoverColor: scheme.onSurface.withValues(alpha: 0.10),
            child: SizedBox(
              width: 32,
              height: 32,
              child: IconTheme.merge(
                data: IconThemeData(
                  size: 18,
                  color: enabled
                      ? scheme.onSurface
                      : scheme.onSurface.withValues(alpha: 0.38),
                ),
                child: Center(child: icon),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      height: kColumnTopBarHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
          ),
          bottom: BorderSide(
            color: Theme.of(context).dividerColor,
          ),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'AIReelStudio',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
          ),
          _buildModeSwitcher(context),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  topBtn(
                    icon: const Icon(Icons.search, size: 18),
                    onPressed: () => showGlobalSearch(context),
                    tooltip: '全局搜索 (Ctrl+P)',
                  ),
                  const SizedBox(width: 4),
                  topBtn(
                    icon: Icon(
                      ref.watch(shellVisibleProvider)
                          ? Icons.terminal
                          : Icons.terminal_outlined,
                      size: 18,
                    ),
                    onPressed: () =>
                        ref.read(shellVisibleProvider.notifier).state =
                            !ref.read(shellVisibleProvider),
                    tooltip: '终端',
                  ),
                  const SizedBox(width: 4),
                  topBtn(
                    icon: const Icon(Icons.settings, size: 18),
                    onPressed: () => _openSettings(context),
                    tooltip: '设置',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDivider({
    required bool resizeTree,
    required double maxWidth,
  }) {
    final shellVisible = ref.read(shellVisibleProvider);
    return _ColumnSplitter(
      onPanUpdate: (details) {
        setState(() {
          if (resizeTree) {
            final shellW = shellVisible ? (_shellWidth ?? _shellMinWidth) : 0.0;
            final dividers =
                shellVisible ? _dividerWidth * 2 : _dividerWidth;
            final maxTree =
                maxWidth - shellW - dividers - kCenterPanelMinWidth;
            final treeCap = maxTree < _treeMinWidth
                ? _treeMinWidth
                : (maxTree > _treeMaxWidth ? _treeMaxWidth : maxTree);
            _treeWidth = (_treeWidth + details.delta.dx).clamp(
              _treeMinWidth,
              treeCap,
            );
          } else {
            final maxShell = maxWidth -
                _treeWidth -
                _dividerWidth * 2 -
                kCenterPanelMinWidth;
            _shellWidth = ((_shellWidth ?? 400) - details.delta.dx).clamp(
              0.0,
              maxShell < 0 ? 0.0 : maxShell,
            );
          }
          _ensurePanelWidths(maxWidth, shellVisible: shellVisible);
        });
      },
    );
  }

  void _openSettings(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => const SettingsPage(),
    );
  }
}

/// 平时几乎看不见，悬停时用强调色标出可拖区域。
class _ColumnSplitter extends StatefulWidget {
  const _ColumnSplitter({required this.onPanUpdate});

  final GestureDragUpdateCallback onPanUpdate;

  @override
  State<_ColumnSplitter> createState() => _ColumnSplitterState();
}

class _ColumnSplitterState extends State<_ColumnSplitter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onPanUpdate: widget.onPanUpdate,
        child: Container(
          width: 3,
          color: _hover
              ? scheme.primary.withValues(alpha: 0.85)
              : scheme.outlineVariant.withValues(alpha: 0.45),
        ),
      ),
    );
  }
}
