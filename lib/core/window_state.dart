import 'dart:ui' show Size;

import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// 窗口状态管理：最大化偏好记忆与恢复。
///
/// 首启默认最大化填满屏幕（保留系统标题栏与窗口按钮）；
/// 此后记录“上次是否最大化”，下次启动按记忆恢复。
///
/// 无闪烁方案：用原生 `screen_retriever` 读取真实显示器逻辑尺寸，在
/// 窗口创建时即以该尺寸（满屏/工作区）生成，show 时直接满屏，无“先小窗
/// 再放大”跳变；随后再切到正式最大化态补齐任务栏避让与状态记录。
class WindowState extends WindowListener {
  static const _prefsKey = 'window_maximized';
  bool _preferMaximized = true;

  Future<void> init() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_prefsKey);
    _preferMaximized = saved ?? true;

    // 读取主屏逻辑尺寸（dp）。优先可见工作区（排除任务栏），否则全屏。
    // 通过原生插件获取，不受 Flutter 远端假 viewport 影响。
    Size fullSize = const Size(1280, 800);
    bool haveScreen = false;
    try {
      final primary = await screenRetriever.getPrimaryDisplay();
      final area = primary.visibleSize ?? primary.size;
      if (area.width.isFinite &&
          area.height.isFinite &&
          area.width >= 800 &&
          area.height >= 600) {
        fullSize = Size(area.width, area.height);
        haveScreen = true;
      }
    } catch (_) {
      // 读取失败则保持默认尺寸（后面用 maximize 兜底）
    }

    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: 'AIReelStudio',
        // 能读到屏幕尺寸时直接以满屏/工作区尺寸创建（无闪烁）；
        // 否则用正常尺寸、稍后经 maximize 补齐。
        // 不用 center:true —— 满屏尺寸本身占满屏幕，且 center 在部分版本
        // 会引发“先别处后居中”的闪烁。
        size: _preferMaximized && haveScreen
            ? fullSize
            : const Size(1280, 800),
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        // 首帧已按工作区满屏显示，再切到正式最大化态（状态记录 + 兜底）
        if (_preferMaximized) {
          await windowManager.maximize();
        }
      },
    );
  }

  @override
  void onWindowMaximize() {
    _store(true);
  }

  @override
  void onWindowUnmaximize() {
    _store(false);
  }

  Future<void> _store(bool maximized) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, maximized);
  }
}
