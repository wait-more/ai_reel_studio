import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/config.dart';
import '../../core/media_types.dart';
import '../../core/providers.dart';
import '../../core/search_utils.dart';
import '../media/media_preview.dart';

/// 打开全局搜索对话框（顶栏按钮 / Ctrl+P 触发）。
Future<void> showGlobalSearch(BuildContext context) {
  if (!AppConfig.instance.isConfigured) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (_) => const Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 80, vertical: 60),
      child: _GlobalSearchDialog(),
    ),
  );
}

class _SearchEntry {
  final String path;
  final String name;
  String? snippet; // Markdown 内容命中片段
  bool matchedByContent = false;
  _SearchEntry(this.path, this.name);
}

class _GlobalSearchDialog extends ConsumerStatefulWidget {
  const _GlobalSearchDialog();

  @override
  ConsumerState<_GlobalSearchDialog> createState() =>
      _GlobalSearchDialogState();
}

class _GlobalSearchDialogState extends ConsumerState<_GlobalSearchDialog> {
  final _queryController = TextEditingController();
  final _focusNode = FocusNode();
  final _listController = ScrollController();
  final List<_SearchEntry> _fileIndex = [];
  final List<_SearchEntry> _results = [];
  final Map<String, _MdCache> _mdCache = {}; // path -> 内容缓存（按需构建）
  bool _indexing = true;
  bool _searching = false;
  Timer? _debounce;
  int _version = 0;
  int _selectedIndex = -1;

  static const double _itemExtent = 64;

  @override
  void initState() {
    super.initState();
    _buildFileIndex();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _queryController.dispose();
    _focusNode.dispose();
    _listController.dispose();
    super.dispose();
  }

  int get _shownCount => math.min(_results.length, 200);

  void _setSelected(int index, {bool scroll = true}) {
    if (_shownCount == 0) {
      if (_selectedIndex != -1) setState(() => _selectedIndex = -1);
      return;
    }
    final next = index.clamp(0, _shownCount - 1);
    if (next == _selectedIndex) {
      if (scroll) _scrollToSelected();
      return;
    }
    setState(() => _selectedIndex = next);
    if (scroll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToSelected();
      });
    }
  }

  void _scrollToSelected() {
    if (!_listController.hasClients || _selectedIndex < 0) return;
    final target = _selectedIndex * _itemExtent;
    final view = _listController.position.viewportDimension;
    final offset = _listController.offset;
    if (target < offset) {
      _listController.jumpTo(target);
    } else if (target + _itemExtent > offset + view) {
      _listController.jumpTo(target + _itemExtent - view);
    }
  }

  void _selectNext() {
    if (_shownCount == 0) return;
    _setSelected(_selectedIndex < 0 ? 0 : _selectedIndex + 1);
  }

  void _selectPrevious() {
    if (_shownCount == 0) return;
    _setSelected(_selectedIndex < 0 ? 0 : _selectedIndex - 1);
  }

  void _activateSelected() {
    if (_selectedIndex >= 0 && _selectedIndex < _shownCount) {
      _open(_results[_selectedIndex].path);
    }
  }

  /// 一次性构建项目全文件索引（只记录路径，不读内容）。
  Future<void> _buildFileIndex() async {
    final root = AppConfig.instance.projectRoot;
    final sep = Platform.pathSeparator;
    try {
      await for (final e in Directory(root)
          .list(recursive: true, followLinks: false)) {
        final name = e.path.split(sep).last;
        if (name.startsWith('.')) continue; // 隐藏文件（系统/缓存）跳过
        if (name.contains('.git')) continue;
        _fileIndex.add(_SearchEntry(e.path, name));
      }
    } catch (_) {
      // 树根目录不可达时保持空索引
    }
    if (!mounted) return;
    setState(() => _indexing = false);
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      _runSearch(q.trim());
    });
  }

  Future<void> _runSearch(String q) async {
    final version = ++_version;
    if (q.isEmpty) {
      if (mounted) {
        setState(() {
          _results.clear();
          _searching = false;
          _selectedIndex = -1;
        });
      }
      return;
    }
    final ql = q.toLowerCase();

    // 1. 文件名过滤（内存，即时）
    final nameHits = <_SearchEntry>[];
    for (final e in _fileIndex) {
      if (e.name.toLowerCase().contains(ql)) {
        e.snippet = null;
        e.matchedByContent = false;
        nameHits.add(e);
      }
    }
    if (mounted) {
      setState(() {
        _results
          ..clear()
          ..addAll(nameHits);
        _searching = true;
        _selectedIndex = nameHits.isEmpty ? -1 : 0;
      });
    }

    // 2. Markdown 内容流式匹配（IO 异步，逐条让出事件循环）
    for (final e in _fileIndex) {
      if (version != _version) return; // 输入已变，丢弃过期结果
      if (e.matchedByContent || nameHits.contains(e)) continue;
      if (classifyMedia(e.path) != MediaKind.markdown) continue;
      final snippet = await _findInContent(e.path, ql);
      if (!mounted || version != _version) return;
      if (snippet != null) {
        e.snippet = snippet;
        e.matchedByContent = true;
        setState(() {
          _results.add(e);
          if (_selectedIndex < 0) _selectedIndex = 0;
        });
      }
    }
    if (mounted && version == _version) {
      setState(() => _searching = false);
    }
  }

  /// 读取并缓存 .md 内容（按 mtime 失效），返回首个命中 query 的上下文片段。
  Future<String?> _findInContent(String path, String ql) async {
    final file = File(path);
    try {
      final stat = await file.stat();
      final cached = _mdCache[path];
      if (cached != null && cached.mtime == stat.modified) {
        return mdSnippet(cached.text, ql);
      }
      if (_mdCache.length > 300) _mdCache.remove(_mdCache.keys.first);
      final text = await file.readAsString(); // UTF-8 按平台默认；md 均 UTF-8
      _mdCache[path] = _MdCache(stat.modified, text);
      return mdSnippet(text, ql);
    } catch (_) {
      return null;
    }
  }

  void _open(String path) {
    final navigator = Navigator.of(context);
    navigator.pop();
    // 等搜索框关动画结束后再打开目标（仍在 mounted 内则有效）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
    });
  }

  @override
  Widget build(BuildContext context) {
    // Shortcuts 包在 TextField 外层，覆盖默认上下键光标行为，用于结果列表导航。
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): _SelectNextIntent(),
        SingleActivator(LogicalKeyboardKey.arrowUp): _SelectPreviousIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SelectNextIntent: CallbackAction<_SelectNextIntent>(
            onInvoke: (_) {
              _selectNext();
              return null;
            },
          ),
          _SelectPreviousIntent: CallbackAction<_SelectPreviousIntent>(
            onInvoke: (_) {
              _selectPrevious();
              return null;
            },
          ),
        },
        child: Container(
          width: 640,
          constraints: const BoxConstraints(maxHeight: 520),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: TextField(
                  controller: _queryController,
                  focusNode: _focusNode,
                  autofocus: true,
                  onChanged: _onQueryChanged,
                  onSubmitted: (_) => _activateSelected(),
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '搜索整个 scripts 库（文件名 / Markdown 内容）...',
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                  ),
                ),
              ),
              const Divider(height: 1),
              SizedBox(
                height: 300,
                child: _buildResults(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResults(BuildContext context) {
    if (_indexing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(height: 10),
            Text('正在索引项目目录...', style: TextStyle(fontSize: 12)),
          ],
        ),
      );
    }
    if (_queryController.text.trim().isEmpty) {
      return const Center(
        child: Text('输入关键词，搜索整个项目', style: TextStyle(fontSize: 12)),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('无匹配结果', style: TextStyle(fontSize: 12)));
    }
    final shown = _results.take(200).toList();
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _listController,
      itemCount: shown.length,
      itemExtent: _itemExtent,
      itemBuilder: (context, i) {
        final e = shown[i];
        final kind = classifyMedia(e.path);
        final selected = i == _selectedIndex;
        return Material(
          color: selected ? scheme.primary.withValues(alpha: 0.22) : Colors.transparent,
          child: InkWell(
            onTap: () => _open(e.path),
            onHover: (hovering) {
              if (hovering) _setSelected(i, scroll: false);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    _kindIcon(kind),
                    size: 16,
                    color: selected ? scheme.primary : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          e.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.normal,
                            color: selected ? scheme.onSurface : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (e.matchedByContent && e.snippet != null)
                          Text(
                            e.snippet!,
                            style: TextStyle(
                              fontSize: 11,
                              color: selected
                                  ? scheme.primary
                                  : Colors.orangeAccent,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: _qualifiedPath(e, emphasize: selected),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _qualifiedPath(_SearchEntry e, {bool emphasize = false}) {
    final root = AppConfig.instance.projectRoot;
    var rel = e.path;
    if (root.isNotEmpty && e.path.startsWith(root)) {
      rel = e.path.substring(root.length);
    }
    final scheme = Theme.of(context).colorScheme;
    return Text(
      rel,
      style: TextStyle(
        fontSize: 10,
        color: emphasize ? scheme.primary : scheme.onSurfaceVariant,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
    );
  }

  IconData _kindIcon(MediaKind kind) {
    switch (kind) {
      case MediaKind.markdown:
        return Icons.description_outlined;
      case MediaKind.image:
        return Icons.image_outlined;
      case MediaKind.video:
        return Icons.movie_outlined;
      case MediaKind.audio:
        return Icons.audio_file_outlined;
      case MediaKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }
}

class _MdCache {
  final DateTime mtime;
  final String text;
  _MdCache(this.mtime, this.text);
}

class _SelectNextIntent extends Intent {
  const _SelectNextIntent();
}

class _SelectPreviousIntent extends Intent {
  const _SelectPreviousIntent();
}