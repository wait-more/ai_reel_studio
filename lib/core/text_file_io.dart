import 'dart:io';

import 'windows_path.dart';

/// 项目文档等文本写入。
///
/// 默认一次 [File.writeAsString]（与改前相同）。不在每次保存时跑盘符探测。
/// 仅拒绝访问时：清只读 → 再写 → 临时替换 → 再刷盘符缓存试 UNC。
Future<void> writeTextFileReliable(String path, String contents) async {
  final target = path.trim();
  if (target.isEmpty) {
    throw ArgumentError('path is empty');
  }

  // 热路径：直接写，零额外 IPC / PowerShell。
  try {
    await _writeTextFileOnce(target, contents);
    return;
  } catch (e) {
    if (!_isAccessDenied(e) &&
        e is! PathAccessException &&
        e is! FileSystemException) {
      rethrow;
    }
  }

  Object? lastError;
  if (Platform.isWindows) {
    await WindowsDriveUncCache.instance.refresh();
  }

  for (final candidate in _writePathCandidates(target)) {
    try {
      await _writeTextFileOnce(candidate, contents, allowFallback: true);
      return;
    } catch (e) {
      lastError = e;
      if (!_isAccessDenied(e) &&
          e is! PathAccessException &&
          e is! FileSystemException) {
        rethrow;
      }
    }
  }

  throw StateError(_friendlyWriteError(target, lastError));
}

List<String> _writePathCandidates(String path) {
  final out = <String>[];
  void add(String? raw) {
    final t = raw?.trim() ?? '';
    if (t.isEmpty) return;
    final native = Platform.isWindows ? toNativeFilesystemPath(t) : t;
    if (out.any(
      (e) => normalizeComparablePath(e) == normalizeComparablePath(native),
    )) {
      return;
    }
    out.add(native);
  }

  add(path);
  if (Platform.isWindows) {
    final unc = WindowsDriveUncCache.instance.expandMappedDrive(
      normalizeComparablePath(path),
    );
    add(unc);
  }
  return out;
}

Future<void> _writeTextFileOnce(
  String path,
  String contents, {
  bool allowFallback = false,
}) async {
  final file = File(path);
  final parent = file.parent;
  if (!await parent.exists()) {
    await parent.create(recursive: true);
  }

  try {
    await file.writeAsString(contents, flush: true);
    return;
  } catch (e) {
    if (!allowFallback || !_isAccessDenied(e)) rethrow;
  }

  if (Platform.isWindows) {
    await _clearReadOnlyAttribute(path);
  }
  try {
    await file.writeAsString(contents, flush: true);
    return;
  } catch (e) {
    if (!_isAccessDenied(e)) rethrow;
  }

  await _writeViaTempReplace(file, contents);
}

Future<void> _writeViaTempReplace(File file, String contents) async {
  final path = file.path;
  final tmp = File('$path.aireel-saving');
  final bak = File('$path.aireel-bak');
  try {
    if (await tmp.exists()) {
      await tmp.delete();
    }
    await tmp.writeAsString(contents, flush: true);

    if (Platform.isWindows) {
      await _clearReadOnlyAttribute(path);
    }

    if (await bak.exists()) {
      await bak.delete();
    }
    if (await file.exists()) {
      await file.rename(bak.path);
    }
    try {
      await tmp.rename(path);
    } catch (_) {
      if (Platform.isWindows) {
        final moved = await Process.run('cmd', [
          '/c',
          'move /Y "${tmp.path}" "$path"',
        ]);
        if (moved.exitCode != 0) {
          throw FileSystemException(
            'temp replace failed',
            path,
            OSError('${moved.stderr}${moved.stdout}'.trim(), 5),
          );
        }
      } else {
        rethrow;
      }
    }
    if (await bak.exists()) {
      try {
        await bak.delete();
      } catch (_) {}
    }
  } catch (e) {
    if (!await file.exists() && await bak.exists()) {
      try {
        await bak.rename(path);
      } catch (_) {}
    }
    rethrow;
  } finally {
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }
}

Future<void> _clearReadOnlyAttribute(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return;
    await Process.run('attrib', ['-R', path], runInShell: false);
  } catch (_) {}
}

bool _isAccessDenied(Object error) {
  final text = '$error'.toLowerCase();
  if (text.contains('拒绝访问') ||
      text.contains('access is denied') ||
      text.contains('access denied') ||
      text.contains('errno = 5') ||
      text.contains('errno=5') ||
      text.contains('os error: 5')) {
    return true;
  }
  if (error is PathAccessException) return true;
  if (error is FileSystemException) {
    final os = error.osError;
    if (os != null && os.errorCode == 5) return true;
  }
  return false;
}

String _friendlyWriteError(String path, Object? cause) {
  final detail = '$cause'.replaceFirst(RegExp(r'^Bad state:\s*'), '').trim();
  if (_isAccessDenied(cause ?? '')) {
    return '无法写入文件（拒绝访问）：$path\n'
        '请检查网络盘是否可写、文件是否只读，或是否被其他程序占用。';
  }
  if (detail.isEmpty) return '无法写入文件：$path';
  return '无法写入文件：$path\n$detail';
}
