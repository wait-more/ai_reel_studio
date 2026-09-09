import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'file_actions.dart';
import 'providers.dart';
import 'toast.dart';

/// 应用内文件拖拽载荷（可含多选）。
class FsDragItem {
  final List<FsClipboardItem> items;

  const FsDragItem({required this.items}) : assert(items.length > 0);

  factory FsDragItem.single({
    required String path,
    required bool isDir,
  }) =>
      FsDragItem(items: [FsClipboardItem(path: path, isDir: isDir)]);

  String get primaryPath => items.first.path;
  bool get primaryIsDir => items.first.isDir;
  String get primaryName => p.basename(items.first.path);
}

bool _wantCopy() =>
    HardwareKeyboard.instance.isControlPressed ||
    HardwareKeyboard.instance.isMetaPressed;

bool _canDropItems(List<FsClipboardItem> items, String destDir, bool asCopy) {
  for (final item in items) {
    if (!canRelocateTo(
      srcPath: item.path,
      isDir: item.isDir,
      destDir: destDir,
      asCopy: asCopy,
    )) {
      return false;
    }
  }
  return true;
}

Future<void> _dropItems({
  required BuildContext context,
  required List<FsClipboardItem> items,
  required String destDir,
  required bool move,
  required VoidCallback onChanged,
}) async {
  var ok = 0;
  for (final item in items) {
    final result = await relocateEntity(
      context,
      ProviderScope.containerOf(context, listen: false),
      srcPath: item.path,
      isDir: item.isDir,
      destDir: destDir,
      move: move,
      onDone: null,
      silent: items.length > 1,
    );
    if (result != null) ok++;
  }
  if (ok > 0) {
    onChanged();
    if (context.mounted) {
      showGlobalToast(
        // ignore: use_build_context_synchronously
        context,
        move
            ? (ok == 1 ? '已移动' : '已移动 $ok 项')
            : (ok == 1 ? '已复制到目标' : '已复制 $ok 项'),
      );
    }
  }
}

/// 可拖出；若 [dropIntoDir] 非空则同时作为应用内放入目标（文件夹）。
class FsDragDropShell extends ConsumerWidget {
  const FsDragDropShell({
    super.key,
    required this.path,
    required this.isDir,
    required this.displayName,
    required this.onChanged,
    required this.child,
    this.dropIntoDir,
    this.dragItems,
  });

  final String path;
  final bool isDir;
  final String displayName;
  final VoidCallback onChanged;
  final Widget child;
  final String? dropIntoDir;

  /// 多选拖拽时传入全部选中项；为空则只拖当前项。
  final List<FsClipboardItem>? dragItems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = (dragItems != null && dragItems!.isNotEmpty)
        ? dragItems!
        : [FsClipboardItem(path: path, isDir: isDir)];
    final item = FsDragItem(items: items);
    final draggable = Draggable<FsDragItem>(
      data: item,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: _FsDragFeedback(item: item),
      childWhenDragging: Opacity(opacity: 0.35, child: child),
      child: child,
    );

    final dest = dropIntoDir;
    if (dest == null) return draggable;

    return DragTarget<FsDragItem>(
      onWillAcceptWithDetails: (details) {
        final asCopy = _wantCopy();
        return _canDropItems(details.data.items, dest, asCopy);
      },
      onAcceptWithDetails: (details) async {
        final asCopy = _wantCopy();
        if (!_canDropItems(details.data.items, dest, asCopy)) return;
        await _dropItems(
          context: context,
          items: details.data.items,
          destDir: dest,
          move: !asCopy,
          onChanged: onChanged,
        );
      },
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: hot
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : null,
            color: hot
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
                : null,
          ),
          child: draggable,
        );
      },
    );
  }
}

/// 当前目录放入目标：应用内拖放 + 资源管理器拖入。
class FsDirDropTarget extends ConsumerWidget {
  const FsDirDropTarget({
    super.key,
    required this.destDir,
    required this.onChanged,
    required this.child,
    this.enableDesktopDrop = true,
  });

  final String destDir;
  final VoidCallback onChanged;
  final Widget child;
  final bool enableDesktopDrop;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget body = DragTarget<FsDragItem>(
      onWillAcceptWithDetails: (details) {
        final asCopy = _wantCopy();
        return _canDropItems(details.data.items, destDir, asCopy);
      },
      onAcceptWithDetails: (details) async {
        final asCopy = _wantCopy();
        await _dropItems(
          context: context,
          items: details.data.items,
          destDir: destDir,
          move: !asCopy,
          onChanged: onChanged,
        );
      },
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty;
        return DecoratedBox(
          decoration: BoxDecoration(
            border: hot
                ? Border.all(
                    color: Theme.of(context).colorScheme.primary,
                    width: 2,
                  )
                : Border.all(color: Colors.transparent, width: 2),
            color: hot
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.08)
                : null,
          ),
          child: child,
        );
      },
    );

    if (!enableDesktopDrop) return body;

    return DropTarget(
      onDragDone: (detail) async {
        final paths = <String>[
          for (final f in detail.files)
            if (f.path.isNotEmpty) f.path,
        ];
        if (paths.isEmpty) return;
        await importDroppedPaths(
          context,
          destDir: destDir,
          paths: paths,
          onDone: onChanged,
        );
      },
      child: body,
    );
  }
}

class _FsDragFeedback extends StatelessWidget {
  const _FsDragFeedback({required this.item});
  final FsDragItem item;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = item.items.length;
    final title = n == 1 ? item.primaryName : '$n 项';
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              n > 1
                  ? Icons.select_all
                  : (item.primaryIsDir
                      ? Icons.folder
                      : Icons.insert_drive_file_outlined),
              size: 16,
              color: cs.primary,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _wantCopy() ? '复制' : '移动',
              style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
