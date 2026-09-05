import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../core/directory_parser.dart';
import '../../core/directory_watcher.dart';
import '../../core/file_actions.dart';
import '../../core/media_types.dart';
import '../../core/progress.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../media/media_preview.dart';

class ProjectTree extends ConsumerStatefulWidget {
  const ProjectTree({super.key});

  @override
  ConsumerState<ProjectTree> createState() => _ProjectTreeState();
}

class _ProjectTreeState extends ConsumerState<ProjectTree> {
  final _searchController = TextEditingController();
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
    super.dispose();
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

    return Container(
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
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
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
                            width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(height: 12),
                        Text('正在加载项目目录...'),
                      ],
                    ),
                  )
                : _buildTree(context, root),
          ),
        ],
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

  const _TreeNodeWidget({
    required this.node,
    required this.level,
    required this.onTreeChanged,
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

  
/// 通过右键菜单提取帧（首帧/末帧）并给出可见反馈。
  Future<void> _extractFrameAndNotify(String tag,
      {required bool lastFrame}) async {
    final mediaPath = widget.node.path;
    final result = await extractMediaFrame(
      path: mediaPath,
      tag: tag,
      lastFrame: lastFrame,
    );
    if (!context.mounted) return;
    showGlobalToast(context, result != null
        ? '已保存：$result'
        : '截帧失败：未取得帧数据');
    if (result != null) {
      // 新帧文件已生成，通知父级刷新该目录。
      widget.onTreeChanged(Directory(mediaPath).parent.path);
    }
  }

  /// 右键操作菜单：打开 / 在资源管理器显示 /（视频）截取首尾帧。
  /// （目录）新建子文件夹、设置进度 / 重命名 /（文件）复制 / 删除。
  /// 功能区之间以细分隔线划分。
  Future<void> _showMenu(BuildContext context) async {
    final node = widget.node;
    final isFile = node.type == ScriptNodeType.file;
    final isVideo =
        isFile && classifyMedia(node.path) == MediaKind.video;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final origin = overlay.globalToLocal(_menuPos);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        origin & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        // 查看
        PopupMenuItem(height: 32,
          value: 'open',
          child: Row(children: [
            const Icon(Icons.open_in_new, size: 16),
            const SizedBox(width: 8),
            Text(isFile ? '打开' : '在当前目录查看'),
          ]),
        ),
        PopupMenuItem(height: 32,
          value: 'reveal',
          child: Row(children: [
            const Icon(Icons.folder_open, size: 16),
            const SizedBox(width: 8),
            const Text('在资源管理器显示'),
          ]),
        ),
        // 媒体操作（仅视频）
        if (isVideo) ...[
          const PopupMenuDivider(height: 4),
          PopupMenuItem(height: 32,
            value: 'grabFirst',
            child: Row(children: [
              const Icon(Icons.first_page, size: 16, color: Colors.tealAccent),
              const SizedBox(width: 8),
              const Text('截取首帧'),
            ]),
          ),
          PopupMenuItem(height: 32,
            value: 'grabLast',
            child: Row(children: [
              const Icon(Icons.last_page, size: 16, color: Colors.tealAccent),
              const SizedBox(width: 8),
              const Text('截取末帧'),
            ]),
          ),
        ],
        // 目录管理（仅目录）
        if (!isFile) ...[
          const PopupMenuDivider(height: 4),
          PopupMenuItem(height: 32,
            value: 'newFolder',
            child: Row(children: [
              const Icon(Icons.create_new_folder_outlined, size: 16),
              const SizedBox(width: 8),
              const Text('新建子文件夹'),
            ]),
          ),
          PopupMenuItem(height: 32,
            value: 'progress',
            child: Row(children: [
              const Icon(Icons.donut_large, size: 16, color: Colors.teal),
              const SizedBox(width: 8),
              const Text('设置创作进度'),
            ]),
          ),
        ],
        // 文件操作
        const PopupMenuDivider(height: 4),
        PopupMenuItem(height: 32,
          value: 'rename',
          child: Row(children: [
            const Icon(Icons.drive_file_rename_outline, size: 16),
            const SizedBox(width: 8),
            const Text('重命名'),
          ]),
        ),
        if (!isFile)
          PopupMenuItem(height: 32,
            value: 'duplicate',
            child: Row(children: [
              const Icon(Icons.copy, size: 16),
              const SizedBox(width: 8),
              const Text('复制'),
            ]),
          ),
        // 危险操作
        const PopupMenuDivider(height: 4),
        PopupMenuItem(height: 32,
          value: 'delete',
          child: Row(children: [
            Icon(Icons.delete_outline, size: 16, color: Colors.red[300]),
            const SizedBox(width: 8),
            Text('删除', style: TextStyle(color: Colors.red[300])),
          ]),
        ),
      ],
    );

    if (action == null) return;
    final dir = Directory(node.path).parent.path;
    switch (action) {
      case 'open':
        if (isFile) {
          _openFile(node.path);
        } else {
          ref.read(selectedDirProvider.notifier).state = node.path;
          ref.read(contentModeProvider.notifier).state = 'assets';
        }
        break;
      case 'grabFirst':
        await _extractFrameAndNotify('首帧', lastFrame: false);
        break;
      case 'grabLast':
        await _extractFrameAndNotify('末帧', lastFrame: true);
        break;
      case 'reveal':
        await revealInExplorer(node.path);
        break;
      case 'newFolder':
        await newFolderDialog(
          context,
          parentDir: node.path,
          onDone: () => widget.onTreeChanged(node.path),
        );
        break;
      case 'progress':
        await setProgressDialog(
          context,
          ref,
          path: node.path,
          displayName: node.name,
        );
        break;
      case 'rename':
        await renameEntityDialog(
          context,
          path: node.path,
          isDir: !isFile,
          onDone: () => widget.onTreeChanged(dir),
        );
        break;
      case 'duplicate':
        await duplicateFileDialog(
          context,
          path: node.path,
          onDone: () => widget.onTreeChanged(dir),
        );
        break;
      case 'delete':
        await deleteEntityDialog(
          context,
          path: node.path,
          isDir: !isFile,
          onDone: () => widget.onTreeChanged(dir),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final level = widget.level;
    final isFile = node.type == ScriptNodeType.file;
    final isExpanded = node.isExpanded;
    // 目录总是可尝试展开：未加载（懒加载壳）或已加载且有子项
    final canExpand = !isFile && (!node.isLoaded || node.children.isNotEmpty);
    final selected = ref.watch(selectedFileProvider) == node.path;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () async {
            if (isFile) {
              _openFile(node.path);
            } else {
              // 目录：激活物料网格并定位到该目录（编辑器文档保留）
              ref.read(selectedDirProvider.notifier).state = node.path;
              ref.read(contentModeProvider.notifier).state = 'assets';
              if (canExpand) {
                node.isExpanded = !isExpanded;
                setState(() {});
                // 懒加载壳：展开时按需拉取真实子节点
                if (!node.isLoaded) {
                  await DirectoryParser.loadChildrenAsync(node);
                  if (!mounted) return;
                  setState(() {});
                }
                _syncExpandedPathsToProvider();
              }
            }
          },
          onSecondaryTapDown: (d) => _menuPos = d.globalPosition,
          onSecondaryTap: () => _showMenu(context),
          child: Container(
            padding: EdgeInsets.only(
              left: 8.0 + level * 12.0,
              right: 4,
              top: 4,
              bottom: 4,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.primary.withOpacity(0.15)
                  : null,
              borderRadius: BorderRadius.circular(4),
            ),
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
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
                _progressBubble(node),
                if (canExpand) ...[
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 16,
                  ),
                ],
              ],
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
