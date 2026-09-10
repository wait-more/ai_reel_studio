import 'dart:async';
import 'dart:io';

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

void _removeMenuEntry(OverlayEntry? entry) {
  if (entry == null) return;
  if (_activeMenuEntry == entry) {
    _activeMenuEntry = null;
    _activeComplete = null;
    _activeMenuRect = null;
  }
  // 必须同步移除：若延后到 microtask，紧接着 showDialog 时
  // 复用 GlobalKey / Inherited 依赖未清空会触发 dependents.isEmpty 断言。
  if (entry.mounted) {
    entry.remove();
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
  /// 多选时传入全部选中项；长度 > 1 时菜单仅保留剪切/复制/删除等批量操作。
  List<FsClipboardItem>? multiItems,
  /// 物料栏空白处右键：针对当前目录，仅保留粘贴/新建/导入等，不含删除重命名。
  bool background = false,
}) async {
  final overlayState = Overlay.maybeOf(context, rootOverlay: true);
  if (overlayState == null || !context.mounted) return;

  final hostContext = overlayState.context;
  final callerContext = context;
  final container = ProviderScope.containerOf(context, listen: false);
  final batch = (!background && multiItems != null && multiItems.length > 1)
      ? multiItems
      : null;

  _dismissActiveMenu();

  final isVideo = !background && !isDir && classifyMedia(path) == MediaKind.video;
  final completer = Completer<String?>();
  late OverlayEntry entry;
  // 每次菜单使用独立 Key，避免与尚未卸掉的旧 Overlay 抢同一个 GlobalKey。
  final menuKey = GlobalKey();

  void close([String? action]) {
    if (completer.isCompleted) return;
    _detachKeyHandler();
    _detachPointerRoute();
    _removeMenuEntry(entry);
    completer.complete(action);
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

  // 预先取色，减少 Overlay 重建时对外部 Inherited 的瞬时依赖窗口。
  final scheme = Theme.of(context).colorScheme;
  final menuColor = scheme.surfaceContainerHigh;
  final mutedColor = scheme.onSurfaceVariant;

  entry = OverlayEntry(
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      const menuWidth = 240.0;
      final clipboard = container.read(fsClipboardProvider);
      final canPaste = clipboard != null;

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

      final children = <Widget>[
        if (background) ...[
          if (canPaste)
            item(
              value: 'paste',
              icon: Icons.content_paste,
              label: '粘贴',
            ),
          item(
            value: 'newDoc',
            icon: Icons.note_add_outlined,
            label: '新建文档',
          ),
          item(
            value: 'newFolder',
            icon: Icons.create_new_folder_outlined,
            label: '新建文件夹',
          ),
          item(
            value: 'importHere',
            icon: Icons.file_upload_outlined,
            label: '导入物料',
          ),
          divider(),
          item(
            value: 'openTerminal',
            icon: Icons.terminal,
            label: '在终端打开',
          ),
          item(
            value: 'reveal',
            icon: Icons.folder_open,
            label: '在资源管理器显示',
          ),
          item(
            value: 'copyAbsPath',
            icon: Icons.link,
            label: '复制当前目录路径',
          ),
        ] else if (batch == null) ...[
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
          if (isDir)
            item(
              value: 'openTerminal',
              icon: Icons.terminal,
              label: '在终端打开',
            ),
          if (isDir)
            item(
              value: 'importHere',
              icon: Icons.file_upload_outlined,
              label: '在此导入物料',
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
            value: 'copyAbsPath',
            icon: Icons.link,
            label: '复制绝对路径',
          ),
          item(
            value: 'copyRelPath',
            icon: Icons.account_tree_outlined,
            label: '复制相对路径',
          ),
          item(
            value: 'copyName',
            icon: Icons.text_fields,
            label: '复制名称',
          ),
          divider(),
          item(
            value: 'cut',
            icon: Icons.content_cut,
            label: '剪切',
          ),
          item(
            value: 'copy',
            icon: Icons.copy,
            label: '复制',
          ),
          if (canPaste)
            item(
              value: 'paste',
              icon: Icons.content_paste,
              label: '粘贴',
            ),
          item(
            value: 'rename',
            icon: Icons.drive_file_rename_outline,
            label: '重命名',
          ),
          divider(),
          item(
            value: 'properties',
            icon: Icons.info_outline,
            label: '属性',
          ),
          item(
            value: 'delete',
            icon: Icons.delete_outline,
            label: '删除',
            iconColor: Colors.red[300],
            labelColor: Colors.red[300],
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text(
              '已选 ${batch.length} 项',
              style: TextStyle(
                fontSize: 12,
                color: mutedColor,
              ),
            ),
          ),
          item(
            value: 'cut',
            icon: Icons.content_cut,
            label: '剪切 ${batch.length} 项',
          ),
          item(
            value: 'copy',
            icon: Icons.copy,
            label: '复制 ${batch.length} 项',
          ),
          item(
            value: 'delete',
            icon: Icons.delete_outline,
            label: '删除 ${batch.length} 项',
            iconColor: Colors.red[300],
            labelColor: Colors.red[300],
          ),
        ],
      ];

      // 估算高度用于贴边；实际以布局为准。
      final menuHeight = (children.length * 36.0).clamp(80.0, size.height - 16);
      final left =
          globalPosition.dx.clamp(8.0, size.width - menuWidth - 8.0);
      final top =
          globalPosition.dy.clamp(8.0, size.height - menuHeight - 8.0);

      _activeMenuRect = Rect.fromLTWH(left, top, menuWidth, menuHeight);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_activeMenuEntry != entry || !entry.mounted) return;
        final box =
            menuKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize && box.attached) {
          _activeMenuRect = box.localToGlobal(Offset.zero) & box.size;
        }
      });

      // 只放面板，不铺全屏 Stack，避免截获下层命中。
      return Positioned(
        left: left,
        top: top,
        child: Material(
          key: menuKey,
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          clipBehavior: Clip.antiAlias,
          color: menuColor,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: size.height - 16),
            child: SingleChildScrollView(
              child: SizedBox(
                width: menuWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
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
  // 优先用调用方 context（有正确 Overlay 祖先）；菜单用的 overlayState.context
  // 本身就是 Overlay，向上找不到 Overlay，Toast 会报错。
  final actionContext =
      callerContext.mounted ? callerContext : hostContext;
  if (!actionContext.mounted) return;
  await runFsAction(
    context: actionContext,
    overlay: overlayState,
    container: container,
    action: action,
    path: path,
    isDir: isDir,
    displayName: displayName,
    onOpen: onOpen,
    onChanged: onChanged,
    multiItems: batch,
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
  if (complete != null) {
    // close() 内部会同步卸掉 OverlayEntry 并 complete。
    complete(action);
    return;
  }
  _detachKeyHandler();
  _detachPointerRoute();
  _removeMenuEntry(entry);
}

/// 执行文件系统菜单动作（右键菜单与键盘快捷键共用）。
Future<void> runFsAction({
  required BuildContext context,
  OverlayState? overlay,
  required ProviderContainer container,
  required String action,
  required String path,
  required bool isDir,
  required String displayName,
  required Future<void> Function() onOpen,
  required void Function() onChanged,
  List<FsClipboardItem>? multiItems,
}) async {
  void toast(String msg) =>
      showGlobalToast(context, msg, overlay: overlay);

  switch (action) {
    case 'open':
      await onOpen();
      break;
    case 'reveal':
      await revealInExplorer(path);
      break;
    case 'openTerminal':
      {
        final dir = isDir ? path : File(path).parent.path;
        container.read(shellVisibleProvider.notifier).state = true;
        container.read(shellOpenCwdRequestProvider.notifier).state = dir;
        toast('已在终端打开');
      }
      break;
    case 'importHere':
      if (isDir) {
        await importFilesToDir(context, dir: path, onDone: onChanged);
      }
      break;
    case 'grabFirst':
      await _grabFrame(
        context,
        path: path,
        tag: '首帧',
        lastFrame: false,
        onChanged: onChanged,
        overlay: overlay,
      );
      break;
    case 'grabLast':
      await _grabFrame(
        context,
        path: path,
        tag: '末帧',
        lastFrame: true,
        onChanged: onChanged,
        overlay: overlay,
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
    case 'copyAbsPath':
      await copyAbsolutePath(context, path);
      break;
    case 'copyRelPath':
      await copyProjectRelativePath(context, path);
      break;
    case 'copyName':
      await copyBaseName(context, path);
      break;
    case 'cut':
      {
        final items = multiItems ??
            [FsClipboardItem(path: path, isDir: isDir)];
        container.read(fsClipboardProvider.notifier).state =
            FsClipboardEntry(items: items, isCut: true);
        toast(items.length == 1
            ? '已剪切：$displayName'
            : '已剪切 ${items.length} 项');
      }
      break;
    case 'copy':
      {
        final items = multiItems ??
            [FsClipboardItem(path: path, isDir: isDir)];
        container.read(fsClipboardProvider.notifier).state =
            FsClipboardEntry(items: items, isCut: false);
        toast(items.length == 1
            ? '已复制：$displayName'
            : '已复制 ${items.length} 项');
      }
      break;
    case 'paste':
      {
        final destDir = isDir ? path : File(path).parent.path;
        await pasteClipboardEntry(
          context,
          container,
          destDir: destDir,
          onDone: onChanged,
          overlay: overlay,
        );
      }
      break;
    case 'rename':
      await renameEntityDialog(
        context,
        path: path,
        isDir: isDir,
        onDone: onChanged,
      );
      break;
    case 'properties':
      await showEntityPropertiesDialog(
        context,
        path: path,
        isDir: isDir,
      );
      break;
    case 'delete':
      if (multiItems != null && multiItems.length > 1) {
        final ok = await deleteEntitiesDialog(
          context,
          items: multiItems,
          onDone: onChanged,
        );
        if (ok) {
          for (final item in multiItems) {
            closeOpenDocumentsAffectedBy(
              container,
              path: item.path,
              isDir: item.isDir,
            );
          }
        }
      } else {
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
  OverlayState? overlay,
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
    overlay: overlay,
  );
  if (result != null) onChanged();
}
