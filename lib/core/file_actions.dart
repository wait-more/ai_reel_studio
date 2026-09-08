import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'progress.dart';
import 'providers.dart';

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

/// 重命名文件/目录。成功返回新路径。
Future<String?> renameEntityDialog(
  BuildContext context, {
  required String path,
  required bool isDir,
  VoidCallback? onDone,
}) async {
  final entity = isDir ? Directory(path) : File(path);
  final oldName = path.split(Platform.pathSeparator).last;
  final newName = await promptTextDialog(
    context,
    title: '重命名${isDir ? "文件夹" : "文件"}',
    label: '',
    initial: oldName,
  );
  if (newName == null || newName.trim().isEmpty || newName == oldName) {
    return null;
  }
  final parent = Directory(path).parent.path;
  final target = '$parent${Platform.pathSeparator}${newName.trim()}';
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
  final name = path.split(Platform.pathSeparator).last;
  final ext = name.contains('.') ? name.substring(name.lastIndexOf('.')) : '';
  final base =
      ext.isEmpty ? name : name.substring(0, name.length - ext.length);
  var target =
      '${file.parent.path}${Platform.pathSeparator}${base}_copy$ext';
  var i = 2;
  while (await File(target).exists()) {
    target =
        '${file.parent.path}${Platform.pathSeparator}${base}_copy$i$ext';
    i++;
  }
  try {
    await file.copy(target);
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
  final name = path.split(Platform.pathSeparator).last;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除确认', style: TextStyle(fontSize: 15)),
      content: Text(
        isDir ? '删除文件夹“$name”及其全部内容？此操作不可恢复。'
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
  final target = '$parentDir${Platform.pathSeparator}${name.trim()}';
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
  final target = '$parentDir${Platform.pathSeparator}$fileName';
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