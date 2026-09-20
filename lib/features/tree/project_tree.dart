import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../core/directory_parser.dart';
import '../../core/directory_watcher.dart';
import '../../core/editor_tabs.dart';
import '../../core/fs_context_menu.dart';
import '../../core/fs_drag.dart';
import '../../core/inline_fs_edit.dart';
import '../../core/media_types.dart';
import '../../core/progress.dart';
import '../../core/providers.dart';
import '../media/media_preview.dart';

/// 目录树行定位用：按路径相等匹配，避免 [GlobalObjectKey] 对临时字符串用 identical。
class _TreeRowKey extends GlobalKey {
  const _TreeRowKey(this.path) : super.constructor();

  final String path;

  @override
  bool operator ==(Object other) =>
      other is _TreeRowKey && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => '[_TreeRowKey $path]';
}

class ProjectTree extends ConsumerStatefulWidget {
  const ProjectTree({super.key});

  @override
  ConsumerState<ProjectTree> createState() => _ProjectTreeState();
}

class _ProjectTreeState extends ConsumerState<ProjectTree> {
  final _searchController = TextEditingController();
  final FocusNode _panelFocus = FocusNode(debugLabel: 'projectTree');
  final ScrollController _treeScrollController = ScrollController();
  String _searchText = '';

  /// 目录树单行大约高度（图标 16 + 上下 padding 4*2），用于估算滚动偏移。
  static const double _kTreeRowExtent = 28.0;

  @override
  void initState() {
    super.initState();
    _loadTree();
    // 自动监听项目目录外部变化（NAS/文件管理器拷贝、外部脚本生成等）。
    // 周期扫描，检测到文件数量变化时发出刷新 tick，树与网格同步更新。
    DirectoryWatcher.instance.start(onChange: () => _handleTreeChanged(''));
  }

  void _loadTree() {
    if (AppConfig.instance.isConfigured) {
      final projectRoot = AppConfig.instance.projectRoot;
      DirectoryParser.parseRootAsync(projectRoot).then((root) async {
        if (!mounted) return;
        ref.read(treeRootProvider.notifier).state = root;
        await _applyExpandedPaths(
          root,
          ref.read(expandedTreePathsProvider),
        );
        if (!mounted) return;
        setState(() {});
        // 定位到上次选中的文件/目录
        final anchor = ref.read(selectedFileProvider) ??
            ref.read(selectedDirProvider);
        if (anchor != null && anchor.isNotEmpty) {
          unawaited(_expandTo(anchor));
        }
        _seedTreeSelectionFromWorkspace();
        _publishExpandedPaths();
      });
    }
  }

  /// 启动恢复后：把树多选列表收成单一导航项，避免 file+dir 双高亮。
  void _seedTreeSelectionFromWorkspace() {
    if (ref.read(treeSelectionProvider).isNotEmpty) return;
    final mode = ref.read(contentModeProvider);
    if (mode == 'assets') {
      final dir = ref.read(selectedDirProvider);
      if (dir != null && dir.isNotEmpty) {
        _setTreeSelection([FsClipboardItem(path: dir, isDir: true)]);
      }
      return;
    }
    final file = ref.read(selectedFileProvider);
    if (file != null && file.isNotEmpty) {
      _setTreeSelection([FsClipboardItem(path: file, isDir: false)]);
      return;
    }
    final dir = ref.read(selectedDirProvider);
    if (dir != null && dir.isNotEmpty) {
      _setTreeSelection([FsClipboardItem(path: dir, isDir: true)]);
    }
  }

  /// 把 [paths] 应用到树：按路径深度排序，保证父目录先于子目录展开。
  Future<void> _applyExpandedPaths(
    ScriptNode root,
    List<String> paths,
  ) async {
    final sorted = List<String>.of(paths)
      ..sort((a, b) {
        final da = a.split(RegExp(r'[/\\]')).length;
        final db = b.split(RegExp(r'[/\\]')).length;
        return da.compareTo(db);
      });
    for (final p in sorted) {
      final node = _findNodeByPath(root, p);
      if (node == null || node.type == ScriptNodeType.file) continue;
      if (!node.isLoaded) {
        await DirectoryParser.loadChildrenAsync(node);
      }
      node.isExpanded = true;
    }
  }

  void _publishExpandedPaths() {
    final out = <String>[];
    _collectExpandedPaths(ref.read(treeRootProvider), out);
    ref.read(expandedTreePathsProvider.notifier).state = List.of(out);
  }

  /// 树自身结构变更统一入口：抛出一个 tick，由树与物料网格的监听各自刷新。
  void _handleTreeChanged(String _) {
    if (!mounted) return;
    if (!AppConfig.instance.isConfigured) return;
    ref.read(treeRefreshTickProvider.notifier).state++;
  }

  /// 树结构变更（重命名/删除/复制/新建）后整体重建，并展开定位到锚点。
/// ScriptNode.name/path 是 final，无法就地修改，故必须重新解析。
/// 重建前收集当前所有已展开节点路径，重建后恢复。
/// 避免用户手动展开的分支被收拢。
  void _refreshTree(String anchorPath) {
    if (!AppConfig.instance.isConfigured) return;
    // 1. 收集当前展开状态（优先用 provider，保证与持久化一致）
    final expandedPaths = List<String>.of(ref.read(expandedTreePathsProvider));
    if (expandedPaths.isEmpty) {
      _collectExpandedPaths(ref.read(treeRootProvider), expandedPaths);
    }
    final savedOffset = _treeScrollController.hasClients
        ? _treeScrollController.offset
        : null;

    _lastSyncedPath = null; // 强制重新执行展开
    DirectoryParser.parseRootAsync(AppConfig.instance.projectRoot).then(
        (root) async {
      if (!mounted) return;
      // 先在未挂上的新树上恢复展开。若先把折叠树交给界面，
      // 列表变短会把滚动夹到 0，展开后再也回不去。
      await _applyExpandedPaths(root, expandedPaths);
      if (!mounted) return;
      ref.read(treeRootProvider.notifier).state = root;
      setState(() {});
      _publishExpandedPaths();
      await _expandTo(anchorPath);
      if (!mounted) return;
      await _restoreTreeScroll(savedOffset);
    });
  }

  Future<void> _restoreTreeScroll(double? offset) async {
    if (offset == null) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_treeScrollController.hasClients) return;
    final max = _treeScrollController.position.maxScrollExtent;
    _treeScrollController.jumpTo(offset.clamp(0.0, max));
  }

  
/// DFS 收集所有已展开节点的路径。
  void _collectExpandedPaths(ScriptNode? node, List<String> out) {
    if (node == null) return;
    if (node.isExpanded) out.add(node.path);
    for (final child in node.children) {
      _collectExpandedPaths(child, out);
    }
  }

  
/// 按完全匹配路径查找节点（DFS）。
  ScriptNode? _findNodeByPath(ScriptNode? node, String path) {
    if (node == null) return null;
    if (node.path == path) return node;
    for (final child in node.children) {
      final found = _findNodeByPath(child, path);
      if (found != null) return found;
    }
    return null;
  }

  
/// 在项目根目录下新建顶层剧本（目录），成功后重建并定位到新剧本。
  Future<void> _createScript() async {
    if (!AppConfig.instance.isConfigured) return;
    beginInlineNewFolder(
      ref,
      parentDir: AppConfig.instance.projectRoot,
      surface: FsShortcutPane.tree,
    );
  }

  String? _lastSyncedPath;

  /// 根据目标路径，把左侧树的祖先节点逐级展开（含懒加载子节点）。
  Future<void> _expandTo(String? targetPath) async {
    if (targetPath == null || targetPath.isEmpty) return;
    if (targetPath == _lastSyncedPath) return;
    _lastSyncedPath = targetPath;

    final sep = Platform.pathSeparator;
    final root = ref.read(treeRootProvider);
    if (root == null) return;

    // 目标路径相对根目录的剩余部分（分隔成各级）
    String rest = targetPath;
    if (root.path.isNotEmpty && targetPath.startsWith(root.path)) {
      rest = targetPath.substring(root.path.length);
    }
    final segments = rest
        .split(sep)
        .where((s) => s.isNotEmpty)
        .toList();

    await _expandInto(root, segments, 0, sep);
  }

  /// 递归展开：在 [node].children 中找匹配 [segments[index]] 的子节点。
  /// 展开它并继续深入；必要时异步加载懒加载壳。
  Future<void> _expandInto(
      ScriptNode node, List<String> segments, int index, String sep) async {
    if (index >= segments.length) return;

    final want = segments[index];
    // 在所有后代节点中找路径直系匹配的子节点。
    ScriptNode? match;
    for (final child in node.children) {
      if (child.name == want ||
          child.path.endsWith('$sep$want') ||
          child.path == want) {
        match = child;
        break;
      }
    }
    if (match == null) return;

    final isFinal = index == segments.length - 1;
    if (!match.isLoaded) {
      // 懒加载壳：异步加载后再继续展开
      final nodeToExpand = match;
      final shouldExpand = !isFinal;
      await DirectoryParser.loadChildrenAsync(nodeToExpand);
      if (!mounted) return;
      if (shouldExpand) nodeToExpand.isExpanded = true;
      setState(() {});
      await _expandInto(nodeToExpand, segments, index + 1, sep);
      _publishExpandedPaths();
      return;
    }
    match.isExpanded = !isFinal ? true : match.isExpanded;
    setState(() {});
    await _expandInto(match, segments, index + 1, sep);
    if (isFinal) _publishExpandedPaths();
  }

  /// 标签「在目录树中定位」：展开后把目标滚进视窗并尽量居中。
  Future<void> _revealTreePath(String path) async {
    if (path.isEmpty) return;
    _lastSyncedPath = null;
    await _expandTo(path);
    if (!mounted) return;
    final node = _findNodeByPath(ref.read(treeRootProvider), path);
    final isDir = node != null && node.type != ScriptNodeType.file;
    _setTreeSelection([FsClipboardItem(path: path, isDir: isDir)]);
    await _scrollTreePathIntoView(path);
  }

  Future<void> _scrollTreePathIntoView(String path) async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    for (var attempt = 0; attempt < 12; attempt++) {
      final ctx = _TreeRowKey(path).currentContext;
      if (ctx != null && ctx.mounted) {
        if (_isTreeRowFullyVisible(ctx)) return;
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: attempt == 0
              ? const Duration(milliseconds: 220)
              : Duration.zero,
          curve: Curves.easeOutCubic,
        );
        return;
      }

      // 目标所在根节点尚未被 ListView.builder 构建：先按估算偏移跳转。
      if (_treeScrollController.hasClients) {
        final estimated = _estimateOffsetForPath(path);
        if (estimated != null) {
          final pos = _treeScrollController.position;
          final view = pos.viewportDimension;
          final target = (estimated - (view - _kTreeRowExtent) / 2)
              .clamp(0.0, pos.maxScrollExtent);
          if ((target - pos.pixels).abs() > 1) {
            _treeScrollController.jumpTo(target);
          }
        }
      }

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
  }

  bool _isTreeRowFullyVisible(BuildContext rowContext) {
    final rowBox = rowContext.findRenderObject();
    if (rowBox is! RenderBox || !rowBox.hasSize) return false;
    final scrollable = Scrollable.maybeOf(rowContext);
    if (scrollable == null) return true;
    final viewportBox = scrollable.context.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.hasSize) return false;

    final topLeft = rowBox.localToGlobal(Offset.zero, ancestor: viewportBox);
    final bottom = topLeft.dy + rowBox.size.height;
    return topLeft.dy >= -0.5 && bottom <= viewportBox.size.height + 0.5;
  }

  bool _isSameOrUnder(String path, String ancestor) {
    if (path == ancestor) return true;
    final sep = Platform.pathSeparator;
    final prefix = ancestor.endsWith(sep) ? ancestor : '$ancestor$sep';
    return path.startsWith(prefix);
  }

  /// 估算目标行相对 ListView 内容顶部的偏移（嵌套 Column 树）。
  double? _estimateOffsetForPath(String path) {
    final root = ref.read(treeRootProvider);
    if (root == null) return null;
    final visibleRoots = _searchText.isEmpty
        ? root.children
        : _filterNodes(root.children);
    var offset = 4.0; // ListView vertical padding

    bool walk(List<ScriptNode> nodes) {
      for (final n in nodes) {
        if (n.path == path) return true;
        if (_isSameOrUnder(path, n.path)) {
          offset += _kTreeRowExtent;
          if (n.isExpanded && walk(n.children)) return true;
          return false;
        }
        offset += _estimateSubtreeExtent(n);
      }
      return false;
    }

    if (!walk(visibleRoots)) return null;
    return offset;
  }

  double _estimateSubtreeExtent(ScriptNode node) {
    var h = _kTreeRowExtent;
    if (!node.isExpanded) return h;
    for (final c in node.children) {
      h += _estimateSubtreeExtent(c);
    }
    return h;
  }

  Future<void> _ensureInlineAnchorVisible(
    String anchor, {
    required bool expandLeaf,
  }) async {
    if (!mounted || anchor.isEmpty) return;
    _lastSyncedPath = null;
    await _expandTo(anchor);
    if (!expandLeaf) return;
    final root = ref.read(treeRootProvider);
    final node = _findNodeByPath(root, anchor);
    if (node == null || node.type == ScriptNodeType.file) return;
    if (!node.isLoaded) {
      await DirectoryParser.loadChildrenAsync(node);
      if (!mounted) return;
    }
    node.isExpanded = true;
    setState(() {});
    _publishExpandedPaths();
  }

  @override
  void dispose() {
    DirectoryWatcher.instance.stop();
    _searchController.dispose();
    _panelFocus.dispose();
    _treeScrollController.dispose();
    super.dispose();
  }

  void _ensurePanelFocus() {
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
    if (!_panelFocus.hasFocus) _panelFocus.requestFocus();
  }

  void _whenNotTyping(VoidCallback action) {
    if (_isTypingInTextField()) return;
    action();
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

  void _setTreeSelection(List<FsClipboardItem> items) {
    ref.read(treeSelectionProvider.notifier).state = items;
    ref.read(treeSelectionByCtrlProvider.notifier).state = false;
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
  }

  void _clearTreeMultiSelection() {
    final mode = ref.read(contentModeProvider);
    if (mode == 'editor') {
      final file = ref.read(selectedFileProvider);
      if (file != null && file.isNotEmpty) {
        _setTreeSelection([FsClipboardItem(path: file, isDir: false)]);
        return;
      }
    }
    final dir = ref.read(selectedDirProvider);
    if (dir != null && dir.isNotEmpty) {
      _setTreeSelection([FsClipboardItem(path: dir, isDir: true)]);
      return;
    }
    _setTreeSelection([]);
  }

  String? _pasteDestDir() {
    final items = ref.read(treeSelectionProvider);
    if (items.length == 1) {
      final it = items.first;
      return it.isDir ? it.path : File(it.path).parent.path;
    }
    return ref.read(selectedDirProvider) ??
        (AppConfig.instance.projectRoot.isEmpty
            ? null
            : AppConfig.instance.projectRoot);
  }

  Future<void> _openTreeItem(FsClipboardItem item) async {
    if (item.isDir) {
      ref.read(selectedDirProvider.notifier).state = item.path;
      ref.read(contentModeProvider.notifier).state = 'assets';
      _setTreeSelection([item]);
      return;
    }
    switch (classifyMedia(item.path)) {
      case MediaKind.image:
        showImageViewerDialog(context, item.path);
        return;
      case MediaKind.video:
        showMediaPreviewDialog(context, path: item.path, isVideo: true);
        return;
      case MediaKind.audio:
        showMediaPreviewDialog(context, path: item.path, isVideo: false);
        return;
      case MediaKind.markdown:
      case MediaKind.other:
        openEditorTabRef(ref, path: item.path, pin: true);
        _setTreeSelection([item]);
    }
  }

  Future<void> _fsShortcut(String action) async {
    if (!mounted) return;
    if (action == 'escape') {
      _clearTreeMultiSelection();
      return;
    }
    if (action == 'selectAll' || action == 'backspace') {
      // 目录树暂不支持全选 / Backspace 上一级。
      return;
    }
    final container = ProviderScope.containerOf(context, listen: false);

    if (action == 'paste') {
      final dest = _pasteDestDir();
      if (dest == null || dest.isEmpty) return;
      if (ref.read(fsClipboardProvider) == null) return;
      final name = dest.split(Platform.pathSeparator).last;
      await runFsAction(
        context: context,
        container: container,
        action: 'paste',
        path: dest,
        isDir: true,
        displayName: name.isEmpty ? dest : name,
        surface: FsShortcutPane.tree,
        onOpen: () async {},
        onChanged: () {
          _setTreeSelection([]);
          _handleTreeChanged(dest);
        },
      );
      return;
    }

    final items = ref.read(treeSelectionProvider);
    if (items.isEmpty) return;
    if ((action == 'rename' || action == 'open') && items.length != 1) return;

    final target = items.first;
    final name = target.path.split(Platform.pathSeparator).last;
    await runFsAction(
      context: context,
      container: container,
      action: action,
      path: target.path,
      isDir: target.isDir,
      displayName: name,
      multiItems: items.length > 1 ? items : null,
      surface: FsShortcutPane.tree,
      onOpen: () async => _openTreeItem(target),
      onChanged: () {
        _setTreeSelection([]);
        _handleTreeChanged(
          target.isDir ? target.path : File(target.path).parent.path,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final root = ref.watch(treeRootProvider);

    // 中间视图导航时，左侧树同步展开定位到对应路径。
    ref.listen(selectedDirProvider, (_, next) {
      unawaited(_expandTo(next));
    });
    ref.listen(selectedFileProvider, (_, next) {
      unawaited(_expandTo(next));
    });

    // 标签「在目录树中定位」：强制展开并滚进视窗（尽量居中）。
    ref.listen(treeRevealRequestProvider, (prev, next) {
      if (next == null || prev?.nonce == next.nonce) return;
      unawaited(_revealTreePath(next.path));
    });

    // 物料网格发生结构变更时，重建树以保持两边同步
    ref.listen(treeRefreshTickProvider, (prev, next) {
      if (next == prev || !AppConfig.instance.isConfigured) return;
      final anchor =
          ref.read(selectedDirProvider) ?? AppConfig.instance.projectRoot;
      _refreshTree(anchor);
    });

    // 主布局下发的文件快捷键（不依赖本面板是否持有焦点）。
    ref.listen(fsShortcutRequestProvider, (prev, next) {
      if (next == null || next.pane != FsShortcutPane.tree) return;
      if (prev?.nonce == next.nonce) return;
      _whenNotTyping(() => unawaited(_fsShortcut(next.action)));
    });

    // 原地新建/重命名：展开并滚到目标位置。
    ref.listen(inlineFsEditProvider, (prev, next) {
      if (next == null || prev?.nonce == next.nonce) return;
      if (next.surface != FsShortcutPane.tree) return;
      final anchor = next.path ?? next.parentDir;
      unawaited(_ensureInlineAnchorVisible(anchor, expandLeaf: next.path == null));
    });

    return Focus(
      focusNode: _panelFocus,
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Container(
              height: kColumnTopBarHeight,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context)
                        .dividerColor
                        .withValues(alpha: 0.35),
                  ),
                  bottom: BorderSide(
                    color: Theme.of(context)
                        .dividerColor
                        .withValues(alpha: 0.35),
                  ),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(8, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _searchText = v),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: '搜索剧本 / 文件...',
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 18),
                        suffixIcon: _searchText.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _searchText = '');
                                },
                              )
                            : null,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surface
                            .withValues(alpha: 0.55),
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 6),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '新建顶层剧本',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: _createScript,
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '手动刷新目录',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => _handleTreeChanged(''),
                  ),
                ],
              ),
            ),
            Expanded(
              child: root == null
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2)),
                          SizedBox(height: 12),
                          Text('正在加载项目目录...'),
                        ],
                      ),
                    )
                  : GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTapDown: (_) => _ensurePanelFocus(),
                      child: _buildTree(context, root),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTree(BuildContext context, ScriptNode root) {
    final visibleRoots = _searchText.isEmpty
        ? root.children
        : _filterNodes(root.children);
    final inline = ref.watch(inlineFsEditProvider);
    final creatingAtRoot = inline != null &&
        inline.matchesCreateUnder(
          AppConfig.instance.projectRoot,
          FsShortcutPane.tree,
        );
    final rootCreateEdit = creatingAtRoot ? inline : null;

    if (visibleRoots.isEmpty && rootCreateEdit == null) {
      return const Center(child: Text('无匹配结果'));
    }

    return ListView.builder(
      controller: _treeScrollController,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visibleRoots.length + (rootCreateEdit != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (rootCreateEdit != null && index == 0) {
          return _InlineCreateTreeRow(
            level: 0,
            edit: rootCreateEdit,
            onTreeChanged: _handleTreeChanged,
          );
        }
        final nodeIndex = rootCreateEdit != null ? index - 1 : index;
        return _TreeNodeWidget(
          node: visibleRoots[nodeIndex],
          level: 0,
          onTreeChanged: _handleTreeChanged,
          onInteract: _ensurePanelFocus,
        );
      },
    );
  }

  List<ScriptNode> _filterNodes(List<ScriptNode> nodes) {
    final result = <ScriptNode>[];
    for (final node in nodes) {
      if (node.name.contains(_searchText)) {
        result.add(node);
      } else {
        final filtered = _filterNodes(node.children);
        if (filtered.isNotEmpty) {
          result.add(ScriptNode(
            name: node.name,
            path: node.path,
            type: node.type,
            children: filtered,
            isExpanded: true,
          ));
        }
      }
    }
    return result;
  }
}

class _TreeNodeWidget extends ConsumerStatefulWidget {
  final ScriptNode node;
  final int level;

  
/// 树结构变更（重命名/删除/复制/新建子目录）后，由父级重建并定位。
  final ValueChanged<String> onTreeChanged;
  final VoidCallback onInteract;

  const _TreeNodeWidget({
    required this.node,
    required this.level,
    required this.onTreeChanged,
    required this.onInteract,
  });

  @override
  ConsumerState<_TreeNodeWidget> createState() => _TreeNodeWidgetState();
}

class _TreeNodeWidgetState extends ConsumerState<_TreeNodeWidget> {
  Offset _menuPos = Offset.zero;

  void _syncExpandedPathsToProvider() {
    final out = <String>[];
    void walk(ScriptNode? n) {
      if (n == null) return;
      if (n.isExpanded) out.add(n.path);
      for (final c in n.children) {
        walk(c);
      }
    }

    walk(ref.read(treeRootProvider));
    ref.read(expandedTreePathsProvider.notifier).state = List.of(out);
  }

  
/// 目录节点的进度状态徽章（未开始时隐藏）。
  Widget _progressBubble(ScriptNode node) {
    if (node.type == ScriptNodeType.file) return const SizedBox.shrink();
    final status =
        ref.watch(episodeStatusesProvider)[node.path];
    if (status == null || status == EpisodeStatus.notStarted) {
      return const SizedBox.shrink();
    }
    final color = Color(EpisodeStatus.colors[status] ?? 0xFF9E9E9E);
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          EpisodeStatus.labelIcons[status] ?? status,
          style: TextStyle(
            fontSize: 9,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  
  /// 打开文件：与中间物料栏行为一致——图片弹查看、视频/音频内嵌预览。
  /// 其余（含 .md）进入编辑器。[pin] 为 true 时固定标签（双击 / 显式打开）。
  void _openFile(String path, {bool pin = false}) {
    switch (classifyMedia(path)) {
      case MediaKind.image:
        showImageViewerDialog(context, path);
        return;
      case MediaKind.video:
        showMediaPreviewDialog(context, path: path, isVideo: true);
        return;
      case MediaKind.audio:
        showMediaPreviewDialog(context, path: path, isVideo: false);
        return;
      case MediaKind.markdown:
      case MediaKind.other:
        openEditorTabRef(ref, path: path, pin: pin);
    }
  }

  
  /// 右键操作菜单（与中间素材栏共用 [showFsContextMenu]）。
  Future<void> _showMenu(BuildContext context) async {
    final node = widget.node;
    final isFile = node.type == ScriptNodeType.file;
    final dir = Directory(node.path).parent.path;
    var multi = ref.read(treeSelectionProvider);
    final inMulti = multi.any((i) => i.path == node.path);
    if (!inMulti) {
      multi = [FsClipboardItem(path: node.path, isDir: !isFile)];
      ref.read(treeSelectionProvider.notifier).state = multi;
      ref.read(treeSelectionByCtrlProvider.notifier).state = false;
    }
    await showFsContextMenu(
      context: context,
      globalPosition: _menuPos,
      path: node.path,
      isDir: !isFile,
      displayName: node.name,
      multiItems: multi.length > 1 ? multi : null,
      surface: FsShortcutPane.tree,
      onOpen: () async {
        if (isFile) {
          _openFile(node.path, pin: true);
        } else {
          _selectDir(node.path, forceAssets: true);
        }
      },
      onChanged: () {
        ref.read(treeSelectionProvider.notifier).state = [];
        ref.read(treeSelectionByCtrlProvider.notifier).state = false;
        widget.onTreeChanged(isFile ? dir : node.path);
      },
    );
  }

  /// 选中目录并写入 [selectedDirProvider]。
  ///
  /// 默认**不**切换中间栏模式：仅在素材栏时，中间网格会随 [selectedDirProvider]
  /// 同步；[forceAssets] 为 true 时（如右键「打开」）才切到素材栏。
  void _selectDir(String dirPath, {bool forceAssets = false}) {
    ref.read(selectedDirProvider.notifier).state = dirPath;
    _setSingleTreeSelection(path: dirPath, isDir: true);
    if (forceAssets) {
      ref.read(contentModeProvider.notifier).state = 'assets';
    }
  }

  bool get _ctrlHeld =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _setSingleTreeSelection({
    required String path,
    required bool isDir,
    bool byCtrl = false,
  }) {
    ref.read(treeSelectionProvider.notifier).state = [
      FsClipboardItem(path: path, isDir: isDir),
    ];
    ref.read(treeSelectionByCtrlProvider.notifier).state = byCtrl;
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
  }

  /// Ctrl 叠加多选（不再从普通导航状态偷偷塞入旧项）。
  void _toggleTreeSelectionCtrl({required String path, required bool isDir}) {
    final current = List<FsClipboardItem>.of(ref.read(treeSelectionProvider));
    final idx = current.indexWhere((i) => i.path == path);
    if (idx >= 0) {
      current.removeAt(idx);
    } else {
      current.add(FsClipboardItem(path: path, isDir: isDir));
    }
    ref.read(treeSelectionProvider.notifier).state = current;
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
    if (current.isEmpty) {
      ref.read(treeSelectionByCtrlProvider.notifier).state = false;
    }
  }

  void _onNodeTap({required bool isFile}) {
    widget.onInteract();
    final path = widget.node.path;
    if (_ctrlHeld) {
      final byCtrl = ref.read(treeSelectionByCtrlProvider);
      if (!byCtrl) {
        // 首次 Ctrl+单击：丢弃普通选中，只保留当前项；文件不打开。
        // 不改 selectedFileProvider，避免编辑器「当前文档」被未打开的文件顶掉。
        _setSingleTreeSelection(path: path, isDir: !isFile, byCtrl: true);
        if (!isFile) {
          ref.read(selectedDirProvider.notifier).state = path;
        }
      } else {
        _toggleTreeSelectionCtrl(path: path, isDir: !isFile);
        if (!isFile) {
          final still =
              ref.read(treeSelectionProvider).any((i) => i.path == path);
          if (still) {
            ref.read(selectedDirProvider.notifier).state = path;
          }
        }
      }
      return;
    }
    if (isFile) {
      _setSingleTreeSelection(path: path, isDir: false);
      _openFile(path);
    } else {
      // 目录：只选中；素材栏下中间同步，文档/生成栏不抢切模式。
      _selectDir(path);
    }
  }

  Future<void> _toggleExpand() async {
    widget.onInteract();
    final node = widget.node;
    if (node.type == ScriptNodeType.file) return;
    final canExpand = !node.isLoaded || node.children.isNotEmpty;
    if (!canExpand) return;

    final expanding = !node.isExpanded;
    node.isExpanded = expanding;
    setState(() {});

    if (expanding) {
      // 展开：素材栏下让中间进入该文件夹，并选中当前项。
      // 折叠则只收起树，不改选中、也不把中间甩到父级（体感更稳）。
      _selectDir(node.path);
      if (!node.isLoaded) {
        await DirectoryParser.loadChildrenAsync(node);
        if (!mounted) return;
        setState(() {});
      }
    }
    _syncExpandedPathsToProvider();
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final level = widget.level;
    final isFile = node.type == ScriptNodeType.file;
    final isExpanded = node.isExpanded;
    // 目录总是可尝试展开：未加载（懒加载壳）或已加载且有子项
    final canExpand = !isFile && (!node.isLoaded || node.children.isNotEmpty);
    final fileSelected = ref.watch(selectedFileProvider) == node.path;
    final dirSelected =
        !isFile && ref.watch(selectedDirProvider) == node.path;
    final treeMulti = ref.watch(treeSelectionProvider);
    final inTreeMulti = treeMulti.any((i) => i.path == node.path);
    // 有树选中列表时只认它；否则只高亮一个导航目标。
    // selectedFile / selectedDir 会同时被工作区恢复，不能 OR 否则像多选。
    final bool selected;
    if (treeMulti.isNotEmpty) {
      selected = inTreeMulti;
    } else {
      final mode = ref.watch(contentModeProvider);
      if (mode == 'assets') {
        selected = !isFile && dirSelected;
      } else {
        // 文档 / 生成栏：优先文件；没有文件再亮目录。
        final hasFile =
            ref.watch(selectedFileProvider)?.isNotEmpty == true;
        selected =
            hasFile ? (isFile && fileSelected) : (!isFile && dirSelected);
      }
    }
    final multiDrag = treeMulti.length > 1 && inTreeMulti ? treeMulti : null;
    final scheme = Theme.of(context).colorScheme;
    final inline = ref.watch(inlineFsEditProvider);
    final renaming = inline?.matchesRename(node.path, FsShortcutPane.tree) == true;
    final renameEdit = renaming ? inline : null;
    final createEdit = (inline != null &&
            inline.matchesCreateUnder(node.path, FsShortcutPane.tree) &&
            isExpanded)
        ? inline
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          key: _TreeRowKey(node.path),
          padding: EdgeInsets.only(left: 8.0 + level * 12.0, right: 2),
          child: FsContextMenuTarget(
            path: node.path,
            isDir: !isFile,
            displayName: node.name,
            onOpen: () async {
              if (isFile) {
                _openFile(node.path, pin: true);
              } else {
                _selectDir(node.path, forceAssets: true);
              }
            },
            onChanged: () {
              ref.read(treeSelectionProvider.notifier).state = [];
              ref.read(treeSelectionByCtrlProvider.notifier).state = false;
              widget.onTreeChanged(
                isFile ? Directory(node.path).parent.path : node.path,
              );
            },
            child: FsDragDropShell(
              path: node.path,
              isDir: !isFile,
              displayName: node.name,
              dropIntoDir: isFile ? null : node.path,
              dragItems: multiDrag,
              onChanged: () {
                ref.read(treeSelectionProvider.notifier).state = [];
                ref.read(treeSelectionByCtrlProvider.notifier).state = false;
                widget.onTreeChanged(
                  isFile ? Directory(node.path).parent.path : node.path,
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // 原地重命名时只留输入框描边，避免「选中框套编辑框」。
                  color: selected && !renaming
                      ? scheme.primary.withValues(alpha: 0.15)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  border: selected && !renaming
                      ? Border.all(
                          color: scheme.primary.withValues(alpha: 0.55),
                        )
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: renaming ? null : () => _onNodeTap(isFile: isFile),
                        onDoubleTap: renaming
                            ? null
                            : () {
                                if (isFile) {
                                  _setSingleTreeSelection(
                                    path: node.path,
                                    isDir: false,
                                  );
                                  _openFile(node.path, pin: true);
                                } else {
                                  _toggleExpand();
                                }
                              },
                        onSecondaryTapDown: renaming
                            ? null
                            : (d) => _menuPos = d.globalPosition,
                        onSecondaryTap:
                            renaming ? null : () => _showMenu(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(
                                _iconFor(node),
                                size: 16,
                                color: _iconColorFor(context, node),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: renameEdit != null
                                    ? InlineFsNameField(
                                        key: ValueKey(
                                            'rename-${renameEdit.nonce}'),
                                        initialName: renameEdit.initialName,
                                        isDir: !isFile,
                                        onSubmit: (name) => unawaited(
                                          _commitInline(renameEdit, name),
                                        ),
                                        onCancel: () =>
                                            clearInlineFsEdit(ref),
                                      )
                                    : Text(
                                        node.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w400,
                                          color: isExpanded
                                              ? scheme.primary
                                              : null,
                                        ),
                                      ),
                              ),
                              if (!renaming) _progressBubble(node),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (canExpand && !renaming)
                      InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: _toggleExpand,
                        onSecondaryTapDown: (d) =>
                            _menuPos = d.globalPosition,
                        onSecondaryTap: () => _showMenu(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 4,
                          ),
                          child: Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 16,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (isExpanded) ...[
          if (createEdit != null)
            _InlineCreateTreeRow(
              level: level + 1,
              edit: createEdit,
              onTreeChanged: widget.onTreeChanged,
            ),
          if (!node.isLoaded)
            const Padding(
              padding: EdgeInsets.only(left: 24, top: 2, bottom: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 6),
                  Text('加载中...', style: TextStyle(fontSize: 12)),
                ],
              ),
            )
          else
            ...node.children.map((c) => _TreeNodeWidget(
                  node: c,
                  level: level + 1,
                  onTreeChanged: widget.onTreeChanged,
                  onInteract: widget.onInteract,
                )),
        ],
      ],
    );
  }

  Future<void> _commitInline(InlineFsEdit edit, String name) async {
    final created = await commitInlineFsEdit(context, ref, edit, name);
    if (!mounted || created == null) return;
    widget.onTreeChanged(
      edit.kind == InlineFsEditKind.rename
          ? (edit.isDir ? created : Directory(created).parent.path)
          : edit.parentDir,
    );
    if (edit.kind == InlineFsEditKind.rename) {
      _setSingleTreeSelection(path: created, isDir: edit.isDir);
      return;
    }
    if (edit.kind == InlineFsEditKind.newDocument) {
      _openFile(created, pin: true);
    } else if (edit.kind == InlineFsEditKind.newFolder) {
      _selectDir(created);
    }
  }

  IconData _iconFor(ScriptNode node) {
    switch (node.type) {
      case ScriptNodeType.script:
        return Icons.folder;
      case ScriptNodeType.season:
        return Icons.groups_outlined;
      case ScriptNodeType.episode:
        return Icons.movie_outlined;
      case ScriptNodeType.folder:
        return Icons.folder_outlined;
      case ScriptNodeType.file:
        if (node.name.endsWith('.md')) return Icons.description_outlined;
        if (node.name.endsWith('.png') ||
            node.name.endsWith('.jpg') ||
            node.name.endsWith('.jpeg')) {
          return Icons.image_outlined;
        }
        if (node.name.endsWith('.mp4') || node.name.endsWith('.mov')) {
          return Icons.videocam_outlined;
        }
        if (node.name.endsWith('.wav') || node.name.endsWith('.mp3')) {
          return Icons.music_note_outlined;
        }
        return Icons.insert_drive_file_outlined;
    }
  }

  Color _iconColorFor(BuildContext context, ScriptNode node) {
    switch (node.type) {
      case ScriptNodeType.script:
        return Colors.orange;
      case ScriptNodeType.season:
        return Colors.teal;
      case ScriptNodeType.episode:
        return Colors.indigo;
      case ScriptNodeType.folder:
        return Colors.grey;
      case ScriptNodeType.file:
        if (node.name.endsWith('.md')) return Colors.blueGrey;
        if (node.name.endsWith('.png') ||
            node.name.endsWith('.jpg') ||
            node.name.endsWith('.jpeg')) {
          return Colors.purple;
        }
        if (node.name.endsWith('.mp4') || node.name.endsWith('.mov')) {
          return Colors.red;
        }
        if (node.name.endsWith('.wav') || node.name.endsWith('.mp3')) {
          return Colors.pink;
        }
        return Colors.blueGrey;
    }
  }
}

/// 目录树中的「新建」占位行（原地输入）。
class _InlineCreateTreeRow extends ConsumerWidget {
  const _InlineCreateTreeRow({
    required this.level,
    required this.edit,
    required this.onTreeChanged,
  });

  final int level;
  final InlineFsEdit edit;
  final ValueChanged<String> onTreeChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final isFolder = edit.kind == InlineFsEditKind.newFolder;
    return Padding(
      padding: EdgeInsets.only(left: 8.0 + level * 12.0, right: 2, top: 2),
      child: Row(
        children: [
          Icon(
            isFolder ? Icons.folder_outlined : Icons.description_outlined,
            size: 16,
            color: isFolder ? Colors.grey : Colors.blueGrey,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: InlineFsNameField(
              key: ValueKey('create-${edit.nonce}'),
              initialName: edit.initialName,
              isDir: isFolder,
              onSubmit: (name) async {
                final created =
                    await commitInlineFsEdit(context, ref, edit, name);
                if (created == null) return;
                onTreeChanged(edit.parentDir);
                if (edit.kind == InlineFsEditKind.newDocument) {
                  openEditorTabRef(ref, path: created, pin: true);
                } else {
                  ref.read(selectedDirProvider.notifier).state = created;
                }
              },
              onCancel: () => clearInlineFsEdit(ref),
            ),
          ),
          Icon(Icons.edit_outlined, size: 14, color: scheme.primary),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
