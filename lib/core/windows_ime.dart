import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 中文输入法候选窗偶发消失的缓解（原生侧轮换 HIMC）。
///
/// 对应 runner `ime_context.cpp`；非 Windows 为空操作。
class WindowsIme {
  WindowsIme._();

  static const MethodChannel _channel =
      MethodChannel('ai_reel_studio/windows_ime');

  static Timer? _debounce;
  static WindowsImeGuard? _guard;

  /// 立即请求原生刷新；组字中由原生跳过。
  static Future<void> refresh() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('refresh');
    } catch (_) {
      // 渠道未就绪或旧包：忽略。
    }
  }

  /// 合并短时间内的多次请求（焦点连跳、窗口激活）。
  static void refreshDebounced({
    Duration delay = const Duration(milliseconds: 80),
  }) {
    if (!Platform.isWindows) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      unawaited(refresh());
    });
  }

  /// 在 [main] 里启动一次：窗口重回前台、焦点变化时尝试恢复。
  static void ensureGuardStarted() {
    if (!Platform.isWindows) return;
    _guard ??= WindowsImeGuard()..start();
  }

  static void disposeGuard() {
    _debounce?.cancel();
    _debounce = null;
    _guard?.dispose();
    _guard = null;
  }
}

class WindowsImeGuard with WindowListener {
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    windowManager.addListener(this);
    FocusManager.instance.addListener(_onFocusChange);
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    windowManager.removeListener(this);
    FocusManager.instance.removeListener(_onFocusChange);
  }

  @override
  void onWindowFocus() {
    WindowsIme.refreshDebounced();
  }

  void _onFocusChange() {
    // 终端 ↔ 编辑器等切换后，偶发整窗 IME 会话发霉；焦点落定后再刷一次。
    WindowsIme.refreshDebounced(
      delay: const Duration(milliseconds: 120),
    );
  }
}
