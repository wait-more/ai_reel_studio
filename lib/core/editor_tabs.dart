import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

/// Cursor / VS Code 风格：单击预览（斜体、可被替换），双击/编辑等固定。

/// 打开文档标签。
///
/// [pin] 为 false 时以预览打开：若已有预览标签则替换其槽位；
/// 为 true 时固定打开，不占用预览槽。
void openEditorTab(
  ProviderContainer container, {
  required String path,
  bool pin = false,
}) {
  final normalized = path.trim();
  if (normalized.isEmpty) return;

  final tabs = List<String>.of(container.read(openTabsProvider));
  final preview = container.read(previewTabPathProvider);
  final existing = tabs.indexOf(normalized);

  if (existing >= 0) {
    container.read(selectedFileProvider.notifier).state = normalized;
    if (pin && preview == normalized) {
      container.read(previewTabPathProvider.notifier).state = null;
    }
    container.read(contentModeProvider.notifier).state = 'editor';
    return;
  }

  if (pin) {
    tabs.add(normalized);
    container.read(openTabsProvider.notifier).state = tabs;
    container.read(selectedFileProvider.notifier).state = normalized;
    container.read(contentModeProvider.notifier).state = 'editor';
    return;
  }

  // 预览打开：替换已有预览槽，或追加新槽。
  if (preview != null) {
    final pIdx = tabs.indexOf(preview);
    if (pIdx >= 0) {
      tabs[pIdx] = normalized;
    } else {
      tabs.add(normalized);
    }
  } else {
    tabs.add(normalized);
  }
  container.read(openTabsProvider.notifier).state = tabs;
  container.read(previewTabPathProvider.notifier).state = normalized;
  container.read(selectedFileProvider.notifier).state = normalized;
  container.read(contentModeProvider.notifier).state = 'editor';
}

/// 将 [path] 从预览升格为固定（标题正体）。
void pinEditorTab(ProviderContainer container, String path) {
  final preview = container.read(previewTabPathProvider);
  if (preview != path) return;
  container.read(previewTabPathProvider.notifier).state = null;
}

/// 与 [openEditorTab] 相同，供只有 [WidgetRef] 的调用点使用。
void openEditorTabRef(
  WidgetRef ref, {
  required String path,
  bool pin = false,
}) {
  final normalized = path.trim();
  if (normalized.isEmpty) return;

  final tabs = List<String>.of(ref.read(openTabsProvider));
  final preview = ref.read(previewTabPathProvider);
  final existing = tabs.indexOf(normalized);

  if (existing >= 0) {
    ref.read(selectedFileProvider.notifier).state = normalized;
    if (pin && preview == normalized) {
      ref.read(previewTabPathProvider.notifier).state = null;
    }
    ref.read(contentModeProvider.notifier).state = 'editor';
    return;
  }

  if (pin) {
    tabs.add(normalized);
    ref.read(openTabsProvider.notifier).state = tabs;
    ref.read(selectedFileProvider.notifier).state = normalized;
    ref.read(contentModeProvider.notifier).state = 'editor';
    return;
  }

  if (preview != null) {
    final pIdx = tabs.indexOf(preview);
    if (pIdx >= 0) {
      tabs[pIdx] = normalized;
    } else {
      tabs.add(normalized);
    }
  } else {
    tabs.add(normalized);
  }
  ref.read(openTabsProvider.notifier).state = tabs;
  ref.read(previewTabPathProvider.notifier).state = normalized;
  ref.read(selectedFileProvider.notifier).state = normalized;
  ref.read(contentModeProvider.notifier).state = 'editor';
}

/// 与 [pinEditorTab] 相同，供只有 [WidgetRef] 的调用点使用。
void pinEditorTabRef(WidgetRef ref, String path) {
  final preview = ref.read(previewTabPathProvider);
  if (preview != path) return;
  ref.read(previewTabPathProvider.notifier).state = null;
}
