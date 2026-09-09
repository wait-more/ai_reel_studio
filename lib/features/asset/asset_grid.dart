import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/file_actions.dart';
import '../../core/fs_context_menu.dart';
import '../../core/fs_drag.dart';
import '../../core/media_types.dart';
import '../../core/progress.dart';
import '../../core/providers.dart';
import '../media/media_preview.dart';

/// 物料类型过滤器。
enum _AssetFilter {
  all,
  folders,
  images,
  videos,
  audios,
  docs,
}

/// 物料网格：以卡片方式展示某个目录下的物料（图片/视频/音频/文件）。
/// 带导航栏（上一级/后退/前进 + 面包屑）、搜索与类型过滤、文件操作。
/// 导入与分类汇总。点击 .md 在软件内开启编辑器，点击图片软件内预览。
class AssetGridView extends ConsumerStatefulWidget {
  const AssetGridView({super.key});

  @override
  ConsumerState<AssetGridView> createState() => _AssetGridViewState();
}

class _AssetGridViewState extends ConsumerState<AssetGridView> {
  final List<String> _history = []; // 已访问目录栈（含当前）
  int _historyIndex = -1;
  List<FileSystemEntity> _entries = [];
  bool _loading = false;
  bool _initialized = false;
  bool _suppressExternal = false; // 消耗由内部导航引发的 selectedDirProvider 变化
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  _AssetFilter _filter = _AssetFilter.all;

  /// 当前多选路径。
  final Set<String> _selected = {};
  final Map<String, GlobalKey> _itemKeys = {};
  final GlobalKey _gridStackKey = GlobalKey();

  Offset? _marqueeOrigin;
  Offset? _marqueeCurrent;
  bool _marqueeActive = false;
  bool _pointerOnItem = false;
  bool _marqueeAdditive = false;
  Set<String> _marqueeBase = {};

  String? get _currentDir =>
      (_historyIndex >= 0 && _historyIndex < _history.length)
          ? _history[_historyIndex]
          : null;

  
/// 过滤后的条目（先类型后关键字，且保留排序）。
  List<FileSystemEntity> get _visibleEntries {
    final entries = _entries.where((e) {
      final dir = e is Directory;
      final lower = e.path.split(Platform.pathSeparator).last.toLowerCase();
      final kind = classifyMedia(lower);
      switch (_filter) {
        case _AssetFilter.all:
          break;
        case _AssetFilter.folders:
          if (!dir) return false;
          break;
        case _AssetFilter.images:
          if (dir || kind != MediaKind.image) return false;
          break;
        case _AssetFilter.videos:
          if (dir || kind != MediaKind.video) return false;
          break;
        case _AssetFilter.audios:
          if (dir || kind != MediaKind.audio) return false;
          break;
        case _AssetFilter.docs:
          if (dir ||
              !(lower.endsWith('.md') ||
                  lower.endsWith('.txt') ||
                  lower.endsWith('.pdf'))) {
            return false;
          }
          break;
      }
      if (_query.isNotEmpty && !lower.contains(_query.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
    return entries;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final dir = ref.read(selectedDirProvider);
    if (dir != null) {
      _initTo(dir);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 外部(左树)指定新目录时，重置导航历史并跳到该目录。
    ref.listen(selectedDirProvider, (prev, next) {
      if (next == null) return;
      if (_suppressExternal) {
        _suppressExternal = false;
        return;
      }
      if (next != _currentDir) {
        _initTo(next);
      }
    });
    // 左侧树发生结构变更（新增/删除/重命名等）时，同步重载当前目录。
    ref.listen(treeRefreshTickProvider, (prev, next) {
      if (next != prev && _initialized) _reload();
    });

    final dir = _currentDir;
    if (dir == null) {
      return const Center(child: Text('选择左侧目录以查看物料'));
    }

    return Column(
      children: [
        _buildToolbar(context, dir),
        const Divider(height: 1, color: Colors.white12),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  void _initTo(String dir) {
    _history.clear();
    _history.add(dir);
    _historyIndex = 0;
    _selected.clear();
    _reload();
  }

  Future<void> _reload() async {
    final dirPath = _currentDir;
    if (dirPath == null) return;

    setState(() => _loading = true);
    try {
      final entries = <FileSystemEntity>[];
      if (await Directory(dirPath).exists()) {
        await for (final e in Directory(dirPath).list()) {
          entries.add(e);
        }
      }
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path
            .split(Platform.pathSeparator)
            .last
            .compareTo(b.path.split(Platform.pathSeparator).last);
      });
      if (mounted) {
        final keep = entries.map((e) => e.path).toSet();
        _selected.removeWhere((p) => !keep.contains(p));
        _itemKeys.removeWhere((k, _) => !keep.contains(k));
        setState(() => _entries = entries);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  
/// 网格数据发生结构变更后：重载网格 + 通知左侧树重建，保持两边同步。
  void _reloadAndSyncTree() {
    _reload();
    if (mounted) {
      ref.read(treeRefreshTickProvider.notifier).state++;
    }
  }

  
  /// 导航到 [path]：截断当前位置之后的分支，压入并更新全局以同步左树。
  void _enterDir(String path) {
    setState(() {
      _history.removeRange(_historyIndex + 1, _history.length);
      _history.add(path);
      _historyIndex = _history.length - 1;
      _selected.clear();
    });
    _syncGlobal(path);
    _reload();
  }

  
/// 内部导航引发的变化，要同步到全局 selectedDirProvider 供左树定位，
  
/// 但需抑制 ref.listen 对本地的重复重置。
  void _syncGlobal(String path) {
    _suppressExternal = true;
    ref.read(selectedDirProvider.notifier).state = path;
  }

  bool get _canBack => _historyIndex > 0;
  bool get _canForward =>
      _historyIndex >= 0 && _historyIndex < _history.length - 1;

  void _back() {
    if (!_canBack) return;
    setState(() {
      _historyIndex--;
      _selected.clear();
    });
    _syncGlobal(_currentDir!);
    _reload();
  }

  void _forward() {
    if (!_canForward) return;
    setState(() {
      _historyIndex++;
      _selected.clear();
    });
    _syncGlobal(_currentDir!);
    _reload();
  }

  bool get _ctrlHeld =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  List<FsClipboardItem> _selectedItems() => [
        for (final e in _entries)
          if (_selected.contains(e.path))
            FsClipboardItem(path: e.path, isDir: e is Directory),
      ];

  void _selectPath(String path, {required bool toggle}) {
    setState(() {
      if (toggle) {
        if (!_selected.remove(path)) _selected.add(path);
      } else {
        _selected
          ..clear()
          ..add(path);
      }
    });
  }

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() => _selected.clear());
  }

  String? _hitTestItem(Offset global) {
    for (final e in _visibleEntries) {
      final box =
          _itemKeys[e.path]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return e.path;
    }
    return null;
  }

  Rect? get _marqueeRect {
    final a = _marqueeOrigin;
    final b = _marqueeCurrent;
    if (!_marqueeActive || a == null || b == null) return null;
    return Rect.fromPoints(a, b);
  }

  void _applyMarqueeSelection() {
    final rect = _marqueeRect;
    final stackBox =
        _gridStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (rect == null || stackBox == null) return;
    final next = <String>{..._marqueeBase};
    for (final e in _visibleEntries) {
      final box =
          _itemKeys[e.path]?.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || !box.attached) continue;
      final topLeft = stackBox.globalToLocal(box.localToGlobal(Offset.zero));
      if ((topLeft & box.size).overlaps(rect)) {
        next.add(e.path);
      }
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(next);
    });
  }

  void _onGridPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton) return;
    final box =
        _gridStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(e.position);
    _marqueeOrigin = local;
    _marqueeCurrent = local;
    _marqueeActive = false;
    _marqueeAdditive = _ctrlHeld;
    _marqueeBase = _marqueeAdditive ? {..._selected} : {};
    _pointerOnItem = _hitTestItem(e.position) != null;
  }

  void _onGridPointerMove(PointerMoveEvent e) {
    if (_marqueeOrigin == null) return;
    if ((e.buttons & kPrimaryMouseButton) == 0) return;
    final box =
        _gridStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final local = box.globalToLocal(e.position);
    if (!_marqueeActive) {
      if ((local - _marqueeOrigin!).distance <= 6) return;
      // 从卡片上拖出交给文件拖拽，不启动框选。
      if (_pointerOnItem) {
        _marqueeOrigin = null;
        return;
      }
      _marqueeActive = true;
      if (!_marqueeAdditive) {
        _selected.clear();
        _marqueeBase = {};
      }
    }
    _marqueeCurrent = local;
    _applyMarqueeSelection();
  }

  void _onGridPointerUp(PointerUpEvent e) {
    if (_marqueeActive) {
      _marqueeActive = false;
      _marqueeOrigin = null;
      _marqueeCurrent = null;
      if (mounted) setState(() {});
      return;
    }
    final wasEmptyClick = !_pointerOnItem && _marqueeOrigin != null;
    _marqueeOrigin = null;
    _marqueeCurrent = null;
    if (wasEmptyClick && !_marqueeAdditive) {
      _clearSelection();
    }
  }

  void _onGridPointerCancel(PointerCancelEvent e) {
    _marqueeActive = false;
    _marqueeOrigin = null;
    _marqueeCurrent = null;
    if (mounted) setState(() {});
  }

  void _up() {
    final dir = _currentDir!;
    final parent = Directory(dir).parent.path;
    if (parent == dir) return; // 已在当前目录
    if (_historyIndex > 0 && _history[_historyIndex - 1] == parent) {
      _back();
    } else {
      _enterDir(parent);
    }
  }

  Widget _buildToolbar(BuildContext context, String currentDir) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 40,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  onPressed: _canBack ? _back : null,
                  tooltip: '后退',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  onPressed: _canForward ? _forward : null,
                  tooltip: '前进',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  onPressed: _up,
                  tooltip: '上一级',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                PopupMenuButton<String>(
                  initialValue: currentDir,
                  itemBuilder: (_) {
                    final crumbs = _breadcrumbs(currentDir);
                    return [
                      for (final c in crumbs)
                        PopupMenuItem<String>(
                          value: c.path,
                          child: Text(c.label),
                        ),
                    ];
                  },
                  onSelected: (p) => _enterDir(p),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.folder,
                            size: 16, color: Colors.orange),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            _displayPath(currentDir),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down, size: 16),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                _buildFilterChips(),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.note_add_outlined, size: 18),
                  onPressed: () => _newDocument(currentDir),
                  tooltip: '新建文档',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  onPressed: () => _newFolder(currentDir),
                  tooltip: '新建文件夹',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  onPressed: () => _importFiles(currentDir),
                  tooltip: '导入物料',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.category_outlined, size: 18),
                  onPressed: () => _showSummary(currentDir),
                  tooltip: '分类汇总',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: _reload,
                  tooltip: '刷新',
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: SizedBox(
              height: 32,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _query = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索当前目录',
                  hintStyle: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 16),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor:
                      Theme.of(context).colorScheme.surfaceContainerLowest,
                  contentPadding: const EdgeInsets.symmetric(vertical: 6),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  
/// 类型过滤 chips（紧凑，文字 + 图标）。
  Widget _buildFilterChips() {
    Widget chip(_AssetFilter f, IconData icon, String label) {
      final sel = _filter == f;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: () => setState(() => _filter = f),
          borderRadius: BorderRadius.circular(6),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: sel
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 13,
                    color: sel
                        ? Theme.of(context).colorScheme.onPrimaryContainer
                        : Colors.grey[400]),
                const SizedBox(width: 3),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: sel
                            ? Theme.of(context)
                                .colorScheme
                                .onPrimaryContainer
                            : Colors.grey[400])),
              ],
            ),
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip(_AssetFilter.all, Icons.apps, '全部'),
        chip(_AssetFilter.folders, Icons.folder, '目录'),
        chip(_AssetFilter.images, Icons.image, '图片'),
        chip(_AssetFilter.videos, Icons.videocam, '视频'),
        chip(_AssetFilter.audios, Icons.audiotrack, '音频'),
        chip(_AssetFilter.docs, Icons.description, '文档'),
      ],
    );
  }

  
/// 新建文档：输入文件名，创建于 [dir] 下并打开编辑器。
  Future<void> _newDocument(String dir) async {
    final created = await newDocumentDialog(context, parentDir: dir);
    if (created == null) return;
    _reloadAndSyncTree();
    ref.read(selectedFileProvider.notifier).state = created;
    final tabs = ref.read(openTabsProvider);
    if (!tabs.contains(created)) {
      ref.read(openTabsProvider.notifier).state = [...tabs, created];
    }
    ref.read(contentModeProvider.notifier).state = 'editor';
  }

  /// 新建文件夹：输入名称，创建于 [dir] 下。
  Future<void> _newFolder(String dir) async {
    final created = await newFolderDialog(context, parentDir: dir);
    if (created != null) _reloadAndSyncTree();
  }

  /// 导入物料：系统文件选择器多选，复制到 [dir]。
  Future<void> _importFiles(String dir) async {
    await importFilesToDir(
      context,
      dir: dir,
      onDone: _reloadAndSyncTree,
    );
  }

  
/// 分类汇总：扫描当前目录，按子目录分组展示各类物料数量，点击跳入。
  Future<void> _showSummary(String dir) async {
    final subDirs = <String>[]; // 子目录路径
    var fileCount = 0;
    var imageCount = 0;
    try {
      await for (final e in Directory(dir).list()) {
        if (e is Directory) {
          subDirs.add(e.path);
        } else {
          final lower = e.path.toLowerCase();
          if (classifyMedia(lower) != MediaKind.other) {
            imageCount++;
          } else {
            fileCount++;
          }
        }
      }
    } catch (_) {}

    // 汇总数据：子目录（含条目计数） + 直属文件统计
    final dirInfos = <({String path, String name, int count})>[];
    for (final d in subDirs) {
      var n = 0;
      try {
        await for (final _ in Directory(d).list()) {
          n++;
        }
      } catch (_) {}
      dirInfos.add((
        path: d,
        name: d.split(Platform.pathSeparator).last,
        count: n,
      ));
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.category_outlined, size: 18, color: Colors.teal),
          const SizedBox(width: 8),
          Text('分类汇总：${_displayPath(dir)}',
              style: const TextStyle(fontSize: 15)),
        ]),
        content: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 360, maxHeight: 520),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (dirInfos.isEmpty && imageCount == 0 && fileCount == 0)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text('此目录为空',
                          style: TextStyle(color: Colors.grey[500])),
                    ),
                  ),
                for (final info in dirInfos)
                  ListTile(
                    dense: true,
                    leading:
                        const Icon(Icons.folder, color: Colors.orange, size: 20),
                    title: Text(info.name,
                        style: const TextStyle(fontSize: 13)),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blueGrey.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${info.count} 项',
                          style: const TextStyle(fontSize: 11)),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _enterDir(info.path);
                    },
                  ),
                if (imageCount > 0 || fileCount > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(children: [
                      const Icon(Icons.insert_drive_file,
                          size: 16, color: Colors.grey),
                      const SizedBox(width: 8),
                      Text(
                        '直属素材：$imageCount 个媒体 · $fileCount 个文件',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ]),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  
/// 生成面包屑层级（含各级名称与路径）。
  List<({String label, String path})> _breadcrumbs(String dir) {
    final sep = Platform.pathSeparator;
    final result = <({String label, String path})>[];
    String current = dir;
    while (true) {
      final name = current.split(sep).last;
      result.insert(0, (label: name.isEmpty ? current : name, path: current));
      final parent = Directory(current).parent.path;
      if (parent == current) break;
      current = parent;
    }
    return result;
  }

  String _displayPath(String dir) {
    final name = dir.split(Platform.pathSeparator).last;
    if (name.isEmpty) return dir;
    // 显示最后两级，避免过长
    final parent = dir.split(Platform.pathSeparator);
    final label = parent.length >= 2
        ? '${parent[parent.length - 2]}/$name'
        : name;
    return label;
  }

  Widget _buildBody(BuildContext context) {
    final dir = _currentDir;
    Widget body;
    if (_loading && _entries.isEmpty) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_visibleEntries.isEmpty) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.folder_open, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            Text(
              _entries.isEmpty ? '此目录为空' : '无匹配内容',
              style: TextStyle(color: Colors.grey[500]),
            ),
            if (_entries.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '可从资源管理器拖入文件，或在应用内拖拽整理',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
              ),
          ],
        ),
      );
    } else {
      final entries = _visibleEntries;
      final primary = Theme.of(context).colorScheme.primary;
      body = Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onGridPointerDown,
        onPointerMove: _onGridPointerMove,
        onPointerUp: _onGridPointerUp,
        onPointerCancel: _onGridPointerCancel,
        child: Stack(
          key: _gridStackKey,
          children: [
            GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 160,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.9,
              ),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entity = entries[index];
                final itemKey =
                    _itemKeys.putIfAbsent(entity.path, GlobalKey.new);
                return KeyedSubtree(
                  key: itemKey,
                  child: _AssetCard(
                    entity: entity,
                    selected: _selected.contains(entity.path),
                    selectedItems: _selectedItems(),
                    onSelect: (toggle) =>
                        _selectPath(entity.path, toggle: toggle),
                    onEnterDir: _enterDir,
                    onOpenFile: _openFileEntry,
                    onChanged: () {
                      _clearSelection();
                      _reloadAndSyncTree();
                    },
                  ),
                );
              },
            ),
            if (_marqueeRect != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _MarqueePainter(
                      rect: _marqueeRect!,
                      color: primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    if (dir == null || dir.isEmpty) return body;
    return FsDirDropTarget(
      destDir: dir,
      onChanged: () {
        _clearSelection();
        _reloadAndSyncTree();
      },
      child: body,
    );
  }

  
/// 软件内打开文件：.md 用编辑器，图片弹预览，其余走系统默认程序。
  void _openFileEntry(String path) {
    switch (classifyMedia(path)) {
      case MediaKind.markdown:
        // 软件内用 Markdown 编辑器打开（文档 Tab 并存，素材视图保留）
        ref.read(selectedFileProvider.notifier).state = path;
        final tabs = ref.read(openTabsProvider);
        if (!tabs.contains(path)) {
          ref.read(openTabsProvider.notifier).state = [...tabs, path];
        }
        ref.read(contentModeProvider.notifier).state = 'editor';
        return;
      case MediaKind.image:
        showImageViewerDialog(context, path);
        return;
      case MediaKind.video:
        // 软件内嵌播放器预览（音画同步、进度控制、首末帧提取与截帧）
        showMediaPreviewDialog(
          context,
          path: path,
          isVideo: true,
          onChanged: _reloadAndSyncTree,
        );
        return;
      case MediaKind.audio:
        showMediaPreviewDialog(
          context,
          path: path,
          isVideo: false,
          onChanged: _reloadAndSyncTree,
        );
        return;
      case MediaKind.other:
        _openWithSystem(path);
    }
  }
}

/// 单个物料卡片。
// ignore: must_be_immutable
class _AssetCard extends ConsumerWidget {
  final FileSystemEntity entity;
  final bool selected;
  final List<FsClipboardItem> selectedItems;
  final void Function(bool toggle) onSelect;
  final ValueChanged<String> onEnterDir;
  final ValueChanged<String> onOpenFile;
  final VoidCallback onChanged;
  Offset _menuPos = Offset.zero;

  _AssetCard({
    required this.entity,
    required this.selected,
    required this.selectedItems,
    required this.onSelect,
    required this.onEnterDir,
    required this.onOpenFile,
    required this.onChanged,
  });

  bool get _isDir => entity is Directory;
  String get _name => entity.path.split(Platform.pathSeparator).last;
  bool get _multiSelected => selected && selectedItems.length > 1;

  bool get _ctrlHeld =>
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _open() {
    if (_isDir) {
      onEnterDir(entity.path);
    } else {
      onOpenFile(entity.path);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return FsContextMenuTarget(
      path: entity.path,
      isDir: _isDir,
      displayName: _name,
      onOpen: () async => _open(),
      onChanged: onChanged,
      child: FsDragDropShell(
        path: entity.path,
        isDir: _isDir,
        displayName: _name,
        dropIntoDir: _isDir ? entity.path : null,
        dragItems: _multiSelected ? selectedItems : null,
        onChanged: onChanged,
        child: InkWell(
          onTapDown: (_) {
            if (!_ctrlHeld && !selected) {
              onSelect(false);
            }
          },
          onTap: () {
            if (_ctrlHeld) {
              onSelect(true);
            } else {
              onSelect(false);
            }
          },
          onDoubleTap: _open,
          onSecondaryTapDown: (d) => _menuPos = d.globalPosition,
          onSecondaryTap: () => _showMenu(context, ref),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.16)
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? scheme.primary : Colors.white10,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _preview(context)),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  decoration: const BoxDecoration(
                    color: Colors.black26,
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(8)),
                  ),
                  child: Row(
                    children: [
                      if (_isDir) _statusBubble(ref),
                      Expanded(
                        child: Text(
                          _name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 目录进度状态徽章（未开始时隐藏）。
  Widget _statusBubble(WidgetRef ref) {
    final status = ref.watch(episodeStatusesProvider)[entity.path];
    if (status == null || status == EpisodeStatus.notStarted) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: Color(EpisodeStatus.colors[status] ?? 0xFF9E9E9E)
              .withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(EpisodeStatus.colors[status] ?? 0xFF9E9E9E),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              EpisodeStatus.labelIcons[status] ?? status,
              style: TextStyle(
                fontSize: 9,
                color: Color(EpisodeStatus.colors[status] ?? 0xFF9E9E9E),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 右键操作菜单（与左树共用 [showFsContextMenu]）。
  Future<void> _showMenu(BuildContext context, WidgetRef ref) async {
    if (!selected) {
      onSelect(false);
    }
    await showFsContextMenu(
      context: context,
      globalPosition: _menuPos,
      path: entity.path,
      isDir: _isDir,
      displayName: _name,
      multiItems: _multiSelected ? selectedItems : null,
      onOpen: () async => _open(),
      onChanged: onChanged,
    );
  }

  Widget _preview(BuildContext context) {
    final lower = _name.toLowerCase();
    if (_isDir) {
      return Container(
        alignment: Alignment.center,
        child: Icon(Icons.folder, color: Colors.orange[400], size: 44),
      );
    }
    if (classifyMedia(_name) == MediaKind.image) {
      return Image.file(
        File(entity.path),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            _fallbackIcon(context, Icons.broken_image_outlined),
      );
    }
    final icon = _iconFor(lower);
    return Container(
      alignment: Alignment.center,
      child: Icon(icon.$1, color: icon.$2, size: 44),
    );
  }

  Widget _fallbackIcon(BuildContext context, IconData icon) {
    return Container(
      alignment: Alignment.center,
      child: Icon(icon,
          color: Theme.of(context).colorScheme.onSurfaceVariant, size: 44),
    );
  }

  (IconData, Color) _iconFor(String lower) {
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi')) {
      return (Icons.videocam, Colors.redAccent);
    }
    if (lower.endsWith('.wav') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg')) {
      return (Icons.audiotrack, Colors.pinkAccent);
    }
    if (lower.endsWith('.md')) return (Icons.description, Colors.blueGrey);
    return (Icons.insert_drive_file, Colors.grey);
  }
}

class _MarqueePainter extends CustomPainter {
  _MarqueePainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final r = Rect.fromLTRB(
      math.max(0, rect.left),
      math.max(0, rect.top),
      math.min(size.width, rect.right),
      math.min(size.height, rect.bottom),
    );
    canvas.drawRect(r, fill);
    canvas.drawRect(r, stroke);
  }

  @override
  bool shouldRepaint(covariant _MarqueePainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}

/// 用系统默认应用打开文件（Windows 下 rundll32/默认关联，避免触发选择器）。
void _openWithSystem(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('rundll32.exe', ['url.dll,FileProtocolHandler', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  } catch (_) {
    // 忽略打开失败
  }
}