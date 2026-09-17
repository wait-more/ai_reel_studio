import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'file_actions.dart';
import 'providers.dart';
import 'toast.dart';

/// 文件/文件夹原地新建或重命名（目录树 / 素材栏）。
enum InlineFsEditKind { rename, newDocument, newFolder }

class InlineFsEdit {
  final InlineFsEditKind kind;
  /// 在目录树还是素材栏原地编辑（避免两侧同时出现输入框抢焦点）。
  final FsShortcutPane surface;
  /// 重命名目标路径；新建时为 null。
  final String? path;
  /// 新建所在父目录；重命名时为 dirname(path)。
  final String parentDir;
  final bool isDir;
  final String initialName;
  final int nonce;

  const InlineFsEdit({
    required this.kind,
    required this.surface,
    required this.parentDir,
    required this.isDir,
    required this.initialName,
    required this.nonce,
    this.path,
  });

  bool matchesRename(String candidatePath, FsShortcutPane surface) =>
      kind == InlineFsEditKind.rename &&
      this.surface == surface &&
      path == candidatePath;

  bool matchesCreateUnder(String dir, FsShortcutPane surface) =>
      this.surface == surface &&
      (kind == InlineFsEditKind.newDocument ||
          kind == InlineFsEditKind.newFolder) &&
      p.equals(p.normalize(parentDir), p.normalize(dir));
}

final inlineFsEditProvider = StateProvider<InlineFsEdit?>((ref) => null);

int _nextInlineNonce = 0;

void clearInlineFsEdit(WidgetRef ref) {
  ref.read(inlineFsEditProvider.notifier).state = null;
}

void clearInlineFsEditContainer(ProviderContainer container) {
  container.read(inlineFsEditProvider.notifier).state = null;
}

void beginInlineRename(
  WidgetRef ref, {
  required String path,
  required bool isDir,
  required FsShortcutPane surface,
}) {
  ref.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.rename,
    surface: surface,
    path: path,
    parentDir: p.dirname(path),
    isDir: isDir,
    initialName: p.basename(path),
    nonce: ++_nextInlineNonce,
  );
}

void beginInlineRenameContainer(
  ProviderContainer container, {
  required String path,
  required bool isDir,
  required FsShortcutPane surface,
}) {
  container.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.rename,
    surface: surface,
    path: path,
    parentDir: p.dirname(path),
    isDir: isDir,
    initialName: p.basename(path),
    nonce: ++_nextInlineNonce,
  );
}

void beginInlineNewDocument(
  WidgetRef ref, {
  required String parentDir,
  required FsShortcutPane surface,
}) {
  ref.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.newDocument,
    surface: surface,
    parentDir: parentDir,
    isDir: false,
    initialName: '新建文档.md',
    nonce: ++_nextInlineNonce,
  );
}

void beginInlineNewDocumentContainer(
  ProviderContainer container, {
  required String parentDir,
  required FsShortcutPane surface,
}) {
  container.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.newDocument,
    surface: surface,
    parentDir: parentDir,
    isDir: false,
    initialName: '新建文档.md',
    nonce: ++_nextInlineNonce,
  );
}

void beginInlineNewFolder(
  WidgetRef ref, {
  required String parentDir,
  required FsShortcutPane surface,
}) {
  ref.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.newFolder,
    surface: surface,
    parentDir: parentDir,
    isDir: true,
    initialName: '新建文件夹',
    nonce: ++_nextInlineNonce,
  );
}

void beginInlineNewFolderContainer(
  ProviderContainer container, {
  required String parentDir,
  required FsShortcutPane surface,
}) {
  container.read(inlineFsEditProvider.notifier).state = InlineFsEdit(
    kind: InlineFsEditKind.newFolder,
    surface: surface,
    parentDir: parentDir,
    isDir: true,
    initialName: '新建文件夹',
    nonce: ++_nextInlineNonce,
  );
}

/// 提交原地编辑；成功返回最终路径，取消/失败返回 null。
Future<String?> commitInlineFsEdit(
  BuildContext context,
  WidgetRef ref,
  InlineFsEdit edit,
  String rawName,
) async {
  final name = rawName.trim();
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..')) {
    clearInlineFsEdit(ref);
    return null;
  }

  try {
    switch (edit.kind) {
      case InlineFsEditKind.rename:
        final oldPath = edit.path!;
        if (name == p.basename(oldPath)) {
          clearInlineFsEdit(ref);
          return oldPath;
        }
        final target = p.join(edit.parentDir, name);
        if (await File(target).exists() || await Directory(target).exists()) {
          if (context.mounted) {
            showGlobalToast(context, '已存在同名项');
          }
          return null;
        }
        final entity = edit.isDir ? Directory(oldPath) : File(oldPath);
        await entity.rename(target);
        _retargetOpenDocs(ref, from: oldPath, to: target, isDir: edit.isDir);
        clearInlineFsEdit(ref);
        return target;
      case InlineFsEditKind.newFolder:
        {
          var finalName = name;
          var target = p.join(edit.parentDir, finalName);
          if (await Directory(target).exists() || await File(target).exists()) {
            target = uniqueSiblingPath(
              edit.parentDir,
              finalName,
              isDir: true,
            );
            finalName = p.basename(target);
          }
          await Directory(target).create(recursive: true);
          clearInlineFsEdit(ref);
          return target;
        }
      case InlineFsEditKind.newDocument:
        {
          var finalName = name;
          final parts = explorerNameParts(finalName, isDir: false);
          if (parts.ext.isEmpty) finalName = '$finalName.md';
          var target = p.join(edit.parentDir, finalName);
          if (await File(target).exists() || await Directory(target).exists()) {
            target = uniqueSiblingPath(
              edit.parentDir,
              finalName,
              isDir: false,
            );
          }
          await File(target).create(recursive: true);
          clearInlineFsEdit(ref);
          return target;
        }
    }
  } catch (e) {
    if (context.mounted) {
      showGlobalToast(context, '操作失败：$e');
    }
    return null;
  }
}

void _retargetOpenDocs(
  WidgetRef ref, {
  required String from,
  required String to,
  required bool isDir,
}) {
  final sep = Platform.pathSeparator;
  final fromNorm = from.toLowerCase();
  String mapPath(String candidate) {
    final t = candidate.toLowerCase();
    if (t == fromNorm) return to;
    if (!isDir) return candidate;
    final prefix = fromNorm.endsWith(sep) ? fromNorm : '$fromNorm$sep';
    if (!t.startsWith(prefix)) return candidate;
    return to + candidate.substring(from.length);
  }

  final tabs = ref.read(openTabsProvider);
  final newTabs = [for (final t in tabs) mapPath(t)];
  if (newTabs.toString() != tabs.toString()) {
    ref.read(openTabsProvider.notifier).state = newTabs;
  }

  final selected = ref.read(selectedFileProvider);
  if (selected != null) {
    final mapped = mapPath(selected);
    if (mapped != selected) {
      ref.read(selectedFileProvider.notifier).state = mapped;
    }
  }

  final dirty = ref.read(dirtyFilesProvider);
  final newDirty = {for (final d in dirty) mapPath(d)};
  if (newDirty.length != dirty.length || !newDirty.containsAll(dirty)) {
    ref.read(dirtyFilesProvider.notifier).state = newDirty;
  }

  final saves = ref.read(saveActionsProvider);
  if (saves.keys.any((k) => mapPath(k) != k)) {
    ref.read(saveActionsProvider.notifier).state = {
      for (final e in saves.entries) mapPath(e.key): e.value,
    };
  }
  final views = ref.read(editorViewStatesProvider);
  if (views.keys.any((k) => mapPath(k) != k)) {
    ref.read(editorViewStatesProvider.notifier).state = {
      for (final e in views.entries) mapPath(e.key): e.value,
    };
  }
  final drafts = ref.read(draftContentsProvider);
  if (drafts.keys.any((k) => mapPath(k) != k)) {
    ref.read(draftContentsProvider.notifier).state = {
      for (final e in drafts.entries) mapPath(e.key): e.value,
    };
  }

  final preview = ref.read(previewTabPathProvider);
  if (preview != null) {
    final mapped = mapPath(preview);
    if (mapped != preview) {
      ref.read(previewTabPathProvider.notifier).state = mapped;
    }
  }
}

/// 原地文件名输入：描边方框，文件默认只选中主名。
class InlineFsNameField extends StatefulWidget {
  const InlineFsNameField({
    super.key,
    required this.initialName,
    required this.isDir,
    required this.onSubmit,
    required this.onCancel,
  });

  final String initialName;
  final bool isDir;
  final ValueChanged<String> onSubmit;
  final VoidCallback onCancel;

  @override
  State<InlineFsNameField> createState() => _InlineFsNameFieldState();
}

class _InlineFsNameFieldState extends State<InlineFsNameField> {
  late final TextEditingController _ctrl;
  final FocusNode _focus = FocusNode();
  bool _done = false;
  bool _stemScheduled = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialName);
    _applyStemSelection();
    _focus.addListener(_onFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
    });
  }

  void _applyStemSelection() {
    if (_ctrl.text != widget.initialName) return;
    final parts = explorerNameParts(widget.initialName, isDir: widget.isDir);
    final end = parts.stem.length.clamp(0, _ctrl.text.length);
    _ctrl.value = _ctrl.value.copyWith(
      selection: TextSelection(baseOffset: 0, extentOffset: end),
      composing: TextRange.empty,
    );
  }

  /// 桌面端 TextField 获得焦点会全选；等焦点处理完再改回只选主名。
  void _scheduleStemSelection() {
    if (_stemScheduled) return;
    _stemScheduled = true;
    void apply() {
      if (!mounted || _done) return;
      _applyStemSelection();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      apply();
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    });
    Future<void>.delayed(const Duration(milliseconds: 16), apply);
    Future<void>.delayed(const Duration(milliseconds: 50), apply);
  }

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _scheduleStemSelection();
      return;
    }
    if (!_done) _submit();
  }

  void _submit() {
    if (_done) return;
    _done = true;
    widget.onSubmit(_ctrl.text);
  }

  void _cancel() {
    if (_done) return;
    _done = true;
    widget.onCancel();
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    final ctrl = _ctrl;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ctrl.dispose();
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    OutlineInputBorder border(Color color, {double width = 1}) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: color, width: width),
        );
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _CancelIntent(),
        SingleActivator(LogicalKeyboardKey.enter): _SubmitIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _SubmitIntent(),
      },
      child: Actions(
        actions: {
          _CancelIntent: CallbackAction<_CancelIntent>(
            onInvoke: (_) {
              _cancel();
              return null;
            },
          ),
          _SubmitIntent: CallbackAction<_SubmitIntent>(
            onInvoke: (_) {
              _submit();
              return null;
            },
          ),
        },
        child: TextField(
          controller: _ctrl,
          focusNode: _focus,
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.55),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            border: border(cs.primary),
            enabledBorder: border(cs.primary),
            focusedBorder: border(cs.primary, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _CancelIntent extends Intent {
  const _CancelIntent();
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}
