import 'package:flutter/material.dart';

OverlayEntry? _activeToast;

/// 全局置顶提示条：插入根 Overlay，显示在所有窗口元素与弹窗之上，
/// 约 2.8 秒后自动消失。连续调用会先移除上一条。
void showGlobalToast(BuildContext context, String message) {
  final overlay = Overlay.of(context, rootOverlay: true);
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
  overlay.insert(entry);
  Future.delayed(const Duration(milliseconds: 2800), () {
    if (_activeToast == entry) _activeToast = null;
    if (entry.mounted) entry.remove();
  });
}