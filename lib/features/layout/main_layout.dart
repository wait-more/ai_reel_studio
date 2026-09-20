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
    final scheme = Theme.of(context).colorScheme;
    final mode = ref.watch(contentModeProvider);
    final tabCount = ref.watch(openTabsProvider).length;
    return Container(
      height: 46,
      color: scheme.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3),
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
          ),
          const Spacer(),
        ],
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
    final fg = active ? scheme.onPrimary : scheme.onSurfaceVariant;
    final badgeBg = active
        ? scheme.onPrimary.withValues(alpha: 0.22)
        : scheme.surfaceContainerHighest;
    final badgeFg = active ? scheme.onPrimary : scheme.onSurfaceVariant;

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
        borderRadius: BorderRadius.circular(8),
        hoverColor: active
            ? scheme.onPrimary.withValues(alpha: 0.08)
            : scheme.onSurface.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: active ? scheme.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.1,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: fg,
                  letterSpacing: active ? 0.2 : 0,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
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
    return Container(
      height: kColumnTopBarHeight,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
          ),
          bottom: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
          ),
        ),
      ),
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
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
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
