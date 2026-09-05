import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import 'markdown_highlight_controller.dart';

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
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (context, index) {
          final path = tabs[index];
          final isSelected = path == selected;
          return InkWell(
            onTap: () => ref.read(selectedFileProvider.notifier).state = path,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white12 : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
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
  bool _isDir = false;
  bool _loading = true;
  bool _isDirty = false;
  bool _showPreview = false;
  List<FileSystemEntity> _dirEntries = [];

  @override
  void initState() {
    super.initState();
    // 延后到首帧构建完成后注册，避免在 build 期间修改 provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registerSave();
    });
    _load();
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
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _content = '';
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法读取文件: $e')),
      );
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
    // 延后到下一帧移除保存注册，避免在 dispose 期间修改 provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unregisterSave();
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
                child: Text(
                  widget.path,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isMarkdown) ...[
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
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: (_showPreview && isMarkdown)
              ? _buildPreview(context)
              : Padding(
                  padding: const EdgeInsets.all(4),
                  child: KeyboardListener(
                    focusNode: _editorFocus,
                    onKeyEvent: (event) {
                      if (event is KeyDownEvent &&
                          HardwareKeyboard.instance.isControlPressed &&
                          event.logicalKey == LogicalKeyboardKey.keyS) {
                        _save();
                      }
                    },
                    child: TextField(
                      controller: _controller,
                      onChanged: (_) {
                        setState(() => _isDirty = true);
                        ref.read(dirtyFilesProvider.notifier).update((s) {
                          if (s.contains(widget.path)) return s;
                          return {...s, widget.path};
                        });
                      },
                      maxLines: null,
                      expands: true,
                      keyboardType: TextInputType.multiline,
                      style: TextStyle(
                        fontSize: ref.watch(editorFontSizeProvider),
                        height: 1.6,
                        fontFamily: 'Consolas',
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.all(8),
                      ),
                    ),
                  ),
                ),
        ),
      ],
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
