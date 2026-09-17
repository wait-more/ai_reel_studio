import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fs_context_menu.dart';

OverlayEntry? _tabMenuEntry;
void Function(String?)? _tabMenuComplete;
bool Function(KeyEvent)? _tabMenuKeyHandler;
void Function(PointerEvent)? _tabMenuPointerRoute;
Rect? _tabMenuRect;
int _tabMenuEpoch = 0;

/// 关掉文档标签右键菜单。已关掉或没有菜单时返回 false。
bool dismissEditorTabMenu() {
  if (_tabMenuComplete == null && _tabMenuEntry == null) return false;
  _dismissTabMenu();
  return true;
}

void _detachTabPointer() {
  final route = _tabMenuPointerRoute;
  _tabMenuPointerRoute = null;
  if (route != null) {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(route);
  }
}

void _detachTabKey() {
  final handler = _tabMenuKeyHandler;
  _tabMenuKeyHandler = null;
  if (handler != null) {
    HardwareKeyboard.instance.removeHandler(handler);
  }
}

void _removeTabEntry(OverlayEntry? entry) {
  if (entry == null) return;
  if (_tabMenuEntry == entry) {
    _tabMenuEntry = null;
    _tabMenuComplete = null;
    _tabMenuRect = null;
  }
  if (entry.mounted) entry.remove();
}

void _dismissTabMenu([String? action]) {
  final complete = _tabMenuComplete;
  final entry = _tabMenuEntry;
  if (complete != null) {
    complete(action);
    return;
  }
  _detachTabKey();
  _detachTabPointer();
  _removeTabEntry(entry);
}

/// 文档标签右键菜单：风格与目录树 [showFsContextMenu] 一致（紧凑、分区）。
Future<String?> showEditorTabMenu({
  required BuildContext context,
  required Offset globalPosition,
  required bool canCloseOthers,
  required bool canCloseRight,
  bool isPreview = false,
}) async {
  registerPeerOverlayMenuDismisser(dismissEditorTabMenu);
  dismissFsContextMenu();
  _dismissTabMenu();

  final overlayState = Overlay.maybeOf(context, rootOverlay: true);
  if (overlayState == null || !context.mounted) return null;

  final completer = Completer<String?>();
  late OverlayEntry entry;
  final menuKey = GlobalKey();
  final epoch = ++_tabMenuEpoch;

  void close([String? action]) {
    if (epoch != _tabMenuEpoch) return;
    if (completer.isCompleted) return;
    _tabMenuEpoch++;
    _detachTabKey();
    _detachTabPointer();
    _removeTabEntry(entry);
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
    if (epoch != _tabMenuEpoch) return;
    final rect = _tabMenuRect;
    if (rect != null && rect.inflate(2).contains(event.position)) {
      return;
    }
    close();
  }

  _tabMenuComplete = close;
  _tabMenuKeyHandler = onKey;
  _tabMenuPointerRoute = onGlobalPointer;
  HardwareKeyboard.instance.addHandler(onKey);
  GestureBinding.instance.pointerRouter.addGlobalRoute(onGlobalPointer);

  final scheme = Theme.of(context).colorScheme;
  final menuColor = scheme.surfaceContainerHigh;
  final mutedColor = scheme.onSurfaceVariant;

  entry = OverlayEntry(
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      const menuWidth = 240.0;

      Widget item({
        required String value,
        required IconData icon,
        required String label,
        bool enabled = true,
      }) {
        final color = enabled ? null : mutedColor.withValues(alpha: 0.45);
        return InkWell(
          onTap: enabled ? () => close(value) : null,
          child: SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 13, color: color),
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
        item(value: 'close', icon: Icons.close, label: '关闭'),
        item(
          value: 'closeOthers',
          icon: Icons.clear_all,
          label: '关闭其它',
          enabled: canCloseOthers,
        ),
        item(
          value: 'closeRight',
          icon: Icons.keyboard_double_arrow_right,
          label: '关闭右侧',
          enabled: canCloseRight,
        ),
        item(
          value: 'closeAll',
          icon: Icons.cancel_outlined,
          label: '关闭全部',
        ),
        if (isPreview) ...[
          divider(),
          item(
            value: 'pin',
            icon: Icons.push_pin_outlined,
            label: '固定',
          ),
        ],
        divider(),
        item(
          value: 'reveal',
          icon: Icons.folder_open,
          label: '在资源管理器显示',
        ),
        item(
          value: 'revealTree',
          icon: Icons.my_location_outlined,
          label: '在目录树中定位',
        ),
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
      ];

      final estimatedHeight =
          (children.length * 36.0).clamp(80.0, 480.0);
      final left =
          globalPosition.dx.clamp(8.0, size.width - menuWidth - 8.0);
      final top = globalPosition.dy
          .clamp(8.0, size.height - estimatedHeight - 8.0);

      _tabMenuRect ??= Rect.fromLTWH(left, top, menuWidth, estimatedHeight);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_tabMenuEntry != entry || !entry.mounted) return;
        final box =
            menuKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize && box.attached) {
          _tabMenuRect = box.localToGlobal(Offset.zero) & box.size;
        }
      });

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

  _tabMenuEntry = entry;
  overlayState.insert(entry);

  final action = await completer.future;
  if (_tabMenuKeyHandler == onKey) _detachTabKey();
  if (_tabMenuPointerRoute == onGlobalPointer) _detachTabPointer();
  return action;
}
