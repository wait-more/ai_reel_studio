import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/agent_bridge.dart';
import '../../core/comfy_prompt_bridge.dart';
import '../../core/providers.dart';

/// re_editor 右键菜单：与目录树 [showFsContextMenu] 同一套表面
/// （surfaceContainerHigh + elevation，无描边）+ Comfy 悬停二级菜单。
class ReEditorContextMenuController implements SelectionToolbarController {
  ReEditorContextMenuController({
    required this.hostContext,
    required this.ref,
  });

  final BuildContext hostContext;
  final WidgetRef ref;

  final ContextMenuController _menu = ContextMenuController();
  ValueNotifier<bool>? _visibility;
  VoidCallback? _visibilityListener;
  bool _keyHandlerAttached = false;

  void _detachVisibility() {
    if (_visibility != null && _visibilityListener != null) {
      _visibility!.removeListener(_visibilityListener!);
    }
    _visibility = null;
    _visibilityListener = null;
  }

  void _detachKeyHandler() {
    if (_keyHandlerAttached) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _keyHandlerAttached = false;
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return true;
    }
    return false;
  }

  void _dismiss() {
    _detachVisibility();
    _detachKeyHandler();
    ContextMenuController.removeAny();
  }

  @override
  void hide(BuildContext context) {
    _dismiss();
  }

  @override
  void show({
    required BuildContext context,
    required CodeLineEditingController controller,
    required TextSelectionToolbarAnchors anchors,
    Rect? renderRect,
    required LayerLink layerLink,
    required ValueNotifier<bool> visibility,
  }) {
    _dismiss();

    _visibility = visibility;
    _visibilityListener = () {
      if (!visibility.value) _dismiss();
    };
    visibility.addListener(_visibilityListener!);

    HardwareKeyboard.instance.addHandler(_onKey);
    _keyHandlerAttached = true;

    final chord = ref.read(sendAgentRefChordProvider);
    final selected = controller.selectedText;
    final hasSel = selected.trim().isNotEmpty;

    _menu.show(
      context: context,
      contextMenuBuilder: (menuContext) {
        final children = <Widget>[
          ...AdaptiveTextSelectionToolbar.getAdaptiveButtons(
            menuContext,
            [
              ContextMenuButtonItem(
                label: '剪切',
                onPressed: () {
                  _dismiss();
                  controller.cut();
                },
              ),
              ContextMenuButtonItem(
                label: '复制',
                onPressed: () {
                  _dismiss();
                  controller.copy();
                },
              ),
              ContextMenuButtonItem(
                label: '粘贴',
                onPressed: () {
                  _dismiss();
                  controller.paste();
                },
              ),
            ],
          ),
          const Divider(height: 8),
          ...AdaptiveTextSelectionToolbar.getAdaptiveButtons(
            menuContext,
            [
              ContextMenuButtonItem(
                label: '填入智能体 (${chord.label})',
                onPressed: () {
                  _dismiss();
                  if (!hostContext.mounted) return;
                  sendAgentReferenceToShell(hostContext, ref);
                },
              ),
            ],
          ),
          if (hasSel)
            ComfyPromptFillSubmenuButton(
              selectedText: selected,
              hostContext: hostContext,
            ),
        ];

        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismiss,
              ),
            ),
            _DesktopContextMenuPanel(
              anchor: anchors.primaryAnchor,
              children: children,
            ),
          ],
        );
      },
    );
  }
}

/// 布局同 [DesktopTextSelectionToolbar]，外观对齐目录树右键：
/// surfaceContainerHigh + elevation 8，无描边。
class _DesktopContextMenuPanel extends StatelessWidget {
  const _DesktopContextMenuPanel({
    required this.anchor,
    required this.children,
  });

  final Offset anchor;
  final List<Widget> children;

  static const double _screenPadding = 8;
  static const double _toolbarWidth = 222;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final paddingAbove =
        MediaQuery.paddingOf(context).top + _screenPadding;
    final localAdjustment = Offset(_screenPadding, paddingAbove);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        paddingAbove,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchor - localAdjustment,
        ),
        child: SizedBox(
          width: _toolbarWidth,
          child: Material(
            color: cs.surfaceContainerHigh,
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
        ),
      ),
    );
  }
}
