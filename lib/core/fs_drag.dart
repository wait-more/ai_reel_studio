import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_actions.dart';

/// 应用内文件拖拽载荷。
class FsDragItem {
  final String path;
  final bool isDir;
  final String name;

  const FsDragItem({
    required this.path,
    required this.isDir,
    required this.name,
  });
}

bool _wantCopy() =>
    HardwareKeyboard.instance.isControlPressed ||
    HardwareKeyboard.instance.isMetaPressed;

/// 可拖出；若 [dropIntoDir] 非空则同时作为应用内放入目标（文件夹）。
///
/// 注意：不要在 [DragTarget.builder] 里引用会被重新赋值的局部变量，
/// 否则闭包读到 DragTarget 自身会栈溢出。
class FsDragDropShell extends ConsumerWidget {
  const FsDragDropShell({
    super.key,
    required this.path,
    required this.isDir,
    required this.displayName,
    required this.onChanged,
    required this.child,
    this.dropIntoDir,
  });

  final String path;
  final bool isDir;
  final String displayName;
  final VoidCallback onChanged;
  final Widget child;

  /// 接受拖入的目标目录；null 表示不接受放入（例如文件卡片）。
  final String? dropIntoDir;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = FsDragItem(path: path, isDir: isDir, name: displayName);
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
        final d = details.data;
        return canRelocateTo(
          srcPath: d.path,
          isDir: d.isDir,
          destDir: dest,
          asCopy: _wantCopy(),
        );
      },
      onAcceptWithDetails: (details) async {
        final d = details.data;
        final asCopy = _wantCopy();
        if (!canRelocateTo(
          srcPath: d.path,
          isDir: d.isDir,
          destDir: dest,
          asCopy: asCopy,
        )) {
          return;
        }
        await relocateEntity(
          context,
          ProviderScope.containerOf(context, listen: false),
          srcPath: d.path,
          isDir: d.isDir,
          destDir: dest,
          move: !asCopy,
          onDone: onChanged,
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
          // 必须用固定的 [draggable]，不能引用外层可变 body。
          child: draggable,
        );
      },
    );
  }
}

/// 当前目录放入目标：应用内拖放 + 资源管理器拖入。
/// 只应包一层（素材栏整体 / 树列表外层），不要包到每个文件夹卡片上。
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
        final d = details.data;
        return canRelocateTo(
          srcPath: d.path,
          isDir: d.isDir,
          destDir: destDir,
          asCopy: _wantCopy(),
        );
      },
      onAcceptWithDetails: (details) async {
        final d = details.data;
        final asCopy = _wantCopy();
        await relocateEntity(
          context,
          ProviderScope.containerOf(context, listen: false),
          srcPath: d.path,
          isDir: d.isDir,
          destDir: destDir,
          move: !asCopy,
          onDone: onChanged,
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
              item.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
              size: 16,
              color: cs.primary,
            ),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                item.name,
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
