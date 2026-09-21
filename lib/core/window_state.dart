import 'dart:ui' show Size;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口状态管理：最大化偏好记忆与恢复。
///
/// 首启默认最大化（保留系统标题栏与窗口按钮）；
/// 此后记录“上次是否最大化”，下次启动按记忆恢复。
///
/// 窗口在原生侧保持隐藏，直到这里 show。需要最大化时先进入最大化再显示，
/// 避免“先按屏幕尺寸铺满、再被 SW_SHOWNORMAL 还原”的跳变。
class WindowState extends WindowListener {
  static const _prefsKey = 'window_maximized';
  bool _preferMaximized = true;

  /// 启动过程中的还原事件不写入偏好，以免把“上次是最大化”覆盖掉。
  bool _tracking = false;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    final prefs = await SharedPreferences.getInstance();
    _preferMaximized = prefs.getBool(_prefsKey) ?? true;

    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'AIReelStudio',
        size: _preferMaximized ? null : const Size(1280, 800),
        center: !_preferMaximized,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        if (_preferMaximized) {
          await windowManager.maximize();
          // maximize 在 Windows 上是 PostMessage，等状态生效再显示。
          for (var i = 0; i < 40; i++) {
            if (await windowManager.isMaximized()) break;
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
        }
        await windowManager.show();
        await windowManager.focus();
        _tracking = true;
      },
    );
  }

  @override
  void onWindowMaximize() {
    if (_tracking) _store(true);
  }

  @override
  void onWindowUnmaximize() {
    if (_tracking) _store(false);
  }

  Future<void> _store(bool maximized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, maximized);
  }
}
