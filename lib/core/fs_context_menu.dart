import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/media/media_preview.dart';
import 'file_actions.dart';
import 'media_types.dart';
import 'toast.dart';

/// 挂在可右键目标上，供「已有菜单时再右键」命中后打开新菜单。
class FsContextMenuTarget extends StatelessWidget {
  const FsContextMenuTarget({
    super.key,
    required this.path,
    required this.isDir,
    required this.displayName,
    required this.ref,
    required this.onOpen,
    required this.onChanged,
    required this.child,
  });

  final String path;
  final bool isDir;
  final String displayName;
  final WidgetRef ref;
  final Future<void> Function() onOpen;
  final void Function() onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: _FsContextMenuAnchor(
        path: path,
        isDir: isDir,
        displayName: displayName,
        ref: ref,
        onOpen: onOpen,
        onChanged: onChanged,
      ),
      child: child,
    );
  }
}

class _FsContextMenuAnchor {
  const _FsContextMenuAnchor({
    required this.path,
    required this.isDir,
    required this.displayName,
    required this.ref,
    required this.onOpen,
    required this.onChanged,
  });

  final String path;
  final bool isDir;
  final String displayName;
  final WidgetRef ref;
  final Future<void> Function() onOpen;
  final void Function() onChanged;
}

OverlayEntry? _activeMenuEntry;
void Function(String?)? _activeComplete;

/// 左树与中间素材栏共用的文件系统右键菜单。
///
/// 使用 Overlay 而非 [showMenu]，以便在菜单已打开时再次右键能直接切到新目标，
/// 而不是只关掉旧菜单。
Future<void> showFsContextMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset globalPosition,
  required String path,
  required bool isDir,
  required String displayName,
  required Future<void> Function() onOpen,
  required void Function() onChanged,
}) async {
  final overlayState = Overlay.maybeOf(context, rootOverlay: true);
  if (overlayState == null || !context.mounted) return;

  // 关掉已有菜单（同目标再次右键也会先关再开）。
  _dismissActiveMenu();

  final isVideo = !isDir && classifyMedia(path) == MediaKind.video;
  final completer = Completer<String?>();
  late OverlayEntry entry;

  void close([String? action]) {
    if (_activeMenuEntry == entry) {
      _activeMenuEntry = null;
      _activeComplete = null;
    }
    if (entry.mounted) {
      entry.remove();
    }
    if (!completer.isCompleted) {
      completer.complete(action);
    }
  }

  _activeComplete = close;

  entry = OverlayEntry(
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      const menuWidth = 220.0;
      const itemH = 36.0;
      // 粗略估算高度，用于贴边夹紧。
      var itemCount = 2; // open + reveal
      if (isVideo) itemCount += 3;
      if (isDir) itemCount += 3;
      itemCount += 2; // rename + delete
      if (!isDir) itemCount += 1; // duplicate
      itemCount += 3; // dividers approx
      final menuHeight = itemCount * itemH;
      var left = globalPosition.dx;
      var top = globalPosition.dy;
      left = left.clamp(8.0, media.size.width - menuWidth - 8.0);
      top = top.clamp(8.0, media.size.height - menuHeight - 8.0);

      Widget item({
        required String value,
        required IconData icon,
        required String label,
        Color? iconColor,
        Color? labelColor,
      }) {
        return InkWell(
          onTap: () => close(value),
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: iconColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 13, color: labelColor),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }

      Widget divider() => const Divider(height: 4, thickness: 1);

      return Stack(
        children: [
          // 遮罩：左键只关闭；右键关闭后按落点重新命中目标并打开新菜单。
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (e) {
                final secondary =
                    (e.buttons & kSecondaryMouseButton) != 0;
                final pos = e.position;
                close();
                if (secondary) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _openFromHitTest(context, pos);
                  });
                }
              },
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              child: SizedBox(
                width: menuWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    item(
                      value: 'open',
                      icon: Icons.open_in_new,
                      label: isDir ? '在当前目录查看' : '打开',
                    ),
                    item(
                      value: 'reveal',
                      icon: Icons.folder_open,
                      label: '在资源管理器显示',
                    ),
                    if (isVideo) ...[
                      divider(),
                      item(
                        value: 'grabFirst',
                        icon: Icons.first_page,
                        label: '截取首帧',
                        iconColor: Colors.tealAccent,
                      ),
                      item(
                        value: 'grabLast',
                        icon: Icons.last_page,
                        label: '截取末帧',
                        iconColor: Colors.tealAccent,
                      ),
                    ],
                    if (isDir) ...[
                      divider(),
                      item(
                        value: 'newFolder',
                        icon: Icons.create_new_folder_outlined,
                        label: '新建子文件夹',
                      ),
                      item(
                        value: 'progress',
                        icon: Icons.donut_large,
                        label: '设置创作进度',
                        iconColor: Colors.teal,
                      ),
                    ],
                    divider(),
                    item(
                      value: 'rename',
                      icon: Icons.drive_file_rename_outline,
                      label: '重命名',
                    ),
                    if (!isDir)
                      item(
                        value: 'duplicate',
                        icon: Icons.copy,
                        label: '复制',
                      ),
                    divider(),
                    item(
                      value: 'delete',
                      icon: Icons.delete_outline,
                      label: '删除',
                      iconColor: Colors.red[300],
                      labelColor: Colors.red[300],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  _activeMenuEntry = entry;
  overlayState.insert(entry);

  final action = await completer.future;
  if (action == null || !context.mounted) return;
  await _runAction(
    context: context,
    ref: ref,
    action: action,
    path: path,
    isDir: isDir,
    displayName: displayName,
    onOpen: onOpen,
    onChanged: onChanged,
  );
}

void _dismissActiveMenu([String? action]) {
  final complete = _activeComplete;
  final entry = _activeMenuEntry;
  _activeComplete = null;
  _activeMenuEntry = null;
  if (entry != null && entry.mounted) {
    entry.remove();
  }
  complete?.call(action);
}

void _openFromHitTest(BuildContext context, Offset globalPos) {
  if (!context.mounted) return;
  final view = View.maybeOf(context);
  if (view == null) return;

  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, globalPos, view.viewId);

  for (final entry in result.path) {
    final target = entry.target;
    if (target is! RenderMetaData) continue;
    final data = target.metaData;
    if (data is! _FsContextMenuAnchor) continue;
    showFsContextMenu(
      context: context,
      ref: data.ref,
      globalPosition: globalPos,
      path: data.path,
      isDir: data.isDir,
      displayName: data.displayName,
      onOpen: data.onOpen,
      onChanged: data.onChanged,
    );
    return;
  }
}

Future<void> _runAction({
  required BuildContext context,
  required WidgetRef ref,
  required String action,
  required String path,
  required bool isDir,
  required String displayName,
  required Future<void> Function() onOpen,
  required void Function() onChanged,
}) async {
  switch (action) {
    case 'open':
      await onOpen();
      break;
    case 'reveal':
      await revealInExplorer(path);
      break;
    case 'grabFirst':
      await _grabFrame(
        context,
        path: path,
        tag: '首帧',
        lastFrame: false,
        onChanged: onChanged,
      );
      break;
    case 'grabLast':
      await _grabFrame(
        context,
        path: path,
        tag: '末帧',
        lastFrame: true,
        onChanged: onChanged,
      );
      break;
    case 'newFolder':
      await newFolderDialog(
        context,
        parentDir: path,
        onDone: onChanged,
      );
      break;
    case 'progress':
      await setProgressDialog(
        context,
        ref,
        path: path,
        displayName: displayName,
      );
      break;
    case 'rename':
      await renameEntityDialog(
        context,
        path: path,
        isDir: isDir,
        onDone: onChanged,
      );
      break;
    case 'duplicate':
      await duplicateFileDialog(
        context,
        path: path,
        onDone: onChanged,
      );
      break;
    case 'delete':
      await deleteEntityDialog(
        context,
        path: path,
        isDir: isDir,
        onDone: onChanged,
      );
      break;
  }
}

Future<void> _grabFrame(
  BuildContext context, {
  required String path,
  required String tag,
  required bool lastFrame,
  required void Function() onChanged,
}) async {
  final result = await extractMediaFrame(
    path: path,
    tag: tag,
    lastFrame: lastFrame,
    hostContext: context,
  );
  if (!context.mounted) return;
  showGlobalToast(
    context,
    result != null ? '已保存：$result' : '截帧失败：未取得帧数据',
  );
  if (result != null) onChanged();
}
