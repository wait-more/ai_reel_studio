import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../core/directory_parser.dart';
import '../../core/directory_watcher.dart';
import '../../core/file_actions.dart';
import '../../core/fs_context_menu.dart';
import '../../core/fs_drag.dart';
import '../../core/media_types.dart';
import '../../core/progress.dart';
import '../../core/providers.dart';
import '../media/media_preview.dart';

class ProjectTree extends ConsumerStatefulWidget {
  const ProjectTree({super.key});

  @override
  ConsumerState<ProjectTree> createState() => _ProjectTreeState();
}

class _ProjectTreeState extends ConsumerState<ProjectTree> {
  final _searchController = TextEditingController();
  final FocusNode _panelFocus = FocusNode(debugLabel: 'projectTree');
  String _searchText = '';

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
          _expandTo(anchor);
        }
        _publishExpandedPaths();
      });
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

    _lastSyncedPath = null; // 强制重新执行展开
    DirectoryParser.parseRootAsync(AppConfig.instance.projectRoot).then(
        (root) async {
      if (!mounted) return;
      ref.read(treeRootProvider.notifier).state = root;
      // 2. 恢复用户展开的分支（懒加载壳需先加载子项）
      await _applyExpandedPaths(root, expandedPaths);
      if (!mounted) return;
      setState(() {});
      _publishExpandedPaths();
      // 3. 锚定到触发变更的位置
      _expandTo(anchorPath);
    });
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
    final projectRoot = AppConfig.instance.projectRoot;
    final name = await promptTextDialog(
      context,
      title: '新建顶层剧本',
      label: '建议格式：编号_类型_名称（如 004_悬疑_深渊来电）',
    );
    if (name == null || name.trim().isEmpty) return;
    final target = '$projectRoot${Platform.pathSeparator}${name.trim()}';
    try {
      await Directory(target).create(recursive: true);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('创建失败：$e', style: const TextStyle(fontSize: 12)),
          duration: const Duration(seconds: 3),
        ));
      }
      return;
    }
    _handleTreeChanged(target);
  }

  String? _lastSyncedPath;

  
/// 根据目标路径，把左侧树的祖先节点逐级展开（含懒加载子节点）。
  void _expandTo(String? targetPath) {
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

    _expandInto(root, segments, 0, sep);
  }

  
/// 递归展开：在 [node].children 中找匹配 [segments[index]] 的子节点。
/// 展开它并继续深入；必要时异步加载懒加载壳。
  void _expandInto(
      ScriptNode node, List<String> segments, int index, String sep) {
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
      DirectoryParser.loadChildrenAsync(nodeToExpand).then((_) {
        if (!mounted) return;
        if (shouldExpand) nodeToExpand.isExpanded = true;
        setState(() {});
        _expandInto(nodeToExpand, segments, index + 1, sep);
        _publishExpandedPaths();
      });
      return;
    }
    match.isExpanded = !isFinal ? true : match.isExpanded;
    setState(() {});
    _expandInto(match, segments, index + 1, sep);
    if (isFinal) _publishExpandedPaths();
  }

  @override
  void dispose() {
    DirectoryWatcher.instance.stop();
    _searchController.dispose();
    _panelFocus.dispose();
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
        ref.read(selectedFileProvider.notifier).state = item.path;
        final tabs = ref.read(openTabsProvider);
        if (!tabs.contains(item.path)) {
          ref.read(openTabsProvider.notifier).state = [...tabs, item.path];
        }
        ref.read(contentModeProvider.notifier).state = 'editor';
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
    ref.listen(selectedDirProvider, (_, next) => _expandTo(next));
    ref.listen(selectedFileProvider, (_, next) => _expandTo(next));

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

    return Focus(
      focusNode: _panelFocus,
      child: Container(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 0),
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
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add, size: 20),
                    tooltip: '新建顶层剧本',
                    onPressed: _createScript,
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '手动刷新目录',
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

    if (visibleRoots.isEmpty) {
      return const Center(child: Text('无匹配结果'));
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visibleRoots.length,
      itemBuilder: (context, index) {
        return _TreeNodeWidget(
          node: visibleRoots[index],
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
/// 其余（含 .md）进入编辑器。
  void _openFile(String path) {
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
        ref.read(selectedFileProvider.notifier).state = path;
        final tabs = ref.read(openTabsProvider);
        if (!tabs.contains(path)) {
          ref.read(openTabsProvider.notifier).state = [...tabs, path];
        }
        ref.read(contentModeProvider.notifier).state = 'editor';
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
    }
    await showFsContextMenu(
      context: context,
      globalPosition: _menuPos,
      path: node.path,
      isDir: !isFile,
      displayName: node.name,
      multiItems: multi.length > 1 ? multi : null,
      onOpen: () async {
        if (isFile) {
          _openFile(node.path);
        } else {
          ref.read(selectedDirProvider.notifier).state = node.path;
          ref.read(contentModeProvider.notifier).state = 'assets';
        }
      },
      onChanged: () {
        ref.read(treeSelectionProvider.notifier).state = [];
        widget.onTreeChanged(isFile ? dir : node.path);
      },
    );
  }

  /// 折叠后中间栏回到的父目录；不超过项目根。
  String _parentDirForAssets(String dirPath) {
    final parent = Directory(dirPath).parent.path;
    final root = AppConfig.instance.projectRoot;
    if (root.isEmpty) return parent;
    final rootNorm = root.toLowerCase();
    final parentNorm = parent.toLowerCase();
    if (parentNorm == rootNorm) return root;
    final prefix = rootNorm.endsWith(Platform.pathSeparator)
        ? rootNorm
        : '$rootNorm${Platform.pathSeparator}';
    if (!parentNorm.startsWith(prefix)) return root;
    return parent;
  }

  void _selectDirInAssets(String dirPath) {
    ref.read(selectedDirProvider.notifier).state = dirPath;
    ref.read(contentModeProvider.notifier).state = 'assets';
    // 与单击目录一致：同步树选中，避免仍高亮旧文件。
    _setSingleTreeSelection(path: dirPath, isDir: true);
  }

  bool get _ctrlHeld =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _setSingleTreeSelection({required String path, required bool isDir}) {
    ref.read(treeSelectionProvider.notifier).state = [
      FsClipboardItem(path: path, isDir: isDir),
    ];
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
  }

  void _toggleTreeSelection({required String path, required bool isDir}) {
    final current = List<FsClipboardItem>.of(ref.read(treeSelectionProvider));
    // 从「当前高亮项」起步，而不是同时塞入 file+dir 两个导航状态。
    if (current.isEmpty) {
      final mode = ref.read(contentModeProvider);
      if (mode == 'editor') {
        final file = ref.read(selectedFileProvider);
        if (file != null && file.isNotEmpty && file != path) {
          current.add(FsClipboardItem(path: file, isDir: false));
        }
      } else {
        final dir = ref.read(selectedDirProvider);
        if (dir != null && dir.isNotEmpty && dir != path) {
          current.add(FsClipboardItem(path: dir, isDir: true));
        }
      }
    }
    final idx = current.indexWhere((i) => i.path == path);
    if (idx >= 0) {
      current.removeAt(idx);
    } else {
      current.add(FsClipboardItem(path: path, isDir: isDir));
    }
    ref.read(treeSelectionProvider.notifier).state = current;
    ref.read(fsShortcutPaneProvider.notifier).state = FsShortcutPane.tree;
  }

  void _onNodeTap({required bool isFile}) {
    widget.onInteract();
    final path = widget.node.path;
    if (_ctrlHeld) {
      _toggleTreeSelection(path: path, isDir: !isFile);
      return;
    }
    // 普通单击：始终重置为单项选中（清掉之前的多选/残留）。
    _setSingleTreeSelection(path: path, isDir: !isFile);
    if (isFile) {
      _openFile(path);
    } else {
      _selectDirInAssets(path);
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
      // 展开：中间栏同步进该文件夹
      _selectDirInAssets(node.path);
      if (!node.isLoaded) {
        await DirectoryParser.loadChildrenAsync(node);
        if (!mounted) return;
        setState(() {});
      }
    } else {
      // 折叠：中间栏回到该文件夹所在层级（父目录）
      _selectDirInAssets(_parentDirForAssets(node.path));
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
    // 有树选中列表时只认它；否则按当前中间栏模式只高亮一个导航目标，
    // 避免 selectedFile + selectedDir 同时亮起（未按 Ctrl 却像多选）。
    final bool selected;
    if (treeMulti.isNotEmpty) {
      selected = inTreeMulti;
    } else {
      final mode = ref.watch(contentModeProvider);
      if (mode == 'editor') {
        selected = isFile && fileSelected;
      } else if (mode == 'assets') {
        selected = !isFile && dirSelected;
      } else {
        selected = fileSelected || dirSelected;
      }
    }
    final multiDrag = treeMulti.length > 1 && inTreeMulti ? treeMulti : null;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 8.0 + level * 12.0, right: 2),
          child: FsContextMenuTarget(
            path: node.path,
            isDir: !isFile,
            displayName: node.name,
            onOpen: () async {
              if (isFile) {
                _openFile(node.path);
              } else {
                ref.read(selectedDirProvider.notifier).state = node.path;
                ref.read(contentModeProvider.notifier).state = 'assets';
              }
            },
            onChanged: () {
              ref.read(treeSelectionProvider.notifier).state = [];
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
                widget.onTreeChanged(
                  isFile ? Directory(node.path).parent.path : node.path,
                );
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.15)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  border: selected
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
                        onTap: () => _onNodeTap(isFile: isFile),
                        onDoubleTap: isFile
                            ? null
                            : () {
                                // 双击名称：展开/折叠（与箭头一致）
                                _toggleExpand();
                              },
                        onSecondaryTapDown: (d) =>
                            _menuPos = d.globalPosition,
                        onSecondaryTap: () => _showMenu(context),
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
                                child: Text(
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
                              _progressBubble(node),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (canExpand)
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
            node.name.endsWith('.jpeg')) return Icons.image_outlined;
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
            node.name.endsWith('.jpeg')) return Colors.purple;
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
