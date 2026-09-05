import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/config.dart';
import 'core/progress.dart';
import 'core/providers.dart';
import 'core/window_state.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 播放器初始化（必须在创建任何 Player 之前调用）
  MediaKit.ensureInitialized();

  await AppConfig.instance.init();
  final windowState = WindowState();
  await windowState.init();

  final container = ProviderContainer();
  // 启动时把已保存的创作进度载入 provider（供树/网格徽章显示）
  final allStatuses = await loadAllStatuses();
  if (allStatuses.isNotEmpty) {
    container.read(episodeStatusesProvider.notifier).state = allStatuses;
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const AIReelStudioApp(),
  ));
}