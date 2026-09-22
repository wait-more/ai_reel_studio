import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../features/layout/main_layout.dart';
import 'comfy_prompt_bridge.dart';
import 'config.dart';
import 'inline_fs_edit.dart';
import 'project_registry.dart';
import 'providers.dart';
import 'toast.dart';
import 'workspace_memory.dart';

/// 把工作区快照灌进 Riverpod（启动 / 换根硬加载共用）。
void applyWorkspaceSnapshot(
  ProviderContainer container,
  WorkspaceSnapshot workspace,
) {
  final root = AppConfig.instance.projectRoot;
  container.read(openTabsProvider.notifier).state = workspace.openTabs;
  container.read(previewTabPathProvider.notifier).state =
      workspace.previewTabPath;
  container.read(selectedFileProvider.notifier).state = workspace.selectedFile;
  if (workspace.selectedDir != null) {
    container.read(selectedDirProvider.notifier).state = workspace.selectedDir;
  } else if (workspace.contentMode == 'assets' && root.isNotEmpty) {
    container.read(selectedDirProvider.notifier).state = root;
  } else {
    container.read(selectedDirProvider.notifier).state = null;
  }
  container.read(contentModeProvider.notifier).state = workspace.contentMode;
  container.read(expandedTreePathsProvider.notifier).state =
      workspace.expandedPaths;
  container.read(editorViewStatesProvider.notifier).state =
      Map.of(workspace.fileViews);
}

/// 换根前：把当前内存工作区落到 [projectRoot] 桶，避免被新根 sanitize 冲掉。
Future<void> persistWorkspaceForRoot(
  ProviderContainer container,
  String projectRoot,
) async {
  final root = projectRoot.trim();
  if (root.isEmpty) return;
  final snap = WorkspaceSnapshot(
    expandedPaths: container.read(expandedTreePathsProvider),
    openTabs: container.read(openTabsProvider),
    previewTabPath: container.read(previewTabPathProvider),
    selectedFile: container.read(selectedFileProvider),
    selectedDir: container.read(selectedDirProvider),
    contentMode: container.read(contentModeProvider),
    fileViews: container.read(editorViewStatesProvider),
  );
  await WorkspaceMemory.instance.saveNow(snap, projectRoot: root);
}

/// 清掉会话级、跟路径强相关的内存态（草稿/脏标/树选中等）。
void clearEphemeralProjectProviders(ProviderContainer container) {
  container.read(dirtyFilesProvider.notifier).state = {};
  container.read(draftContentsProvider.notifier).state = {};
  container.read(saveActionsProvider.notifier).state = {};
  container.read(treeSelectionProvider.notifier).state = [];
  container.read(treeRootProvider.notifier).state = null;
  container.read(assetsRevealFilesProvider.notifier).state = null;
  container.read(treeRevealRequestProvider.notifier).state = null;
  container.read(fsClipboardProvider.notifier).state = null;
  container.read(shellOpenCwdRequestProvider.notifier).state = null;
  container.read(comfyPromptInjectRequestProvider.notifier).state = null;
  container.read(inlineFsEditProvider.notifier).state = null;
}

/// 按当前 [AppConfig.projectRoot] 重载工作区 + 提示词快捷，并 bump 刷新 tick。
Future<void> hydrateAfterProjectRootChange(
  ProviderContainer container,
) async {
  clearEphemeralProjectProviders(container);
  final workspace = await WorkspaceMemory.instance.load();
  applyWorkspaceSnapshot(container, workspace);
  await ComfyPromptSendMemory.hydrateProviderContainer(container);
  container.read(comfyActionsTickProvider.notifier).state++;
  container.read(treeRefreshTickProvider.notifier).state++;
}

/// 设置里切换项目根的数据层：落盘旧根 → 写新根 → touch 最近列表 → 重灌 provider。
/// 返回是否实际切换（同根则 false）；UI 层负责重建路由。
Future<bool> switchProjectRootData({
  required ProviderContainer container,
  required String newRoot,
  required bool firstRun,
}) async {
  final oldRoot = AppConfig.instance.projectRoot.trim();
  final next = newRoot.trim();
  if (next.isEmpty) return false;
  if (!firstRun &&
      oldRoot.isNotEmpty &&
      prefsRootKey(oldRoot) == prefsRootKey(next)) {
    await ProjectRegistry.instance.touch(next);
    return false;
  }

  if (!firstRun && oldRoot.isNotEmpty) {
    await persistWorkspaceForRoot(container, oldRoot);
  }

  await AppConfig.instance.setProjectRoot(next);
  await ProjectRegistry.instance.touch(next);
  await hydrateAfterProjectRootChange(container);
  return true;
}

/// 有未保存文档时询问；返回 true 表示可继续切换。
Future<bool> confirmLeaveDirtyDocuments(
  BuildContext context,
  ProviderContainer container,
) async {
  final dirty = container.read(dirtyFilesProvider);
  if (dirty.isEmpty) return true;

  final paths = dirty.toList()..sort();
  final names = paths.map(p.basename).toList();
  final action = await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final scheme = Theme.of(ctx).colorScheme;
      final show = names.length <= 4 ? names : names.take(3).toList();
      return AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        title: Text(
          names.length == 1 ? '文档未保存' : '${names.length} 个文档未保存',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '切换项目前请先处理未保存的文档。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              for (final name in show)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.3,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              if (names.length > 4)
                Text(
                  '另有 ${names.length - 3} 个…',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('不保存'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: Text(names.length == 1 ? '保存' : '全部保存'),
          ),
        ],
      );
    },
  );

  if (!context.mounted) return false;
  if (action == 'save') {
    await _saveAllDirty(container);
    if (container.read(dirtyFilesProvider).isEmpty) return true;
    if (!context.mounted) return false;
    showGlobalToast(context, '部分文档保存失败');
    return false;
  }
  if (action == 'discard') {
    container.read(discardUnsavedEditsTickProvider.notifier).state++;
    container.read(dirtyFilesProvider.notifier).state = {};
    container.read(draftContentsProvider.notifier).state = {};
    await Future<void>.delayed(const Duration(milliseconds: 120));
    container.read(dirtyFilesProvider.notifier).state = {};
    return true;
  }
  return false;
}

Future<void> _saveAllDirty(ProviderContainer container) async {
  final dirty = container.read(dirtyFilesProvider).toList();
  final saves = container.read(saveActionsProvider);
  for (final path in dirty) {
    final save = saves[path];
    if (save != null) {
      try {
        await save();
      } catch (_) {}
      continue;
    }
    final draft = container.read(draftContentsProvider)[path];
    if (draft == null) {
      container.read(dirtyFilesProvider.notifier).update((s) {
        if (!s.contains(path)) return s;
        return {...s}..remove(path);
      });
      continue;
    }
    try {
      await File(path).writeAsString(draft);
      container.read(dirtyFilesProvider.notifier).update((s) {
        if (!s.contains(path)) return s;
        return {...s}..remove(path);
      });
      container.read(draftContentsProvider.notifier).update((m) {
        if (!m.containsKey(path)) return m;
        return {...m}..remove(path);
      });
    } catch (_) {}
  }
}

void _rebuildMainLayout(BuildContext context) {
  Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
    MaterialPageRoute(
      builder: (_) => MainLayout(
        key: ValueKey(prefsRootKey(AppConfig.instance.projectRoot)),
      ),
    ),
    (route) => false,
  );
}

/// 设置 / 首次运行：确认 dirty → 校验目录 → 切根数据 → 硬重建 MainLayout。
///
/// 返回：是否完成切换（含 firstRun 首次进入）；同根 no-op 返回 false。
Future<bool> switchProjectRootAndRebuild(
  BuildContext context, {
  required String newRoot,
  required bool firstRun,
}) async {
  final next = newRoot.trim();
  if (next.isEmpty) return false;

  try {
    if (!Directory(next).existsSync()) {
      if (context.mounted) {
        showGlobalToast(context, '目录不存在');
      }
      return false;
    }
  } catch (_) {
    if (context.mounted) {
      showGlobalToast(context, '目录不存在');
    }
    return false;
  }

  final container = ProviderScope.containerOf(context, listen: false);
  final oldRoot = AppConfig.instance.projectRoot.trim();
  final sameRoot = !firstRun &&
      oldRoot.isNotEmpty &&
      prefsRootKey(oldRoot) == prefsRootKey(next);

  if (!firstRun && !sameRoot) {
    final ok = await confirmLeaveDirtyDocuments(context, container);
    if (!ok || !context.mounted) return false;
  }

  final switched = await switchProjectRootData(
    container: container,
    newRoot: next,
    firstRun: firstRun,
  );
  if (!context.mounted) return false;
  if (!switched && !firstRun) return false;

  _rebuildMainLayout(context);
  return true;
}
