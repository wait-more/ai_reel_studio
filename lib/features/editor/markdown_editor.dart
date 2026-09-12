import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';
import '../../core/agent_bridge.dart';
import '../../core/comfy_prompt_bridge.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../../core/workspace_memory.dart';
import 'editor_selection_util.dart';
import 'markdown_code_theme.dart';
import 'markdown_outline.dart';
import 'outline_rail.dart';
import 're_editor_context_menu.dart';

/// 大纲是否钉住（会话内保持）。
final outlinePinnedProvider = StateProvider<bool>((ref) => false);

class MarkdownEditor extends ConsumerWidget {
  const MarkdownEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(openTabsProvider);
    final selectedFile = ref.watch(selectedFileProvider);

    // Tab 仍在但 selectedFile 丢失/不在列表（例如曾 Ctrl 选树文件）时，回落到有效 Tab。
    if (tabs.isNotEmpty &&
        (selectedFile == null || !tabs.contains(selectedFile))) {
      final fallback = tabs.last;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final t = ref.read(openTabsProvider);
        final s = ref.read(selectedFileProvider);
        if (t.isEmpty) return;
        if (s == null || !t.contains(s)) {
          ref.read(selectedFileProvider.notifier).state =
              t.contains(fallback) ? fallback : t.last;
        }
      });
    }

    if (tabs.isEmpty) {
      return _emptyState(context);
    }

    return Column(
      children: [
        _buildTabBar(context, tabs, selectedFile, ref),
        Expanded(
          child: selectedFile != null && tabs.contains(selectedFile)
              ? _FileEditor(key: ValueKey(selectedFile), path: selectedFile)
              : _emptyState(context),
        ),
      ],
    );
  }

  Widget _buildTabBar(
      BuildContext context, List<String> tabs, String? selected, WidgetRef ref) {
    return Container(
      height: 36,
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        buildDefaultDragHandles: false,
        onReorder: (oldIndex, newIndex) {
          final list = List<String>.of(ref.read(openTabsProvider));
          if (newIndex > oldIndex) newIndex -= 1;
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
          ref.read(openTabsProvider.notifier).state = list;
        },
        proxyDecorator: (child, index, animation) {
          return AnimatedBuilder(
            animation: animation,
            builder: (context, child) {
              final t = Curves.easeInOut.transform(animation.value);
              return Material(
                elevation: 2 + 4 * t,
                borderRadius: BorderRadius.circular(6),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: child,
              );
            },
            child: child,
          );
        },
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final path = tabs[index];
          final isSelected = path == selected;
          return ReorderableDragStartListener(
            key: ValueKey(path),
            index: index,
            child: InkWell(
              onTap: () =>
                  ref.read(selectedFileProvider.notifier).state = path,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.15)
                      : null,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      path.split(Platform.pathSeparator).last,
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => _closeTab(context, path, ref),
                      child: const Icon(Icons.close, size: 14, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _forceCloseTab(BuildContext context, String path, WidgetRef ref) {
    final tabs = ref.read(openTabsProvider);
    final selected = ref.read(selectedFileProvider);
    final newTabs = tabs.where((t) => t != path).toList();
    ref.read(openTabsProvider.notifier).state = newTabs;
    ref.read(dirtyFilesProvider.notifier).update((s) {
      if (!s.contains(path)) return s;
      return {...s}..remove(path);
    });
    ref.read(draftContentsProvider.notifier).update((m) {
      if (!m.containsKey(path)) return m;
      return {...m}..remove(path);
    });
    if (selected == path) {
      ref.read(selectedFileProvider.notifier).state =
          newTabs.isNotEmpty ? newTabs.last : null;
    }
  }

  Future<void> _closeTab(BuildContext context, String path, WidgetRef ref) async {
    final dirty = ref.read(dirtyFilesProvider).contains(path);
    if (!dirty) {
      _forceCloseTab(context, path, ref);
      return;
    }

    // 有未保存修改：弹确认对话框
    final fileName = path.split(Platform.pathSeparator).last;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
          actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          title: const Text(
            '文档未保存',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 280,
            child: Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                height: 1.3,
                color: scheme.onSurfaceVariant,
              ),
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
              child: const Text('保存'),
            ),
          ],
        );
      },
    );

    if (action == null || action == 'cancel') return;
    if (action == 'save') {
      final save = ref.read(saveActionsProvider)[path];
      if (save != null) {
        await save();
      } else {
        final draft = ref.read(draftContentsProvider)[path];
        if (draft != null) {
          try {
            await File(path).writeAsString(draft);
          } catch (_) {}
        }
      }
      ref.read(dirtyFilesProvider.notifier).update((s) {
        if (!s.contains(path)) return s;
        return {...s}..remove(path);
      });
      ref.read(draftContentsProvider.notifier).update((m) {
        if (!m.containsKey(path)) return m;
        return {...m}..remove(path);
      });
    }
    _forceCloseTab(context, path, ref);
  }

  Widget _emptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.edit_note,
            size: 64,
            color: Theme.of(context).colorScheme.primary.withOpacity(0.5),
          ),
          const SizedBox(height: 12),
          Text(
            '从左侧选择一个文件打开',
            style: TextStyle(
              fontSize: 14,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileEditor extends ConsumerStatefulWidget {
  final String path;
  const _FileEditor({super.key, required this.path});

  @override
  ConsumerState<_FileEditor> createState() => _FileEditorState();
}

class _FileEditorState extends ConsumerState<_FileEditor> {
  bool get isMarkdownDoc => widget.path.toLowerCase().endsWith('.md');

  late final CodeLineEditingController _controller;
  late final CodeScrollController _scrollController;
  final FocusNode _editorFocus = FocusNode();

  double _scrollOffset = 0;
  bool _isDir = false;
  bool _loading = true;
  bool _isDirty = false;
  /// 已保存/已加载的正文基线；仅当编辑后文本与此不同才算脏。
  String _cleanText = '';
  bool _showPreview = false;
  List<FileSystemEntity> _dirEntries = [];

  List<OutlineHeading> _outline = const [];
  int _activeOutline = -1;
  int _activeLine = 0;
  Timer? _outlineDebounce;
  Timer? _viewPersistDebounce;
  Timer? _diskWatchTimer;
  Timer? _diskReloadDebounce;
  bool _restoringView = false;
  bool _reloadingFromDisk = false;
  bool _jumpingToHeading = false;

  /// 上次已知的磁盘 mtime/size，用于发现智能体等外部写入。
  DateTime? _knownMtime;
  int _knownSize = -1;
  bool _diskConflictNotified = false;

  /// 记住最近一次非空选区（扁平字符偏移）。
  ({int base, int extent})? _rememberedRange;

  /// 恢复选区时忽略 controller 回调，避免记忆被冲掉。
  bool _freezeSelection = false;

  static const _editorPadding = EdgeInsets.all(8);
  static const _lineHeightFactor = 1.55;

  @override
  void initState() {
    super.initState();
    _controller = CodeLineEditingController.fromText('');
    _scrollController = CodeScrollController();
    _controller.addListener(_onControllerChanged);
    _scrollController.verticalScroller.addListener(_onScrollChanged);
    _editorFocus.addListener(_onEditorFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registerSave();
      if (mounted) ComfyPromptSendMemory.hydrateProvider(ref);
    });
    _load();
    _diskWatchTimer = Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _pollDiskChange(),
    );
  }

  void _onEditorFocusChanged() {
    if (_editorFocus.hasFocus) {
      final pin = _rememberedValidSelection();
      if (pin != null) {
        _freezeSelection = true;
        _controller.selection =
            codeSelectionFromFlat(_controller.text, pin.base, pin.extent);
        _freezeSelection = false;
      }
    }
  }

  void _onScrollChanged() {
    if (_jumpingToHeading || _restoringView) return;
    final scroller = _scrollController.verticalScroller;
    if (!scroller.hasClients) return;
    final pixels = scroller.offset;
    if ((pixels - _scrollOffset).abs() > 0.5) {
      _scrollOffset = pixels;
      _refreshActiveOutlineFromViewport();
      _schedulePersistView();
    }
  }

  /// 当前应展示/恢复的非空选区（扁平偏移）。
  ({int base, int extent})? _rememberedValidSelection() {
    final text = _controller.text;
    final flat = flatFromCodeSelection(text, _controller.selection);
    if (flat.base != flat.extent &&
        flat.base >= 0 &&
        flat.extent >= 0 &&
        flat.base <= text.length &&
        flat.extent <= text.length) {
      return flat;
    }
    final r = _rememberedRange;
    if (r != null &&
        r.base != r.extent &&
        r.base >= 0 &&
        r.extent >= 0 &&
        r.base <= text.length &&
        r.extent <= text.length) {
      return r;
    }
    return null;
  }

  void _onControllerChanged() {
    if (_freezeSelection) return;
    final text = _controller.text;
    final flat = flatFromCodeSelection(text, _controller.selection);
    if (flat.base != flat.extent) {
      _rememberedRange = flat;
    } else if (_editorFocus.hasFocus) {
      // 仍有焦点时收成光标：用户点击/方向键取消选区，必须清掉记忆。
      _rememberedRange = null;
    } else {
      // 失焦收成光标：端点仍在原选区内则保留。
      final r = _rememberedRange;
      if (r != null) {
        final lo = r.base < r.extent ? r.base : r.extent;
        final hi = r.base < r.extent ? r.extent : r.base;
        if (flat.base < lo || flat.base > hi) {
          _rememberedRange = null;
        }
      }
    }

    if (_controller.isComposing) return;
    _refreshCaretLine();
    _scheduleOutlineRebuild();
    if (!_restoringView) _schedulePersistView();
  }

  void _schedulePersistView() {
    if (_isDir || _loading) return;
    _viewPersistDebounce?.cancel();
    _viewPersistDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _isDir) return;
      _flushPersistView();
    });
  }

  void _flushPersistView() {
    final text = _controller.text;
    final textLen = text.length;
    final sel = _rememberedValidSelection();
    final caretFlat = sel != null
        ? sel.extent
        : flatFromCodeSelection(text, _controller.selection).extent;
    final caret = caretFlat.clamp(0, textLen);
    final scroll = _scrollController.verticalScroller.hasClients
        ? _scrollController.verticalScroller.offset
        : _scrollOffset;
    final next = Map<String, EditorViewState>.of(
      ref.read(editorViewStatesProvider),
    );
    next[widget.path] = EditorViewState(
      caretOffset: caret,
      scrollOffset: scroll,
      selectionBase: sel?.base,
      selectionExtent: sel?.extent,
    );
    ref.read(editorViewStatesProvider.notifier).state = next;
  }

  void _refreshCaretLine() {
    final text = _controller.text;
    final line = _controller.selection.baseIndex.clamp(0, countLines(text) - 1);
    if (line != _activeLine) {
      setState(() => _activeLine = line);
    }
    _updateActiveOutline(line);
  }

  void _refreshActiveOutlineFromViewport() {
    if (!isMarkdownDoc || _outline.isEmpty) return;
    if (_editorFocus.hasFocus) {
      _updateActiveOutline(_activeLine);
      return;
    }
    final fontSize = ref.read(editorFontSizeProvider);
    final lineHeight = fontSize * _lineHeightFactor;
    if (lineHeight <= 0) return;
    final approx = (_scrollOffset / lineHeight).floor().clamp(
          0,
          countLines(_controller.text) - 1,
        );
    _updateActiveOutline(approx);
  }

  void _updateActiveOutline(int line) {
    final idx = activeOutlineIndex(_outline, line);
    if (idx != _activeOutline) {
      setState(() => _activeOutline = idx);
    }
  }

  void _scheduleOutlineRebuild() {
    if (!isMarkdownDoc) return;
    _outlineDebounce?.cancel();
    _outlineDebounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      final next = parseMarkdownOutline(_controller.text);
      final idx = activeOutlineIndex(next, _activeLine);
      _outline = next;
      _activeOutline = idx;
      if (mounted) setState(() {});
    });
  }

  Future<void> _jumpToHeading(OutlineHeading h) async {
    final text = _controller.text;
    final caret = h.charOffset.clamp(0, text.length);
    final (line, col) = flatOffsetToLineCol(text, caret);

    setState(() {
      _activeLine = h.lineIndex;
      _activeOutline = activeOutlineIndex(_outline, h.lineIndex);
    });

    _jumpingToHeading = true;
    _editorFocus.requestFocus();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _jumpingToHeading = false;
      return;
    }

    _freezeSelection = true;
    _controller.selection = CodeLineSelection.collapsed(
      index: line,
      offset: col,
    );
    _freezeSelection = false;

    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _jumpingToHeading = false;
      return;
    }

    _controller.makeCursorCenterIfInvisible();
    _scrollController.makeCenterIfInvisible(
      CodeLinePosition(index: line, offset: col),
    );

    if (_scrollController.verticalScroller.hasClients) {
      _scrollOffset = _scrollController.verticalScroller.offset;
    }

    _jumpingToHeading = false;
    if (mounted) {
      setState(() {});
      if (!_restoringView) _schedulePersistView();
    }
  }

  /// 优先用当前非空选区；若已被快捷键冲成光标，回退到记住的范围选区。
  ({int base, int extent}) _effectiveSelection() {
    final text = _controller.text;
    final flat = flatFromCodeSelection(text, _controller.selection);
    if (flat.base != flat.extent) return flat;
    final remembered = _rememberedRange;
    if (remembered != null &&
        remembered.base != remembered.extent &&
        remembered.base >= 0 &&
        remembered.extent >= 0 &&
        remembered.base <= text.length &&
        remembered.extent <= text.length) {
      return remembered;
    }
    return flat;
  }

  void _registerAgentRef() {
    if (_isDir) return;
    ref.read(agentRefBuilderProvider.notifier).state = () {
      final sel = _effectiveSelection();
      final a = sel.base < sel.extent ? sel.base : sel.extent;
      final b = sel.base < sel.extent ? sel.extent : sel.base;
      return buildAgentReference(
        filePath: widget.path,
        text: _controller.text,
        selectionStart: a,
        selectionEnd: b,
      );
    };
    ref.read(agentRefPreserveSelectionProvider.notifier).state =
        _preserveSelectionAfterAgentRef;
  }

  void _preserveSelectionAfterAgentRef() {
    if (!mounted || _isDir) return;
    final pin = _effectiveSelection();
    if (pin.base == pin.extent) return;
    _freezeSelection = true;
    _rememberedRange = pin;
    _controller.selection =
        codeSelectionFromFlat(_controller.text, pin.base, pin.extent);
    _freezeSelection = false;
  }

  void _unregisterAgentRef() {
    final selected = ref.read(selectedFileProvider);
    if (selected == widget.path) {
      ref.read(agentRefBuilderProvider.notifier).state = null;
      ref.read(agentRefPreserveSelectionProvider.notifier).state = null;
    }
  }

  void _registerSave() {
    ref.read(saveActionsProvider.notifier).update((m) {
      final next = Map.of(m);
      next[widget.path] = _save;
      return next;
    });
  }

  void _unregisterSave() {
    ref.read(saveActionsProvider.notifier).update((m) {
      final next = Map.of(m);
      next.remove(widget.path);
      return next;
    });
  }

  Future<void> _captureDiskFingerprint() async {
    try {
      final stat = await File(widget.path).stat();
      _knownMtime = stat.modified;
      _knownSize = stat.size;
      _diskConflictNotified = false;
    } catch (_) {}
  }

  void _pollDiskChange() {
    if (!mounted || _isDir || _loading || _reloadingFromDisk || _restoringView) {
      return;
    }
    if (ref.read(selectedFileProvider) != widget.path) return;
    unawaited(_pollDiskChangeAsync());
  }

  Future<void> _pollDiskChangeAsync() async {
    try {
      final file = File(widget.path);
      if (!await file.exists()) return;
      final stat = await file.stat();
      if (_knownMtime == null) {
        _knownMtime = stat.modified;
        _knownSize = stat.size;
        return;
      }
      if (stat.modified == _knownMtime && stat.size == _knownSize) return;

      _diskReloadDebounce?.cancel();
      _diskReloadDebounce = Timer(const Duration(milliseconds: 350), () {
        unawaited(_reloadFromDiskIfNeeded());
      });
    } catch (_) {}
  }

  Future<void> _reloadFromDiskIfNeeded() async {
    if (!mounted || _isDir || _loading || _reloadingFromDisk) return;
    final file = File(widget.path);
    FileStat stat;
    try {
      if (!await file.exists()) return;
      stat = await file.stat();
    } catch (_) {
      return;
    }

    if (_knownMtime != null &&
        stat.modified == _knownMtime &&
        stat.size == _knownSize) {
      return;
    }

    if (_isDirty) {
      _knownMtime = stat.modified;
      _knownSize = stat.size;
      if (!_diskConflictNotified && mounted) {
        _diskConflictNotified = true;
        showGlobalToast(context, '磁盘文件已更新，本地有未保存修改，未自动重载');
      }
      return;
    }

    _reloadingFromDisk = true;
    try {
      final content = await file.readAsString();
      if (!mounted) return;
      if (content == _controller.text) {
        _knownMtime = stat.modified;
        _knownSize = stat.size;
        return;
      }

      final scroll = _scrollOffset;
      final caretFlat = flatFromCodeSelection(
        _controller.text,
        _controller.selection,
      ).extent.clamp(0, content.length);

      _freezeSelection = true;
      setState(() {
        _controller.text = content;
        _controller.selection = codeSelectionFromFlat(
          content,
          caretFlat,
          caretFlat,
        );
        _outline = isMarkdownDoc ? parseMarkdownOutline(content) : const [];
        _activeLine = lineIndexOfOffset(content, caretFlat);
        _activeOutline = activeOutlineIndex(_outline, _activeLine);
        _isDirty = false;
      });
      _freezeSelection = false;
      _knownMtime = stat.modified;
      _knownSize = stat.size;
      _diskConflictNotified = false;
      _cleanText = content;
      _registerAgentRef();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final scroller = _scrollController.verticalScroller;
        if (scroller.hasClients) {
          final target = scroll.clamp(0.0, scroller.position.maxScrollExtent);
          if ((scroller.offset - target).abs() > 0.5) scroller.jumpTo(target);
          _scrollOffset = target;
        }
      });

      if (mounted) showGlobalToast(context, '已从磁盘重新加载');
    } catch (_) {
      // 读失败则下一轮再试
    } finally {
      _reloadingFromDisk = false;
    }
  }

  Future<void> _load() async {
    final entity = FileSystemEntity.typeSync(widget.path);
    if (entity == FileSystemEntityType.directory) {
      setState(() {
        _isDir = true;
        _dirEntries = Directory(widget.path).listSync();
        _dirEntries.sort((a, b) {
          final aIsDir = a is Directory;
          final bIsDir = b is Directory;
          if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
          return a.path.split(Platform.pathSeparator).last
              .compareTo(b.path.split(Platform.pathSeparator).last);
        });
        _loading = false;
      });
      return;
    }

    final file = File(widget.path);
    try {
      final diskContent = await file.readAsString();
      if (!mounted) return;
      final draft = ref.read(draftContentsProvider)[widget.path];
      final content = draft ?? diskContent;
      final dirty = draft != null;
      setState(() {
        _controller.text = content;
        _outline = isMarkdownDoc ? parseMarkdownOutline(content) : const [];
        _activeOutline = activeOutlineIndex(_outline, 0);
        _activeLine = 0;
        _isDirty = dirty;
        _cleanText = diskContent;
        _loading = false;
      });
      if (dirty) {
        ref.read(dirtyFilesProvider.notifier).update((s) {
          if (s.contains(widget.path)) return s;
          return {...s, widget.path};
        });
      }
      await _captureDiskFingerprint();
      _registerAgentRef();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreViewState();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
      _registerAgentRef();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法读取文件: $e')),
      );
    }
  }

  Future<void> _restoreViewState() async {
    final saved = ref.read(editorViewStatesProvider)[widget.path];
    if (saved == null || _isDir) return;

    final text = _controller.text;
    final caret = saved.caretOffset.clamp(0, text.length);

    _restoringView = true;
    try {
      _editorFocus.requestFocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      void pinScroll(double desired) {
        final scroller = _scrollController.verticalScroller;
        if (!scroller.hasClients) return;
        final target = desired.clamp(0.0, scroller.position.maxScrollExtent);
        if ((scroller.offset - target).abs() > 0.5) {
          scroller.jumpTo(target);
        }
        _scrollOffset = target;
        setState(() {
          _activeLine = lineIndexOfOffset(text, caret);
          _activeOutline = activeOutlineIndex(_outline, _activeLine);
        });
      }

      var scrollTarget = saved.scrollOffset;
      if (scrollTarget < 0) scrollTarget = 0;
      pinScroll(scrollTarget);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      if (saved.hasSelection) {
        final base = saved.selectionBase!.clamp(0, text.length);
        final extent = saved.selectionExtent!.clamp(0, text.length);
        _freezeSelection = true;
        _rememberedRange = (base: base, extent: extent);
        _controller.selection = codeSelectionFromFlat(text, base, extent);
        _freezeSelection = false;
      } else {
        _controller.selection = codeSelectionFromFlat(text, caret, caret);
      }

      final deadline = DateTime.now().add(const Duration(milliseconds: 200));
      while (mounted && DateTime.now().isBefore(deadline)) {
        await WidgetsBinding.instance.endOfFrame;
        pinScroll(scrollTarget);
      }
    } finally {
      _restoringView = false;
    }
  }

  Future<void> _save() async {
    final file = File(widget.path);
    try {
      await file.writeAsString(_controller.text);
      if (!mounted) return;
      setState(() {
        _isDirty = false;
        _cleanText = _controller.text;
      });
      ref.read(dirtyFilesProvider.notifier).update((s) {
        final next = Set.of(s);
        next.remove(widget.path);
        return next;
      });
      ref.read(draftContentsProvider.notifier).update((m) {
        if (!m.containsKey(widget.path)) return m;
        final next = Map.of(m);
        next.remove(widget.path);
        return next;
      });
      await _captureDiskFingerprint();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败: $e')),
      );
    }
  }

  @override
  void dispose() {
    _outlineDebounce?.cancel();
    _viewPersistDebounce?.cancel();
    _diskWatchTimer?.cancel();
    _diskReloadDebounce?.cancel();
    try {
      if (!_isDir && !_loading) {
        _flushPersistView();
      }
    } catch (_) {}
    if (!_isDir && !_loading && _isDirty) {
      final path = widget.path;
      final text = _controller.text;
      ref.read(draftContentsProvider.notifier).update((m) {
        final next = Map.of(m);
        next[path] = text;
        return next;
      });
    }
    _controller.removeListener(_onControllerChanged);
    _scrollController.verticalScroller.removeListener(_onScrollChanged);
    _editorFocus.removeListener(_onEditorFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unregisterSave();
      _unregisterAgentRef();
    });
    _controller.dispose();
    _scrollController.verticalScroller.dispose();
    _scrollController.horizontalScroller.dispose();
    _scrollController.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  Future<void> _discardUnsavedEdits() async {
    if (_isDir || _loading) return;
    // 与磁盘重载同路径：改 controller.text 会触发 onChanged，
    // 必须挡住 _markDirty，否则「不保存」后脏标记又被写回。
    _reloadingFromDisk = true;
    try {
      final content = await File(widget.path).readAsString();
      if (!mounted) return;
      final caretFlat = flatFromCodeSelection(
        _controller.text,
        _controller.selection,
      ).extent.clamp(0, content.length);
      _freezeSelection = true;
      setState(() {
        _controller.text = content;
        _controller.selection = codeSelectionFromFlat(
          content,
          caretFlat,
          caretFlat,
        );
        _outline = isMarkdownDoc ? parseMarkdownOutline(content) : const [];
        _activeLine = lineIndexOfOffset(content, caretFlat);
        _activeOutline = activeOutlineIndex(_outline, _activeLine);
        _isDirty = false;
        _cleanText = content;
        _rememberedRange = null;
      });
      _freezeSelection = false;
      await _captureDiskFingerprint();
      _diskConflictNotified = false;
      if (mounted) {
        ref.read(dirtyFilesProvider.notifier).update((s) {
          if (!s.contains(widget.path)) return s;
          return {...s}..remove(widget.path);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isDirty = false);
    } finally {
      _reloadingFromDisk = false;
    }
  }

  void _markDirty() {
    if (_restoringView || _reloadingFromDisk) return;
    if (!_isDirty) {
      setState(() => _isDirty = true);
    }
    ref.read(dirtyFilesProvider.notifier).update((s) {
      if (s.contains(widget.path)) return s;
      return {...s, widget.path};
    });
  }

  void _clearDirtyLocal() {
    if (_isDirty) {
      setState(() => _isDirty = false);
    }
    ref.read(dirtyFilesProvider.notifier).update((s) {
      if (!s.contains(widget.path)) return s;
      return {...s}..remove(widget.path);
    });
  }

  /// re_editor 选区变化也会触发 onChanged，必须按正文对比。
  void _onEditorContentChanged() {
    if (_controller.isComposing) return;
    if (_restoringView || _reloadingFromDisk) return;
    final text = _controller.text;
    if (text == _cleanText) {
      if (_isDirty) _clearDirtyLocal();
      return;
    }
    _markDirty();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(discardUnsavedEditsTickProvider, (prev, next) {
      if (prev == next) return;
      unawaited(_discardUnsavedEdits());
    });

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_isDir) {
      return _buildDirView(context);
    }

    final isMarkdown = widget.path.endsWith('.md');
    final relPath = relativeProjectPath(widget.path);
    final pathLabel = relPath.isNotEmpty ? relPath : widget.path;

    return Column(
      children: [
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Icon(
                isMarkdown
                    ? Icons.description_outlined
                    : Icons.insert_drive_file_outlined,
                size: 16,
                color: Colors.grey,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: widget.path,
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    pathLabel,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (isMarkdown) ...[
                IconButton(
                  icon: Icon(
                    ref.watch(outlinePinnedProvider)
                        ? Icons.list_alt
                        : Icons.list_alt_outlined,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: '大纲 (Ctrl+Shift+O)',
                  onPressed: () {
                    final pinned = ref.read(outlinePinnedProvider);
                    ref.read(outlinePinnedProvider.notifier).state = !pinned;
                  },
                ),
                IconButton(
                  icon: Icon(
                    _showPreview ? Icons.edit_note : Icons.visibility_outlined,
                    size: 18,
                  ),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: _showPreview ? '编辑模式' : '预览模式',
                  onPressed: () =>
                      setState(() => _showPreview = !_showPreview),
                ),
                IconButton(
                  icon: const Icon(Icons.save, size: 18),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: '保存',
                  onPressed: _isDirty ? _save : null,
                ),
                if (_isDirty)
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ],
          ),
        ),
        if (isMarkdown) _buildHeadingBreadcrumb(context, pathLabel),
        const Divider(height: 1),
        Expanded(
          child: (_showPreview && isMarkdown)
              ? _buildPreview(context)
              : _buildCodeEditor(context, isMarkdown),
        ),
      ],
    );
  }

  Widget _buildHeadingBreadcrumb(BuildContext context, String fileName) {
    final theme = Theme.of(context);
    final trail = outlineBreadcrumb(_outline, _activeOutline);
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);
    final hashColor = theme.brightness == Brightness.dark
        ? const Color(0xFF5A7A9A)
        : const Color(0xFF6E7781);
    final titleColor = theme.brightness == Brightness.dark
        ? const Color(0xFF79B8FF)
        : const Color(0xFF0550AE);

    void jump(OutlineHeading h) {
      if (_showPreview) {
        setState(() => _showPreview = false);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToHeading(h);
        });
      } else {
        _jumpToHeading(h);
      }
    }

    return Material(
      color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.9),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: theme.dividerColor.withValues(alpha: 0.35),
            ),
          ),
        ),
        child: trail.isEmpty
            ? Text(
                '（无标题 · 正文）',
                style: TextStyle(fontSize: 12, color: muted, height: 1.35),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < trail.length; i++) ...[
                    if (i > 0) const SizedBox(height: 2),
                    InkWell(
                      onTap: () => jump(trail[i]),
                      borderRadius: BorderRadius.circular(3),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text.rich(
                          TextSpan(
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: (15.5 - trail[i].level * 0.6)
                                  .clamp(12.0, 15.0),
                              height: 1.35,
                              fontWeight: i == trail.length - 1
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                            children: [
                              TextSpan(
                                text: '${'#' * trail[i].level} ',
                                style: TextStyle(color: hashColor),
                              ),
                              TextSpan(
                                text: trail[i].title,
                                style: TextStyle(
                                  color: i == trail.length - 1
                                      ? titleColor
                                      : titleColor.withValues(alpha: 0.72),
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildCodeEditor(BuildContext context, bool isMarkdown) {
    final fontSize = ref.watch(editorFontSizeProvider);
    final pinned = ref.watch(outlinePinnedProvider);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
        const SingleActivator(
          LogicalKeyboardKey.keyO,
          control: true,
          shift: true,
        ): () {
          if (!isMarkdown) return;
          final p = ref.read(outlinePinnedProvider);
          ref.read(outlinePinnedProvider.notifier).state = !p;
        },
      },
      child: ColoredBox(
        color: cs.surface,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isMarkdown)
              OutlineRail(
                headings: _outline,
                activeIndex: _activeOutline,
                pinned: pinned,
                onPinnedChanged: (v) =>
                    ref.read(outlinePinnedProvider.notifier).state = v,
                onJump: _jumpToHeading,
              ),
            Expanded(
              child: CodeEditor(
                controller: _controller,
                scrollController: _scrollController,
                focusNode: _editorFocus,
                wordWrap: true,
                padding: _editorPadding,
                onChanged: (_) => _onEditorContentChanged(),
                style: CodeEditorStyle(
                  fontSize: fontSize,
                  fontFamily: 'Consolas',
                  fontHeight: _lineHeightFactor,
                  backgroundColor: cs.surface,
                  textColor: cs.onSurface,
                  cursorColor: cs.primary,
                  selectionColor: cs.primary.withValues(alpha: 0.28),
                  codeTheme: isMarkdown
                      ? CodeHighlightTheme(
                          languages: {
                            'markdown': CodeHighlightThemeMode(
                              mode: langMarkdownRich,
                            ),
                          },
                          theme: markdownEditorHighlightTheme(
                            dark ? Brightness.dark : Brightness.light,
                          ),
                        )
                      : null,
                ),
                indicatorBuilder:
                    (context, editingController, chunkController, notifier) {
                  return DefaultCodeLineNumber(
                    controller: editingController,
                    notifier: notifier,
                  );
                },
                leadingDivider: VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: cs.outlineVariant.withValues(alpha: 0.6),
                ),
                toolbarController: ReEditorContextMenuController(
                  hostContext: context,
                  ref: ref,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: MarkdownBody(
          data: _controller.text,
          selectable: false,
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            h1: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
            h2: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
            h3: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
            p: TextStyle(
              fontSize: 15,
              height: 1.7,
              color: theme.colorScheme.onSurface,
            ),
            code: const TextStyle(
              fontFamily: 'Consolas',
              backgroundColor: Color(0x1FFFFFFF),
            ),
            codeblockDecoration: BoxDecoration(
              color: const Color(0x14000000),
              borderRadius: BorderRadius.circular(6),
            ),
            blockquoteDecoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              border: Border(
                left: BorderSide(
                  color: theme.colorScheme.primary.withOpacity(0.7),
                  width: 4,
                ),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDirView(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Text(
            widget.path,
            style: const TextStyle(fontSize: 13, color: Colors.grey),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: _dirEntries.isEmpty
              ? const Center(child: Text('空目录'))
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 180,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.4,
                  ),
                  itemCount: _dirEntries.length,
                  itemBuilder: (context, index) {
                    final entry = _dirEntries[index];
                    final isDir = entry is Directory;
                    final name =
                        entry.path.split(Platform.pathSeparator).last;
                    final isMedia = !isDir &&
                        (name.endsWith('.png') ||
                            name.endsWith('.jpg') ||
                            name.endsWith('.jpeg') ||
                            name.endsWith('.mp4') ||
                            name.endsWith('.mov') ||
                            name.endsWith('.wav') ||
                            name.endsWith('.mp3'));
                    return _MaterialCard(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _iconForName(name, isDir),
                            size: 32,
                            color: isDir ? Colors.orange : Colors.blueGrey,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            name,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                      onTap: () {
                        if (isDir) {
                          ref.read(selectedFileProvider.notifier).state =
                              entry.path;
                          final tabs = ref.read(openTabsProvider);
                          if (!tabs.contains(entry.path)) {
                            ref.read(openTabsProvider.notifier).state =
                                [...tabs, entry.path];
                          }
                        } else if (isMedia) {
                          _showMediaPreview(context, entry.path, name);
                        } else if (name.endsWith('.md')) {
                          ref.read(selectedFileProvider.notifier).state =
                              entry.path;
                          final tabs = ref.read(openTabsProvider);
                          if (!tabs.contains(entry.path)) {
                            ref.read(openTabsProvider.notifier).state =
                                [...tabs, entry.path];
                          }
                        }
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showMediaPreview(BuildContext context, String path, String name) {
    if (name.endsWith('.mp4') || name.endsWith('.mov')) {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.black,
          child: _VideoPreview(file: File(path)),
        ),
      );
    } else if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg')) {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.black,
          child: Image.file(File(path)),
        ),
      );
    }
  }

  IconData _iconForName(String name, bool isDir) {
    if (isDir) return Icons.folder;
    if (name.endsWith('.md')) return Icons.description_outlined;
    if (name.endsWith('.png') ||
        name.endsWith('.jpg') ||
        name.endsWith('.jpeg')) return Icons.image_outlined;
    if (name.endsWith('.mp4') || name.endsWith('.mov')) return Icons.videocam;
    if (name.endsWith('.wav') || name.endsWith('.mp3')) return Icons.music_note;
    return Icons.insert_drive_file_outlined;
  }
}

class _MaterialCard extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;
  const _MaterialCard({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: Theme.of(context).dividerColor.withOpacity(0.3),
          ),
        ),
        child: child,
      ),
    );
  }
}

class _VideoPreview extends StatefulWidget {
  final File file;
  const _VideoPreview({required this.file});

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.videocam, size: 64, color: Colors.white54),
          const SizedBox(height: 12),
          Text(
            widget.file.path.split(Platform.pathSeparator).last,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          const Text(
            '桌面视频播放需要 media_kit，后续版本加入',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
