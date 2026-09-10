import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/agent_bridge.dart';
import '../../core/comfy_prompt_bridge.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../../core/workspace_memory.dart';
import 'ime_geometry.dart';
import 'line_number_gutter.dart';
import 'line_selection_overlay.dart';
import 'markdown_highlight_controller.dart';
import 'markdown_outline.dart';
import 'outline_rail.dart';
import 'wrap_line_metrics.dart';

/// 大纲是否钉住（会话内保持）。
final outlinePinnedProvider = StateProvider<bool>((ref) => false);

class MarkdownEditor extends ConsumerWidget {
  const MarkdownEditor({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(openTabsProvider);
    final selectedFile = ref.watch(selectedFileProvider);

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
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未保存的更改'),
        content: Text('是否保存对“${path.split(Platform.pathSeparator).last}”的修改？'),
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
      ),
    );

    if (action == null || action == 'cancel') return;
    if (action == 'save') {
      final save = ref.read(saveActionsProvider)[path];
      if (save != null) await save();
      ref.read(dirtyFilesProvider.notifier).update((s) {
        if (!s.contains(path)) return s;
        return {...s}..remove(path);
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
  late String _content;
  late final TextEditingController _controller =
      MarkdownHighlightController(enabled: isMarkdownDoc);
  final FocusNode _editorFocus = FocusNode();
  final GlobalKey _editorFieldKey = GlobalKey();
  double _scrollOffset = 0;
  double _viewportHeight = 400;
  WrapLineMetrics? _wrapMetrics;
  String? _wrapSyncFingerprint;
  bool _isDir = false;
  bool _loading = true;
  bool _isDirty = false;
  bool _showPreview = false;
  List<FileSystemEntity> _dirEntries = [];

  List<OutlineHeading> _outline = const [];
  int _activeOutline = -1;
  int _activeLine = 0;
  int _lineCount = 1;
  Timer? _outlineDebounce;
  Timer? _viewPersistDebounce;
  Timer? _diskWatchTimer;
  Timer? _diskReloadDebounce;
  bool _restoringView = false;
  bool _reloadingFromDisk = false;

  /// 上次已知的磁盘 mtime/size，用于发现智能体等外部写入。
  DateTime? _knownMtime;
  int _knownSize = -1;
  bool _diskConflictNotified = false;

  /// 记住最近一次非空选区。快捷键/失焦时 TextField 常收成光标或隐藏高亮。
  TextSelection? _rememberedRange;

  /// 恢复选区时忽略 controller 回调，避免记忆被冲掉。
  bool _freezeSelection = false;

  /// IME 几何多帧补报是否已挂起。
  bool _imeSyncScheduled = false;
  int _imeSyncFramesLeft = 0;
  TextSelection? _lastImeSelection;
  TextRange _lastImeComposing = TextRange.empty;

  static const _editorPadding = EdgeInsets.all(8);
  static const _lineHeightFactor = 1.6;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _editorFocus.addListener(_onEditorFocusChanged);
    // 延后到首帧构建完成后注册，避免在 build 期间修改 provider
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
      // 回到编辑器：把记忆选区写回 controller，由原生高亮绘制
      final pin = _rememberedValidSelection();
      if (pin != null) {
        _freezeSelection = true;
        _controller.selection = pin;
        _freezeSelection = false;
      }
      _scheduleImeGeometrySync(frames: 4, urgent: true);
    }
    // 失焦时改为叠加层绘制选区；获焦时去掉叠加层
    if (mounted) setState(() {});
  }

  void _pushImeGeometryNow() {
    if (!_editorFocus.hasFocus) return;
    // 组字中绝不覆盖，交给框架。
    if (_controller.value.isComposingRangeValid) return;
    final editable = findRenderEditable(
      _editorFieldKey.currentContext?.findRenderObject(),
    );
    if (editable != null) {
      syncImeGeometryToPlatform(editable, _controller.value);
    }
  }

  void _scheduleImeGeometrySync({int frames = 1, bool urgent = false}) {
    if (!_editorFocus.hasFocus) return;
    if (urgent) {
      _pushImeGeometryNow();
      // 尽快出下一帧，避免「刚挪光标就组字」仍用上一处缓存矩形。
      SchedulerBinding.instance.scheduleFrame();
    }
    _imeSyncFramesLeft = math.max(_imeSyncFramesLeft, frames);
    if (_imeSyncScheduled) return;
    _imeSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback(_onImeSyncFrame);
  }

  void _onImeSyncFrame(Duration _) {
    _imeSyncScheduled = false;
    if (!mounted || !_editorFocus.hasFocus) {
      _imeSyncFramesLeft = 0;
      return;
    }
    // 组字过程中不要盖 EditableText 自己的上报，否则容易把候选推到错误行首。
    if (!_controller.value.isComposingRangeValid) {
      _pushImeGeometryNow();
    }
    _imeSyncFramesLeft -= 1;
    if (_imeSyncFramesLeft > 0) {
      _imeSyncScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback(_onImeSyncFrame);
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  /// 当前应展示/恢复的非空选区。
  TextSelection? _rememberedValidSelection() {
    final sel = _controller.selection;
    if (sel.isValid &&
        !sel.isCollapsed &&
        sel.start >= 0 &&
        sel.end <= _controller.text.length) {
      return sel;
    }
    final r = _rememberedRange;
    if (r != null &&
        r.isValid &&
        !r.isCollapsed &&
        r.start >= 0 &&
        r.end <= _controller.text.length) {
      return r;
    }
    return null;
  }

  void _onControllerChanged() {
    if (_freezeSelection) return;
    final sel = _controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      _rememberedRange = sel;
    } else if (sel.isValid && sel.isCollapsed) {
      if (_editorFocus.hasFocus) {
        // 仍有焦点时收成光标：用户点击/方向键取消选区，必须清掉记忆，
        // 否则切文件再回来会把旧选区从 EditorViewState 恢复出来。
        _rememberedRange = null;
      } else {
        // 失焦收成光标：端点仍在原选区内则保留（叠加层 / Agent 引用）。
        final r = _rememberedRange;
        if (r != null &&
            (sel.baseOffset < r.start || sel.baseOffset > r.end)) {
          _rememberedRange = null;
        }
      }
    }
    // 仅在「未组字」时主动同步：清掉旧光标处的 IME 缓存。
    // 组字中交给 EditableText 自己上报，避免错误覆盖把候选钉在后面行首。
    if (_editorFocus.hasFocus) {
      final value = _controller.value;
      final composing = value.isComposingRangeValid;
      final sel = value.selection;
      final wasComposing =
          _lastImeComposing.isValid && !_lastImeComposing.isCollapsed;
      final selMoved = _lastImeSelection == null ||
          _lastImeSelection!.baseOffset != sel.baseOffset ||
          _lastImeSelection!.extentOffset != sel.extentOffset;
      final composingEnded = !composing && wasComposing;

      _lastImeSelection = sel;
      _lastImeComposing = value.composing;

      if (!composing && (selMoved || composingEnded)) {
        _scheduleImeGeometrySync(frames: 4, urgent: true);
      }

      // 组字中：不做任何 setState（含行号），保持 RenderEditable 布局稳定。
      if (composing) return;
    }
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
    final textLen = _controller.text.length;
    final sel = _rememberedValidSelection();
    final caret = (sel != null ? sel.extentOffset : _controller.selection.baseOffset)
        .clamp(0, textLen);
    final next = Map<String, EditorViewState>.of(
      ref.read(editorViewStatesProvider),
    );
    next[widget.path] = EditorViewState(
      caretOffset: caret,
      scrollOffset: _scrollOffset,
      selectionBase: sel?.baseOffset,
      selectionExtent: sel?.extentOffset,
    );
    ref.read(editorViewStatesProvider.notifier).state = next;
  }

  /// TextField 内部 Scrollable（只在编辑器子树内查找，避免误绑到外层）。
  ScrollPosition? _editorScrollPosition() {
    final root = _editorFieldKey.currentContext as Element?;
    if (root == null) return null;
    ScrollPosition? found;
    void visit(Element el) {
      if (found != null) return;
      if (el is StatefulElement && el.state is ScrollableState) {
        found = (el.state as ScrollableState).position;
        return;
      }
      el.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  void _refreshCaretLine() {
    final text = _controller.text;
    final offset = _controller.selection.baseOffset.clamp(0, text.length);
    final line = lineIndexOfOffset(text, offset);
    final lines = countLines(text);
    if (line != _activeLine || lines != _lineCount) {
      setState(() {
        _activeLine = line;
        _lineCount = lines;
      });
    }
    _updateActiveOutline(line);
  }

  void _refreshActiveOutlineFromViewport() {
    if (!isMarkdownDoc || _outline.isEmpty) return;
    if (_editorFocus.hasFocus) {
      _updateActiveOutline(_activeLine);
      return;
    }
    final metrics = _wrapMetrics;
    if (metrics == null || metrics.lineCount == 0) return;
    final firstVisible = metrics
        .lineAtY(_scrollOffset - _editorPadding.top)
        .clamp(0, metrics.lineCount - 1);
    _updateActiveOutline(firstVisible);
  }

  TextStyle _editorTextStyle(double fontSize) => TextStyle(
        fontSize: fontSize,
        height: _lineHeightFactor,
        fontFamily: 'Consolas',
      );

  StrutStyle _editorStrut(double fontSize) => StrutStyle(
        fontSize: fontSize,
        height: _lineHeightFactor,
        fontFamily: 'Consolas',
        forceStrutHeight: true,
      );

  WrapLineMetrics _computeWrapMetrics(
    BuildContext context,
    double fontSize,
    double textViewportWidth,
  ) {
    final lineHeight = fontSize * _lineHeightFactor;
    final style = _editorTextStyle(fontSize);
    final strut = _editorStrut(fontSize);
    final editableWidth = math.max(
      40.0,
      textViewportWidth - _editorPadding.horizontal - kEditableCaretMargin,
    );

    final InlineSpan span;
    final c = _controller;
    if (c is MarkdownHighlightController && c.enabled) {
      span = c.buildTextSpan(
        context: context,
        style: style,
        withComposing: false,
      );
    } else {
      span = TextSpan(text: _controller.text, style: style);
    }

    return buildWrapLineMetrics(
      text: _controller.text,
      span: span,
      maxWidth: editableWidth,
      lineHeight: lineHeight,
      strutStyle: strut,
    );
  }

  /// 布局完成后用 RenderEditable 真值校正行号，消除估高漂移。
  void _scheduleSyncWrapMetricsFromEditable(
    String fingerprint,
    double fontSize,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_wrapSyncFingerprint == fingerprint && _wrapMetrics != null) {
        return;
      }
      final editable = findRenderEditable(
        _editorFieldKey.currentContext?.findRenderObject(),
      );
      if (editable == null) return;
      final next = buildWrapLineMetricsFromEditable(
        editable: editable,
        text: _controller.text,
        lineHeight: fontSize * _lineHeightFactor,
      );
      if (next == null) return;
      final prev = _wrapMetrics;
      _wrapSyncFingerprint = fingerprint;
      if (prev != null && prev.nearlyEquals(next)) return;
      setState(() => _wrapMetrics = next);
    });
  }

  String _wrapFingerprint(double fontSize, double textViewportW) =>
      '${_controller.text.hashCode}:${_controller.text.length}:'
      '$fontSize:${textViewportW.round()}';

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
      setState(() {
        _outline = next;
        _activeOutline = activeOutlineIndex(next, _activeLine);
      });
    });
  }

  /// 测量目标字符在文档中的 Y（内容坐标，含滚动），优先用 RenderEditable 真值。
  double _measureDocY(int charOffset, TextStyle style) {
    final o = charOffset.clamp(0, _controller.text.length);
    final editable = findRenderEditable(
      _editorFieldKey.currentContext?.findRenderObject(),
    );
    if (editable != null && editable.hasSize) {
      final local = editable.getLocalRectForCaret(TextPosition(offset: o));
      return local.top + editable.offset.pixels;
    }

    final box = _editorFieldKey.currentContext?.findRenderObject() as RenderBox?;
    final maxWidth = (box?.size.width ?? 800) - _editorPadding.horizontal;
    // 测量阶段禁止走 Theme.of(context)/buildTextSpan，避免在非 build 阶段注册 Inherited 依赖。
    final tp = TextPainter(
      text: TextSpan(text: _controller.text, style: style),
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle(
        fontSize: style.fontSize,
        height: style.height,
        fontFamily: style.fontFamily,
        forceStrutHeight: true,
      ),
    )..layout(maxWidth: maxWidth > 40 ? maxWidth : 800);
    final caret = tp.getOffsetForCaret(
      TextPosition(offset: o),
      Rect.zero,
    );
    return _editorPadding.top + caret.dy;
  }

  bool _jumpingToHeading = false;

  Future<void> _jumpToHeading(OutlineHeading h) async {
    final caret = h.charOffset.clamp(0, _controller.text.length);
    final fontSize = ref.read(editorFontSizeProvider);
    final style = _editorTextStyle(fontSize);

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

    void pinTargetInView() {
      final pos = _editorScrollPosition();
      if (pos == null || !pos.hasContentDimensions) return;
      final docY = _measureDocY(caret, style);
      // 目标行落在视口上方约 1/4
      final target =
          (docY - pos.viewportDimension * 0.25).clamp(0.0, pos.maxScrollExtent);
      if ((pos.pixels - target).abs() > 0.5) {
        pos.jumpTo(target);
      }
      _scrollOffset = target;
      _viewportHeight = pos.viewportDimension;
    }

    // 先滚到位，再设光标；随后再纠正一次 bringIntoView 的偏移。
    pinTargetInView();
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _jumpingToHeading = false;
      return;
    }
    pinTargetInView();

    _controller.selection = TextSelection.collapsed(offset: caret);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) {
      _jumpingToHeading = false;
      return;
    }
    pinTargetInView();

    _jumpingToHeading = false;
    if (mounted) {
      setState(() {});
      if (!_restoringView) _schedulePersistView();
    }
  }

  /// 优先用当前非空选区；若已被快捷键冲成光标，回退到记住的范围选区。
  TextSelection _effectiveSelection() {
    final sel = _controller.selection;
    if (sel.isValid && !sel.isCollapsed) return sel;
    final remembered = _rememberedRange;
    if (remembered != null &&
        remembered.isValid &&
        !remembered.isCollapsed &&
        remembered.start >= 0 &&
        remembered.end <= _controller.text.length) {
      return remembered;
    }
    return sel;
  }

  void _registerAgentRef() {
    if (_isDir) return;
    ref.read(agentRefBuilderProvider.notifier).state = () {
      final sel = _effectiveSelection();
      return buildAgentReference(
        filePath: widget.path,
        text: _controller.text,
        selectionStart: sel.start,
        selectionEnd: sel.end,
      );
    };
    ref.read(agentRefPreserveSelectionProvider.notifier).state =
        _preserveSelectionAfterAgentRef;
  }

  /// 快捷键填入后：写回选区并保持记忆，失焦后由字符级叠加层绘制。
  void _preserveSelectionAfterAgentRef() {
    if (!mounted || _isDir) return;
    final pin = _effectiveSelection();
    if (!pin.isValid || pin.isCollapsed) return;
    _freezeSelection = true;
    _rememberedRange = pin;
    _controller.selection = pin;
    _freezeSelection = false;
    if (mounted) setState(() {});
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

      // 外部写入可能分多次落盘，稍作去抖再读。
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
      // 本地有未保存修改：不覆盖，只提示一次。
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
      final caret = _controller.selection.extentOffset.clamp(0, content.length);
      _freezeSelection = true;
      setState(() {
        _content = content;
        _controller.value = TextEditingValue(
          text: content,
          selection: TextSelection.collapsed(offset: caret),
        );
        _lineCount = countLines(content);
        _outline = isMarkdownDoc ? parseMarkdownOutline(content) : const [];
        _activeLine = lineIndexOfOffset(content, caret);
        _activeOutline = activeOutlineIndex(_outline, _activeLine);
        _isDirty = false;
      });
      _freezeSelection = false;
      _knownMtime = stat.modified;
      _knownSize = stat.size;
      _diskConflictNotified = false;
      _registerAgentRef();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pos = _editorScrollPosition();
        if (pos != null && pos.hasContentDimensions) {
          final target = scroll.clamp(0.0, pos.maxScrollExtent);
          if ((pos.pixels - target).abs() > 0.5) pos.jumpTo(target);
          setState(() => _scrollOffset = target);
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
      final content = await file.readAsString();
      if (!mounted) return;
      setState(() {
        _content = content;
        _controller.text = content;
        _lineCount = countLines(content);
        _outline = isMarkdownDoc ? parseMarkdownOutline(content) : const [];
        _activeOutline = activeOutlineIndex(_outline, 0);
        _activeLine = 0;
        _loading = false;
      });
      await _captureDiskFingerprint();
      _registerAgentRef();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreViewState();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _content = '';
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

    final caret = saved.caretOffset.clamp(0, _controller.text.length);
    final style = TextStyle(
      fontSize: ref.read(editorFontSizeProvider),
      height: _lineHeightFactor,
      fontFamily: 'Consolas',
    );

    _restoringView = true;
    try {
      _editorFocus.requestFocus();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      void pinScroll(double desired) {
        final pos = _editorScrollPosition();
        if (pos == null || !pos.hasContentDimensions) return;
        final target = desired.clamp(0.0, pos.maxScrollExtent);
        if ((pos.pixels - target).abs() > 0.5) {
          pos.jumpTo(target);
        }
        setState(() {
          _scrollOffset = target;
          _viewportHeight = pos.viewportDimension;
          _activeLine = lineIndexOfOffset(_controller.text, caret);
          _activeOutline = activeOutlineIndex(_outline, _activeLine);
        });
      }

      // 优先用记下的滚动；若异常再按光标估算
      var scrollTarget = saved.scrollOffset;
      if (scrollTarget < 0) {
        scrollTarget = _measureDocY(caret, style) - _viewportHeight * 0.25;
      }
      pinScroll(scrollTarget);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      // 恢复选区（若有），否则折叠光标
      if (saved.hasSelection) {
        final base = saved.selectionBase!.clamp(0, _controller.text.length);
        final extent =
            saved.selectionExtent!.clamp(0, _controller.text.length);
        final restored = TextSelection(baseOffset: base, extentOffset: extent);
        _freezeSelection = true;
        _rememberedRange = restored;
        _controller.selection = restored;
        _freezeSelection = false;
      } else {
        _controller.selection = TextSelection.collapsed(offset: caret);
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
      setState(() => _isDirty = false);
      ref.read(dirtyFilesProvider.notifier).update((s) {
        final next = Set.of(s);
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
    // 关闭 Tab / 切换文件前尽量落盘当前位置
    try {
      if (!_isDir && !_loading) {
        _flushPersistView();
      }
    } catch (_) {}
    _controller.removeListener(_onControllerChanged);
    _editorFocus.removeListener(_onEditorFocusChanged);
    // 延后到下一帧移除保存注册，避免在 dispose 期间修改 provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unregisterSave();
      _unregisterAgentRef();
    });
    _controller.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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

  /// 顶部粘性标题预览：以 # / ## / ### 展示当前章节链；正文区独立滚动。
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
        color: theme.colorScheme.surface,
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
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final gutterW =
                      LineNumberGutter.widthFor(_lineCount, fontSize);
                  final textViewportW =
                      math.max(80.0, constraints.maxWidth - gutterW);
                  final fp = _wrapFingerprint(fontSize, textViewportW);
                  final WrapLineMetrics metrics;
                  if (_wrapMetrics != null && _wrapSyncFingerprint == fp) {
                    metrics = _wrapMetrics!;
                  } else {
                    metrics = _computeWrapMetrics(
                      context,
                      fontSize,
                      textViewportW,
                    );
                    _wrapMetrics = metrics;
                    _scheduleSyncWrapMetricsFromEditable(fp, fontSize);
                  }

                  final textStyle = _editorTextStyle(fontSize);
                  final revealSel = _rememberedValidSelection();
                  final showSelOverlay = revealSel != null &&
                      !_editorFocus.hasFocus;

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: theme.dividerColor
                                  .withValues(alpha: 0.35),
                            ),
                          ),
                          color: theme.colorScheme.surfaceContainerLow
                              .withValues(alpha: 0.5),
                        ),
                        child: LineNumberGutter(
                          editorFieldKey: _editorFieldKey,
                          text: _controller.text,
                          lineCount: _lineCount,
                          scrollOffset: _scrollOffset,
                          fontSize: fontSize,
                          lineHeight: fontSize * _lineHeightFactor,
                          activeLine: _activeLine,
                        ),
                      ),
                      Expanded(
                        child: Stack(
                          children: [
                            NotificationListener<ScrollNotification>(
                              onNotification: (n) {
                                if (_jumpingToHeading) return false;
                                if (n.metrics.axis != Axis.vertical) {
                                  return false;
                                }
                                if (n.depth != 0) return false;
                                final pixels = n.metrics.pixels;
                                final viewport =
                                    n.metrics.viewportDimension;
                                if ((pixels - _scrollOffset).abs() > 0.5 ||
                                    (viewport - _viewportHeight).abs() >
                                        0.5) {
                                  setState(() {
                                    _scrollOffset = pixels;
                                    _viewportHeight = viewport;
                                  });
                                  _refreshActiveOutlineFromViewport();
                                  if (!_restoringView) {
                                    _schedulePersistView();
                                  }
                                }
                                return false;
                              },
                              child: TextField(
                                key: _editorFieldKey,
                                controller: _controller,
                                focusNode: _editorFocus,
                                onChanged: (_) {
                                  // 组字过程中不要 setState；已脏时也不要反复重建。
                                  if (_controller.value.isComposingRangeValid) {
                                    return;
                                  }
                                  if (!_isDirty) {
                                    setState(() => _isDirty = true);
                                  }
                                  ref
                                      .read(dirtyFilesProvider.notifier)
                                      .update((s) {
                                    if (s.contains(widget.path)) return s;
                                    return {...s, widget.path};
                                  });
                                },
                                maxLines: null,
                                expands: true,
                                // 桌面默认 BoxWidthStyle.max 会在行末选区按段落最宽行拉齐，
                                // 短行选到最后一字时高亮像盖住整行；改用 tight 贴合字符。
                                selectionWidthStyle: ui.BoxWidthStyle.tight,
                                keyboardType: TextInputType.multiline,
                                style: textStyle,
                                strutStyle: _editorStrut(fontSize),
                                decoration: const InputDecoration(
                                  border: InputBorder.none,
                                  contentPadding: _editorPadding,
                                ),
                                contextMenuBuilder: (ctx, editableTextState) {
                                  final chord =
                                      ref.read(sendAgentRefChordProvider);
                                  final defaults = editableTextState
                                      .contextMenuButtonItems;
                                  final value =
                                      editableTextState.textEditingValue;
                                  final sel = value.selection;
                                  final hasSel =
                                      sel.isValid && !sel.isCollapsed;
                                  final selectedText = hasSel
                                      ? sel.textInside(value.text)
                                      : '';
                                  return AdaptiveTextSelectionToolbar(
                                    anchors:
                                        editableTextState.contextMenuAnchors,
                                    children: [
                                      ...AdaptiveTextSelectionToolbar
                                          .getAdaptiveButtons(ctx, defaults),
                                      const Divider(height: 8),
                                      ...AdaptiveTextSelectionToolbar
                                          .getAdaptiveButtons(ctx, [
                                        ContextMenuButtonItem(
                                          label:
                                              '填入智能体 (${chord.label})',
                                          onPressed: () {
                                            ContextMenuController.removeAny();
                                            sendAgentReferenceToShell(
                                                ctx, ref);
                                          },
                                        ),
                                      ]),
                                      if (hasSel &&
                                          selectedText.trim().isNotEmpty)
                                        ComfyPromptFillSubmenuButton(
                                          selectedText: selectedText,
                                          hostContext: context,
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            if (showSelOverlay)
                              Positioned.fill(
                                child: SelectionHighlightOverlay(
                                  editorFieldKey: _editorFieldKey,
                                  selection: revealSel,
                                  scrollOffset: _scrollOffset,
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.28),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
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
    // Simple placeholder - desktop video playback needs media_kit
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
