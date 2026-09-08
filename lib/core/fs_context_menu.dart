import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/media/media_preview.dart';
import 'file_actions.dart';
import 'media_types.dart';
import 'providers.dart';
import 'toast.dart';

/// 兼容调用点的包装；切换菜单不依赖此组件做命中。
class FsContextMenuTarget extends StatelessWidget {
  const FsContextMenuTarget({
    super.key,
    required this.path,
    required this.isDir,
    required this.displayName,
    required this.onOpen,
    required this.onChanged,
    required this.child,
  });

  final String path;
  final bool isDir;
  final String displayName;
  final Future<void> Function() onOpen;
  final void Function() onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

OverlayEntry? _activeMenuEntry;
void Function(String?)? _activeComplete;
bool Function(KeyEvent)? _activeKeyHandler;
void Function(PointerEvent)? _activePointerRoute;
Rect? _activeMenuRect;
final GlobalKey _menuKey = GlobalKey();

void _detachPointerRoute() {
  final route = _activePointerRoute;
  _activePointerRoute = null;
  if (route != null) {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(route);
  }
}

void _detachKeyHandler() {
  final handler = _activeKeyHandler;
  _activeKeyHandler = null;
  if (handler != null) {
    HardwareKeyboard.instance.removeHandler(handler);
  }
}

/// 左树与中间素材栏共用的文件系统右键菜单。
///
/// 关键要点（修复「换地方右键只关不开」）：
/// - Overlay **只放菜单面板**，没有全屏遮罩。全屏遮罩会截获 pointer，
///   下层 InkWell 收不到右键，只能关掉旧菜单。
/// - 用全局 pointer 路由检测「点在菜单外」→ 关闭；右键落到其它目标时，
///   事件仍由该目标的 `onSecondaryTap` 处理并打开新菜单。
Future<void> showFsContextMenu({
  required BuildContext context,
  required Offset globalPosition,
  required String path,
  required bool isDir,
  required String displayName,
  required Future<void> Function() onOpen,
  required void Function() onChanged,
}) async {
  final overlayState = Overlay.maybeOf(context, rootOverlay: true);
  if (overlayState == null || !context.mounted) return;

  final hostContext = overlayState.context;
  final container = ProviderScope.containerOf(context, listen: false);

  _dismissActiveMenu();

  final isVideo = !isDir && classifyMedia(path) == MediaKind.video;
  final completer = Completer<String?>();
  late OverlayEntry entry;

  void close([String? action]) {
    if (completer.isCompleted) return;
    completer.complete(action);
    _detachKeyHandler();
    _detachPointerRoute();
    _activeMenuRect = null;
    if (_activeMenuEntry == entry) {
      _activeMenuEntry = null;
      _activeComplete = null;
    }
    scheduleMicrotask(() {
      if (entry.mounted) entry.remove();
    });
  }

  bool onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      close();
      return true;
    }
    return false;
  }

  void onGlobalPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    if (_activeComplete != close) return;

    final rect = _activeMenuRect;
    if (rect != null && rect.inflate(2).contains(event.position)) {
      return;
    }

    // 菜单外任意按下：关闭。右键点在其它文件/目录上时，目标仍会收到
    // 该事件并在 onSecondaryTap 里打开新菜单。
    close();
  }

  _activeComplete = close;
  _activeKeyHandler = onKey;
  _activePointerRoute = onGlobalPointer;
  HardwareKeyboard.instance.addHandler(onKey);
  GestureBinding.instance.pointerRouter.addGlobalRoute(onGlobalPointer);

  entry = OverlayEntry(
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      const menuWidth = 220.0;
      const itemH = 36.0;
      var itemCount = 2;
      if (isVideo) itemCount += 3;
      if (isDir) itemCount += 4;
      itemCount += 2;
      if (!isDir) itemCount += 1;
      itemCount += 3;
      final menuHeight = itemCount * itemH;
      final left =
          globalPosition.dx.clamp(8.0, size.width - menuWidth - 8.0);
      final top =
          globalPosition.dy.clamp(8.0, size.height - menuHeight - 8.0);

      _activeMenuRect = Rect.fromLTWH(left, top, menuWidth, menuHeight);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final box =
            _menuKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize && box.attached) {
          _activeMenuRect = box.localToGlobal(Offset.zero) & box.size;
        }
      });

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

      // 只放面板，不铺全屏 Stack，避免截获下层命中。
      return Positioned(
        left: left,
        top: top,
        child: Material(
          key: _menuKey,
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
                    value: 'newDoc',
                    icon: Icons.note_add_outlined,
                    label: '新建文档',
                  ),
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
      );
    },
  );

  _activeMenuEntry = entry;
  overlayState.insert(entry);

  final action = await completer.future;
  _detachKeyHandler();
  _detachPointerRoute();
  if (action == null) return;
  await _waitPostFrame();
  if (!hostContext.mounted) return;
  await _runAction(
    context: hostContext,
    container: container,
    action: action,
    path: path,
    isDir: isDir,
    displayName: displayName,
    onOpen: onOpen,
    onChanged: onChanged,
  );
}

Future<void> _waitPostFrame() {
  final c = Completer<void>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!c.isCompleted) c.complete();
  });
  return c.future;
}

void _dismissActiveMenu([String? action]) {
  final complete = _activeComplete;
  final entry = _activeMenuEntry;
  _activeComplete = null;
  _activeMenuEntry = null;
  _activeMenuRect = null;
  if (complete != null) {
    complete(action);
    return;
  }
  _detachKeyHandler();
  _detachPointerRoute();
  if (entry != null && entry.mounted) {
    scheduleMicrotask(() {
      if (entry.mounted) entry.remove();
    });
  }
}

Future<void> _runAction({
  required BuildContext context,
  required ProviderContainer container,
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
    case 'newDoc':
      final created = await newDocumentDialog(context, parentDir: path);
      if (created != null) {
        _openInEditor(container, created);
        onChanged();
      }
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
        container,
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
      final ok = await deleteEntityDialog(
        context,
        path: path,
        isDir: isDir,
        onDone: onChanged,
      );
      if (ok) {
        closeOpenDocumentsAffectedBy(
          container,
          path: path,
          isDir: isDir,
        );
      }
      break;
  }
}

void _openInEditor(ProviderContainer container, String path) {
  container.read(selectedFileProvider.notifier).state = path;
  final tabs = container.read(openTabsProvider);
  if (!tabs.contains(path)) {
    container.read(openTabsProvider.notifier).state = [...tabs, path];
  }
  container.read(contentModeProvider.notifier).state = 'editor';
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
