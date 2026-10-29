import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Windows 中文输入法候选窗偶发消失的缓解（原生侧轮换 HIMC）。
///
/// 只在窗口重新获得前台时触发；不要在 FocusManager 上刷——每次点选都会卡一下。
/// 原生 [WM_ACTIVATE] 也会刷新；这里作为 window_manager 侧的补充。
class WindowsIme {
  WindowsIme._();

  static const MethodChannel _channel =
      MethodChannel('ai_reel_studio/windows_ime');

  static Timer? _debounce;
  static WindowsImeGuard? _guard;
  static DateTime? _lastRefreshAt;

  /// 最短间隔，避免连点/连切窗口时反复 ImmCreateContext。
  static const _minInterval = Duration(seconds: 2);

  /// 立即请求原生刷新；组字中由原生跳过。带节流。
  static Future<void> refresh({bool force = false}) async {
    if (!Platform.isWindows) return;
    final now = DateTime.now();
    if (!force &&
        _lastRefreshAt != null &&
        now.difference(_lastRefreshAt!) < _minInterval) {
      return;
    }
    _lastRefreshAt = now;
    try {
      await _channel.invokeMethod<void>('refresh');
    } catch (_) {
      // 渠道未就绪或旧包：忽略。
    }
  }

  /// 合并短时间内的多次窗口激活。
  static void refreshDebounced({
    Duration delay = const Duration(milliseconds: 200),
  }) {
    if (!Platform.isWindows) return;
    _debounce?.cancel();
    _debounce = Timer(delay, () {
      unawaited(refresh());
    });
  }

  /// 在 [main] 里启动一次：仅监听窗口重回前台。
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
  }

  void dispose() {
    if (!_started) return;
    _started = false;
    windowManager.removeListener(this);
  }

  @override
  void onWindowFocus() {
    WindowsIme.refreshDebounced();
  }
}
