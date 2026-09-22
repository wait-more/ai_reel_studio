import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/config.dart';
import 'core/progress.dart';
import 'core/project_registry.dart';
import 'core/project_reload.dart';
import 'core/providers.dart';
import 'core/window_state.dart';
import 'core/windows_path.dart';
import 'core/workspace_memory.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 播放器初始化（必须在创建任何 Player 之前调用）
  MediaKit.ensureInitialized();

  await AppConfig.instance.init();
  final windowState = WindowState();
  await windowState.init();

  // 先刷新盘符↔UNC，避免工作区路径在 Z: / \\nas 形态下被误丢弃。
  if (Platform.isWindows) {
    await WindowsDriveUncCache.instance.refresh();
  }

  await ProjectRegistry.instance.migrateCurrentRootIfEmpty();
  if (AppConfig.instance.isConfigured) {
    await ProjectRegistry.instance.touch(AppConfig.instance.projectRoot);
  }

  final container = ProviderContainer();
  // 启动时把已保存的创作进度载入 provider（供树/网格徽章显示）
  final allStatuses = await loadAllStatuses();
  if (allStatuses.isNotEmpty) {
    container.read(episodeStatusesProvider.notifier).state = allStatuses;
  }

  // 恢复当前项目根下的目录树展开 + 中间栏（Tabs/模式/选中）
  final workspace = await WorkspaceMemory.instance.load();
  applyWorkspaceSnapshot(container, workspace);

  runApp(UncontrolledProviderScope(
    container: container,
    child: const AIReelStudioApp(),
  ));
}
