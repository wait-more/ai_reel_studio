import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config.dart';
import 'directory_parser.dart';
import 'key_chord.dart';
import 'workspace_memory.dart';

/// 当前选中的文件路径（在编辑区打开）
final selectedFileProvider = StateProvider<String?>((ref) => null);

/// 当前选中的目录路径（用作物料网格视图）
final selectedDirProvider = StateProvider<String?>((ref) => null);

/// 已打开的 Tab 文件路径列表
final openTabsProvider = StateProvider<List<String>>((ref) => []);

/// 各文档光标/滚动位置（供工作区记忆持久化与恢复）。
final editorViewStatesProvider =
    StateProvider<Map<String, EditorViewState>>((ref) => {});

/// 右面板（Shell）是否可见
final shellVisibleProvider = StateProvider<bool>((ref) => true);

/// 项目树根节点
final treeRootProvider = StateProvider<ScriptNode?>((ref) => null);

/// 中间视图模式：'editor' = 文档编辑器，'assets' = 物料网格
final contentModeProvider = StateProvider<String>((ref) => 'editor');

/// 有未保存修改的文档路径集合
final dirtyFilesProvider = StateProvider<Set<String>>((ref) => {});

/// 各打开文档的“保存”回调（path -> 保存函数），供关闭提醒/外部触发使用
typedef SaveAction = Future<void> Function();
final saveActionsProvider =
    StateProvider<Map<String, SaveAction>>((ref) => {});

/// 剧本/季/集 → 创作进度状态。setter 同步写回 SharedPreferences
/// （key: episode_status:<path>）。
final episodeStatusesProvider = StateProvider<Map<String, String>>((ref) => {});

/// 左侧目录树当前已展开的节点路径（供持久化）。
final expandedTreePathsProvider = StateProvider<List<String>>((ref) => []);

/// 目录树/物料网格结构变更 tick（递增即触发双方刷新）。
final treeRefreshTickProvider = StateProvider<int>((ref) => 0);

/// 外观 / 字号 / 快捷启动等用户偏好（与 [AppConfig] 同步持久化）。
final themeModeProvider = StateProvider<ThemeMode>(
  (ref) => AppConfig.instance.themeMode,
);
final uiFontScaleProvider = StateProvider<double>(
  (ref) => AppConfig.instance.uiFontScale,
);
final editorFontSizeProvider = StateProvider<double>(
  (ref) => AppConfig.instance.editorFontSize,
);
final terminalFontSizeProvider = StateProvider<double>(
  (ref) => AppConfig.instance.terminalFontSize,
);
final startCmdsProvider = StateProvider<List<StartCmd>>(
  (ref) => AppConfig.instance.startCmds,
);
final sendAgentRefChordProvider = StateProvider<KeyChord>(
  (ref) => AppConfig.instance.sendAgentRefChord,
);
