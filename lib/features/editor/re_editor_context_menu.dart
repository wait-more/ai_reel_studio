import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';

import '../../core/agent_bridge.dart';
import '../../core/comfy_prompt_bridge.dart';
import '../../core/providers.dart';

/// re_editor 右键菜单：AdaptiveTextSelectionToolbar 紧凑样式 +
/// Comfy 悬停二级菜单；左键点空白 / Esc 可关闭。
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
        return Stack(
          fit: StackFit.expand,
          children: [
            // 点空白关闭；二级 Comfy 菜单自带全屏吸收层，不会点穿到这里。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _dismiss,
              ),
            ),
            AdaptiveTextSelectionToolbar(
              anchors: anchors,
              children: [
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
              ],
            ),
          ],
        );
      },
    );
  }
}
