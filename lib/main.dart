import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/config.dart';
import 'core/progress.dart';
import 'core/providers.dart';
import 'core/window_state.dart';
import 'core/workspace_memory.dart';

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

  // 恢复目录树展开线索 + 中间栏（Tabs/模式/选中）
  final workspace = await WorkspaceMemory.instance.load();
  if (workspace.openTabs.isNotEmpty) {
    container.read(openTabsProvider.notifier).state = workspace.openTabs;
  }
  if (workspace.selectedFile != null) {
    container.read(selectedFileProvider.notifier).state = workspace.selectedFile;
  }
  if (workspace.selectedDir != null) {
    container.read(selectedDirProvider.notifier).state = workspace.selectedDir;
  }
  container.read(contentModeProvider.notifier).state = workspace.contentMode;
  if (workspace.expandedPaths.isNotEmpty) {
    container.read(expandedTreePathsProvider.notifier).state =
        workspace.expandedPaths;
  }
  if (workspace.fileViews.isNotEmpty) {
    container.read(editorViewStatesProvider.notifier).state =
        Map.of(workspace.fileViews);
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const AIReelStudioApp(),
  ));
}
