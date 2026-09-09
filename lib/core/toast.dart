import 'package:flutter/material.dart';

OverlayEntry? _activeToast;

/// 全局置顶提示条：插入根 Overlay，显示在所有窗口元素与弹窗之上，
/// 约 2.8 秒后自动消失。连续调用会先移除上一条。
///
/// [context] 若本身就是 Overlay 的 element（例如菜单用了
/// `overlayState.context`），`Overlay.of` 会找不到祖先而抛错；
/// 这里用 [Overlay.maybeOf] / 可选 [overlay] 兜底，失败则静默跳过。
void showGlobalToast(
  BuildContext context,
  String message, {
  OverlayState? overlay,
}) {
  final target = overlay ??
      Overlay.maybeOf(context, rootOverlay: true) ??
      Overlay.maybeOf(context);
  if (target == null) return;

  _activeToast?.remove();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => Positioned(
      top: 56,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: Colors.black.withValues(alpha: 0.82),
          elevation: 8,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ),
  );
  _activeToast = entry;
  target.insert(entry);
  Future.delayed(const Duration(milliseconds: 2800), () {
    if (_activeToast == entry) _activeToast = null;
    if (entry.mounted) entry.remove();
  });
}
