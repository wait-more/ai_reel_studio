import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'comfy/comfy_models.dart';
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

/// 删除文件或目录后，关闭受影响的编辑器 Tab，并清理脏标记 / 视图状态。
void closeOpenDocumentsAffectedBy(
  ProviderContainer container, {
  required String path,
  required bool isDir,
}) {
  final sep = Platform.pathSeparator;
  final pathNorm = path.toLowerCase();

  bool affected(String candidate) {
    final t = candidate.toLowerCase();
    if (t == pathNorm) return true;
    if (!isDir) return false;
    final prefix = pathNorm.endsWith(sep) ? pathNorm : '$pathNorm$sep';
    return t.startsWith(prefix);
  }

  final tabs = container.read(openTabsProvider);
  final newTabs = tabs.where((t) => !affected(t)).toList();
  if (newTabs.length != tabs.length) {
    container.read(openTabsProvider.notifier).state = newTabs;
  }

  final dirty = container.read(dirtyFilesProvider);
  final newDirty = dirty.where((p) => !affected(p)).toSet();
  if (newDirty.length != dirty.length) {
    container.read(dirtyFilesProvider.notifier).state = newDirty;
  }

  final saves = container.read(saveActionsProvider);
  if (saves.keys.any(affected)) {
    container.read(saveActionsProvider.notifier).state = {
      for (final e in saves.entries)
        if (!affected(e.key)) e.key: e.value,
    };
  }

  final views = container.read(editorViewStatesProvider);
  if (views.keys.any(affected)) {
    container.read(editorViewStatesProvider.notifier).state = {
      for (final e in views.entries)
        if (!affected(e.key)) e.key: e.value,
    };
  }

  final selected = container.read(selectedFileProvider);
  if (selected != null && affected(selected)) {
    container.read(selectedFileProvider.notifier).state =
        newTabs.isNotEmpty ? newTabs.last : null;
  }

  final selectedDir = container.read(selectedDirProvider);
  if (selectedDir != null && affected(selectedDir)) {
    final parent = Directory(path).parent.path;
    container.read(selectedDirProvider.notifier).state = parent;
  }
}

/// 各文档光标/滚动位置（供工作区记忆持久化与恢复）。
final editorViewStatesProvider =
    StateProvider<Map<String, EditorViewState>>((ref) => {});

/// 右面板（Shell）是否可见
final shellVisibleProvider = StateProvider<bool>((ref) => true);

/// 项目树根节点
final treeRootProvider = StateProvider<ScriptNode?>((ref) => null);

/// 中间视图模式：'editor' | 'assets' | 'comfy'
final contentModeProvider = StateProvider<String>((ref) => 'editor');

/// ComfyUI 多实例列表 / 当前选中实例。
final comfyServersProvider = StateProvider<List<ComfyServer>>(
  (ref) => AppConfig.instance.comfyServers,
);
final comfySelectedServerIdProvider = StateProvider<String>(
  (ref) => AppConfig.instance.comfySelectedServerId,
);

/// 兼容旧代码：当前选中实例的 URL / Key。
final comfyBaseUrlProvider = Provider<String>((ref) {
  final id = ref.watch(comfySelectedServerIdProvider);
  final list = ref.watch(comfyServersProvider);
  for (final s in list) {
    if (s.id == id) return s.baseUrl;
  }
  return list.isNotEmpty
      ? list.first.baseUrl
      : AppConfig.defaultComfyBaseUrl;
});
final comfyApiKeyProvider = Provider<String>((ref) {
  final id = ref.watch(comfySelectedServerIdProvider);
  final list = ref.watch(comfyServersProvider);
  for (final s in list) {
    if (s.id == id) return s.apiKey;
  }
  return list.isNotEmpty ? list.first.apiKey : '';
});

/// 强制刷新 `.aireel/comfy` 动作列表（手动刷新或外部变更）。
final comfyActionsTickProvider = StateProvider<int>((ref) => 0);

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

/// 本地保存成功后是否删除 Comfy 远端本次 history/output。
final comfyDeleteRemoteAfterDownloadProvider = StateProvider<bool>(
  (ref) => AppConfig.instance.comfyDeleteRemoteAfterDownload,
);
