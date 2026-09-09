import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'config.dart';
import 'progress.dart';
import 'providers.dart';
import 'toast.dart';

/// 通用文件/目录操作（左树与物料网格共用）。
///
/// 均为带对话框的交互式操作；参数传 path/isDir，成功后通过
/// 可选回调 [onDone] 通知调用方刷新（重建树 / 重载网格）。

/// 在系统文件管理器中显示目标。
Future<void> revealInExplorer(String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
    } else {
      await Process.run('xdg-open', [Directory(path).parent.path]);
    }
  } catch (_) {
    // 忽略打开失败
  }
}

/// 弹文本输入框，返回输入值（取消返回 null）。
Future<String?> promptTextDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) async {
  final ctrl = TextEditingController(text: initial);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: const TextStyle(fontSize: 15)),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  final text = ctrl.text;
  ctrl.dispose();
  return ok == true ? text : null;
}

Future<void> copyTextToClipboard(
  BuildContext context,
  String text, {
  String toast = '已复制',
}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showGlobalToast(context, toast);
}

/// 复制绝对路径。
Future<void> copyAbsolutePath(BuildContext context, String path) =>
    copyTextToClipboard(context, path, toast: '已复制绝对路径');

/// 复制相对项目根的路径；不在根下则回退绝对路径。
Future<void> copyProjectRelativePath(BuildContext context, String path) async {
  final root = AppConfig.instance.projectRoot.trim();
  var text = path;
  if (root.isNotEmpty) {
    final rel = p.relative(path, from: root);
    if (!rel.startsWith('..') && !p.isAbsolute(rel)) {
      text = rel.replaceAll('\\', '/');
    }
  }
  await copyTextToClipboard(context, text, toast: '已复制相对路径');
}

/// 仅复制文件/文件夹名。
Future<void> copyBaseName(BuildContext context, String path) =>
    copyTextToClipboard(context, p.basename(path), toast: '已复制名称');

String _uniqueSiblingPath(String parentDir, String name, {required bool isDir}) {
  final ext = isDir ? '' : p.extension(name);
  final base = isDir ? name : p.basenameWithoutExtension(name);
  final first = isDir ? '${base}_copy' : '${base}_copy$ext';
  var target = p.join(parentDir, first);
  var i = 2;
  while (isDir ? Directory(target).existsSync() : File(target).existsSync()) {
    final candidate = isDir ? '${base}_copy$i' : '${base}_copy$i$ext';
    target = p.join(parentDir, candidate);
    i++;
  }
  return target;
}

/// 是否可将 [srcPath] 放入 [destDir]。
/// [asCopy]=false 时，同目录视为无效（移动无意义）。
bool canRelocateTo({
  required String srcPath,
  required bool isDir,
  required String destDir,
  bool asCopy = false,
}) {
  if (destDir.trim().isEmpty) return false;
  if (!Directory(destDir).existsSync()) return false;
  final srcNorm = p.normalize(srcPath);
  final destNorm = p.normalize(destDir);
  if (isDir && (p.equals(srcNorm, destNorm) || p.isWithin(srcNorm, destNorm))) {
    return false;
  }
  if (!asCopy && p.equals(p.dirname(srcPath), destDir)) return false;
  return true;
}

/// 将文件/文件夹移动或复制到 [destDir]。
/// [move]=true 为移动，false 为复制。成功返回目标路径。
Future<String?> relocateEntity(
  BuildContext context,
  ProviderContainer container, {
  required String srcPath,
  required bool isDir,
  required String destDir,
  required bool move,
  VoidCallback? onDone,
  OverlayState? overlay,
  bool silent = false,
}) async {
  if (!(isDir
      ? await Directory(srcPath).exists()
      : await File(srcPath).exists())) {
    if (!silent) _showError(context, move ? '源已不存在' : '复制源已不存在');
    return null;
  }
  if (!await Directory(destDir).exists()) {
    if (!silent) _showError(context, '目标目录不存在');
    return null;
  }
  if (isDir) {
    final srcNorm = p.normalize(srcPath);
    final destNorm = p.normalize(destDir);
    if (p.equals(srcNorm, destNorm) || p.isWithin(srcNorm, destNorm)) {
      if (!silent) _showError(context, '不能放入自身或其子目录');
      return null;
    }
  }

  final name = p.basename(srcPath);
  var target = p.join(destDir, name);
  if (p.equals(p.dirname(srcPath), destDir)) {
    if (move) {
      if (!silent && context.mounted) {
        showGlobalToast(context, '已在目标目录', overlay: overlay);
      }
      return srcPath;
    }
    target = _uniqueSiblingPath(destDir, name, isDir: isDir);
  } else if (await File(target).exists() || await Directory(target).exists()) {
    target = _uniqueSiblingPath(destDir, name, isDir: isDir);
  }

  try {
    if (move) {
      try {
        if (isDir) {
          await Directory(srcPath).rename(target);
        } else {
          await File(srcPath).rename(target);
        }
      } catch (_) {
        if (isDir) {
          await _copyDirectoryRecursive(Directory(srcPath), Directory(target));
          await Directory(srcPath).delete(recursive: true);
        } else {
          await File(srcPath).copy(target);
          await File(srcPath).delete();
        }
      }
      closeOpenDocumentsAffectedBy(container, path: srcPath, isDir: isDir);
      onDone?.call();
      if (!silent && context.mounted) {
        showGlobalToast(context, '已移动', overlay: overlay);
      }
      return target;
    }

    if (isDir) {
      await _copyDirectoryRecursive(Directory(srcPath), Directory(target));
    } else {
      await File(srcPath).copy(target);
    }
    onDone?.call();
    if (!silent && context.mounted) {
      showGlobalToast(context, '已复制到目标', overlay: overlay);
    }
    return target;
  } catch (e) {
    if (!silent) _showError(context, '${move ? "移动" : "复制"}失败：$e');
    return null;
  }
}

/// 粘贴剪切板：复制模式拷贝到 [destDir]；剪切模式移动到 [destDir]。
Future<String?> pasteClipboardEntry(
  BuildContext context,
  ProviderContainer container, {
  required String destDir,
  VoidCallback? onDone,
  OverlayState? overlay,
}) async {
  final entry = container.read(fsClipboardProvider);
  if (entry == null || entry.items.isEmpty) return null;

  var ok = 0;
  String? last;
  for (final item in entry.items) {
    final exists = item.isDir
        ? await Directory(item.path).exists()
        : await File(item.path).exists();
    if (!exists) continue;
    final result = await relocateEntity(
      context,
      container,
      srcPath: item.path,
      isDir: item.isDir,
      destDir: destDir,
      move: entry.isCut,
      onDone: null,
      overlay: overlay,
      silent: entry.items.length > 1,
    );
    if (result != null) {
      ok++;
      last = result;
    }
  }
  if (ok > 0) {
    if (entry.isCut) {
      container.read(fsClipboardProvider.notifier).state = null;
    }
    onDone?.call();
    if (context.mounted) {
      final tip = entry.isCut
          ? (ok == 1 ? '已移动' : '已移动 $ok 项')
          : (ok == 1 ? '已粘贴' : '已粘贴 $ok 项');
      showGlobalToast(context, tip, overlay: overlay);
    }
  } else {
    container.read(fsClipboardProvider.notifier).state = null;
    _showError(context, entry.isCut ? '剪切项已不存在' : '复制项已不存在');
  }
  return last;
}

/// 批量删除（一次确认）。
Future<bool> deleteEntitiesDialog(
  BuildContext context, {
  required List<FsClipboardItem> items,
  VoidCallback? onDone,
}) async {
  if (items.isEmpty) return false;
  if (items.length == 1) {
    return deleteEntityDialog(
      context,
      path: items.first.path,
      isDir: items.first.isDir,
      onDone: onDone,
    );
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除确认', style: TextStyle(fontSize: 15)),
      content: Text(
        '删除选中的 ${items.length} 项？此操作不可恢复。',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red[800]),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  var failed = 0;
  for (final item in items) {
    try {
      if (item.isDir) {
        await Directory(item.path).delete(recursive: true);
      } else {
        await File(item.path).delete();
      }
    } catch (_) {
      failed++;
    }
  }
  onDone?.call();
  if (failed > 0 && context.mounted) {
    _showError(context, '有 $failed 项删除失败');
  }
  return failed < items.length;
}

/// 将系统拖入的路径复制到 [destDir]（文件直接拷贝；文件夹递归拷贝）。
Future<int> importDroppedPaths(
  BuildContext context, {
  required String destDir,
  required List<String> paths,
  VoidCallback? onDone,
  OverlayState? overlay,
}) async {
  if (paths.isEmpty) return 0;
  if (!await Directory(destDir).exists()) {
    _showError(context, '目标目录不存在');
    return 0;
  }
  var ok = 0;
  for (final src in paths) {
    try {
      final name = p.basename(src);
      final isDir = await Directory(src).exists();
      if (!isDir && !await File(src).exists()) continue;
      if (isDir) {
        final srcNorm = p.normalize(src);
        final destNorm = p.normalize(destDir);
        if (p.equals(srcNorm, destNorm) || p.isWithin(srcNorm, destNorm)) {
          continue;
        }
      }
      var target = p.join(destDir, name);
      if (await File(target).exists() || await Directory(target).exists()) {
        target = _uniqueSiblingPath(destDir, name, isDir: isDir);
      }
      if (isDir) {
        await _copyDirectoryRecursive(Directory(src), Directory(target));
      } else {
        await File(src).copy(target);
      }
      ok++;
    } catch (_) {}
  }
  if (ok > 0) {
    onDone?.call();
    if (context.mounted) {
      showGlobalToast(context, '已导入 $ok 项', overlay: overlay);
    }
  }
  return ok;
}

/// 重命名文件/目录。成功返回新路径。
Future<String?> renameEntityDialog(
  BuildContext context, {
  required String path,
  required bool isDir,
  VoidCallback? onDone,
}) async {
  final entity = isDir ? Directory(path) : File(path);
  final oldName = p.basename(path);
  final newName = await promptTextDialog(
    context,
    title: '重命名${isDir ? "文件夹" : "文件"}',
    label: '',
    initial: oldName,
  );
  if (newName == null || newName.trim().isEmpty || newName == oldName) {
    return null;
  }
  final target = p.join(p.dirname(path), newName.trim());
  try {
    await entity.rename(target);
  } catch (e) {
    _showError(context, '重命名失败：$e');
    return null;
  }
  onDone?.call();
  return target;
}

/// 复制文件（自动避重名）。成功返回新路径。
Future<String?> duplicateFileDialog(
  BuildContext context, {
  required String path,
  VoidCallback? onDone,
}) async {
  final file = File(path);
  final name = p.basename(path);
  final target = _uniqueSiblingPath(file.parent.path, name, isDir: false);
  try {
    await file.copy(target);
  } catch (e) {
    _showError(context, '复制失败：$e');
    return null;
  }
  onDone?.call();
  return target;
}

Future<void> _copyDirectoryRecursive(Directory src, Directory dest) async {
  await dest.create(recursive: true);
  await for (final entity in src.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      await _copyDirectoryRecursive(entity, Directory(p.join(dest.path, name)));
    } else if (entity is File) {
      await entity.copy(p.join(dest.path, name));
    }
  }
}

/// 复制文件夹（同级 `_copy`，自动避重名）。成功返回新路径。
Future<String?> duplicateFolderDialog(
  BuildContext context, {
  required String path,
  VoidCallback? onDone,
}) async {
  final src = Directory(path);
  if (!await src.exists()) {
    _showError(context, '文件夹不存在');
    return null;
  }
  final name = p.basename(path);
  final target = _uniqueSiblingPath(p.dirname(path), name, isDir: true);
  try {
    await _copyDirectoryRecursive(src, Directory(target));
  } catch (e) {
    _showError(context, '复制失败：$e');
    return null;
  }
  onDone?.call();
  return target;
}

/// 删除文件/目录（带确认）。成功返回 true。
Future<bool> deleteEntityDialog(
  BuildContext context, {
  required String path,
  required bool isDir,
  VoidCallback? onDone,
}) async {
  final name = p.basename(path);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除确认', style: TextStyle(fontSize: 15)),
      content: Text(
        isDir
            ? '删除文件夹“$name”及其全部内容？此操作不可恢复。'
            : '删除文件“$name”？此操作不可恢复。',
        style: const TextStyle(fontSize: 13),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red[800]),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  try {
    if (isDir) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
  } catch (e) {
    _showError(context, '删除失败：$e');
    return false;
  }
  onDone?.call();
  return true;
}

/// 新建子目录。成功返回新路径。
Future<String?> newFolderDialog(
  BuildContext context, {
  required String parentDir,
  VoidCallback? onDone,
}) async {
  final name = await promptTextDialog(
    context,
    title: '新建文件夹',
    label: '文件夹名称：',
  );
  if (name == null || name.trim().isEmpty) return null;
  final target = p.join(parentDir, name.trim());
  try {
    await Directory(target).create(recursive: true);
  } catch (e) {
    _showError(context, '创建失败：$e');
    return null;
  }
  onDone?.call();
  return target;
}

/// 在 [parentDir] 下新建空文档。未写扩展名时默认 `.md`。成功返回新路径。
Future<String?> newDocumentDialog(
  BuildContext context, {
  required String parentDir,
  VoidCallback? onDone,
}) async {
  final name = await promptTextDialog(
    context,
    title: '新建文档',
    label: '文件名（可省略 .md）：',
  );
  if (name == null || name.trim().isEmpty) return null;
  var fileName = name.trim();
  // 禁止路径分隔符，避免越出目标目录。
  if (fileName.contains('/') ||
      fileName.contains('\\') ||
      fileName.contains('..')) {
    _showError(context, '文件名不能包含路径');
    return null;
  }
  if (!fileName.contains('.')) {
    fileName = '$fileName.md';
  }
  final target = p.join(parentDir, fileName);
  if (await File(target).exists()) {
    _showError(context, '已存在同名文件：$fileName');
    return null;
  }
  try {
    await File(target).create(recursive: true);
  } catch (e) {
    _showError(context, '创建失败：$e');
    return null;
  }
  onDone?.call();
  return target;
}

/// 导入物料到 [dir]（系统多选复制）。返回成功数量。
Future<int> importFilesToDir(
  BuildContext context, {
  required String dir,
  VoidCallback? onDone,
}) async {
  const any = XTypeGroup(label: '所有文件');
  final paths = await openFiles(acceptedTypeGroups: const [any]);
  if (paths.isEmpty) return 0;
  var ok = 0;
  for (final src in paths) {
    try {
      final dest = p.join(dir, src.name);
      await src.saveTo(dest);
      ok++;
    } catch (_) {}
  }
  if (ok > 0) onDone?.call();
  if (ok < paths.length && context.mounted) {
    _showError(context, '部分文件导入失败（成功 $ok / ${paths.length}）');
  } else if (ok > 0 && context.mounted) {
    showGlobalToast(context, '已导入 $ok 个文件');
  }
  return ok;
}

Future<int> _dirByteSize(Directory dir) async {
  var total = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          total += await e.length();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return total;
}

String _formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

String _formatTime(DateTime? t) {
  if (t == null) return '—';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 显示文件/文件夹属性。
Future<void> showEntityPropertiesDialog(
  BuildContext context, {
  required String path,
  required bool isDir,
}) async {
  var typeLabel = isDir ? '文件夹' : '文件';
  int? size;
  DateTime? modified;
  DateTime? created;
  try {
    if (isDir) {
      final d = Directory(path);
      final st = await d.stat();
      modified = st.modified;
      created = st.changed;
      size = await _dirByteSize(d);
    } else {
      final f = File(path);
      final st = await f.stat();
      modified = st.modified;
      created = st.changed;
      size = await f.length();
      final ext = p.extension(path);
      if (ext.isNotEmpty) typeLabel = '文件（$ext）';
    }
  } catch (e) {
    if (context.mounted) _showError(context, '读取属性失败：$e');
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('属性', style: TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _propRow('名称', p.basename(path)),
            _propRow('类型', typeLabel),
            _propRow('大小', size == null ? '—' : _formatBytes(size)),
            _propRow('修改时间', _formatTime(modified)),
            _propRow('创建/变更', _formatTime(created)),
            _propRow('位置', p.dirname(path)),
            _propRow('完整路径', path),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: path));
            Navigator.pop(ctx);
          },
          child: const Text('复制路径'),
        ),
      ],
    ),
  );
}

Widget _propRow(String k, String v) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            k,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
        ),
        Expanded(
          child: SelectableText(v, style: const TextStyle(fontSize: 12)),
        ),
      ],
    ),
  );
}

/// 设置创作进度状态（记录到进度 provider + SharedPreferences）。
Future<void> setProgressDialog(
  BuildContext context,
  ProviderContainer container, {
  required String path,
  required String displayName,
  VoidCallback? onDone,
}) async {
  final current =
      container.read(episodeStatusesProvider)[path] ?? EpisodeStatus.notStarted;
  final selected = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('设置创作进度 — $displayName',
          style: const TextStyle(fontSize: 15)),
      children: [
        for (final s in EpisodeStatus.all)
          ListTile(
            dense: true,
            leading: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(EpisodeStatus.colors[s] ?? 0xFF9E9E9E),
              ),
            ),
            title: Text(s, style: const TextStyle(fontSize: 13)),
            trailing: s == current
                ? const Icon(Icons.check, size: 18, color: Colors.teal)
                : null,
            onTap: () => Navigator.pop(ctx, s),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Center(
            child: TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('取消'),
            ),
          ),
        ),
      ],
    ),
  );
  if (selected == null || selected == current) return;
  container.read(episodeStatusesProvider.notifier).state = {
    ...container.read(episodeStatusesProvider),
    path: selected,
  };
  await saveEpisodeStatus(path, selected);
  onDone?.call();
}

void _showError(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg, style: const TextStyle(fontSize: 12)),
    duration: const Duration(seconds: 3),
  ));
}
