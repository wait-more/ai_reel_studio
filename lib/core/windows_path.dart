import 'dart:convert';
import 'dart:io';

/// Windows / UNC 路径归一与盘符映射（工作区、OpenCode 会话等共用）。
///
/// 典型问题：项目根是 `\\nas\share\proj`，导航路径却是 `Z:\proj\...`，
/// 字面 `startsWith` 会误判「不在项目下」，把记忆目录清掉。

/// 统一路径形态，便于比对。
String normalizeComparablePath(String path) {
  var p = path.trim().replaceAll('\\', '/');
  if (p.isEmpty) return '';
  // 保留 UNC 前缀 //host/...，其余压缩重复斜杠。
  if (p.startsWith('//')) {
    p = '//${p.substring(2).replaceAll(RegExp(r'/+'), '/')}';
  } else {
    p = p.replaceAll(RegExp(r'/+'), '/');
  }
  if (p.length > 3 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.toLowerCase();
}

/// UNC `//host/share/rest` → `share/rest`（忽略主机名/IP 差异）。
String? uncSharePath(String normalized) {
  if (!normalized.startsWith('//')) return null;
  final rest = normalized.substring(2);
  final slash = rest.indexOf('/');
  if (slash < 0 || slash + 1 >= rest.length) return null;
  return rest.substring(slash + 1);
}

/// Windows 网络盘符 → UNC 根（如 `z:` → `//nas/share`）。
class WindowsDriveUncCache {
  WindowsDriveUncCache._();
  static final WindowsDriveUncCache instance = WindowsDriveUncCache._();

  final Map<String, String> _driveToUncRoot = {};
  Future<void>? _loading;
  DateTime? _loadedAt;

  Map<String, String> get snapshot => Map.unmodifiable(_driveToUncRoot);

  /// 测试或手动注入映射：`drive` 为 `z:`（小写，带冒号）。
  void debugSetMappings(Map<String, String> mappings) {
    _driveToUncRoot
      ..clear()
      ..addAll({
        for (final e in mappings.entries)
          e.key.trim().toLowerCase(): normalizeComparablePath(e.value),
      });
    _loadedAt = DateTime.now();
  }

  void clear() {
    _driveToUncRoot.clear();
    _loadedAt = null;
  }

  Future<void> refresh({bool force = false}) {
    if (!Platform.isWindows) return Future.value();
    final loadedAt = _loadedAt;
    if (!force &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) < const Duration(minutes: 2) &&
        _driveToUncRoot.isNotEmpty) {
      return Future.value();
    }
    return _loading ??= _load().whenComplete(() => _loading = null);
  }

  Future<void> _load() async {
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NoLogo',
          '-Command',
          r'''
Get-CimInstance Win32_LogicalDisk |
  Where-Object { $_.DriveType -eq 4 -and $_.ProviderName } |
  ForEach-Object { "$($_.DeviceID)=$($_.ProviderName)" }
''',
        ],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return;
      final next = <String, String>{};
      for (final line in '${result.stdout}'.split(RegExp(r'\r?\n'))) {
        final t = line.trim();
        if (t.isEmpty) continue;
        final eq = t.indexOf('=');
        if (eq <= 0) continue;
        final drive = t.substring(0, eq).trim().toLowerCase();
        final unc = normalizeComparablePath(t.substring(eq + 1));
        if (RegExp(r'^[a-z]:$').hasMatch(drive) &&
            unc.startsWith('//') &&
            unc.length > 3) {
          next[drive] = unc;
        }
      }
      _driveToUncRoot
        ..clear()
        ..addAll(next);
      _loadedAt = DateTime.now();
    } catch (_) {
      // best-effort
    }
  }

  /// 把 `z:/foo` 展开为 `//server/share/foo`；非盘符路径原样返回 null。
  String? expandMappedDrive(String normalized) {
    final m = RegExp(r'^([a-z]):(/.*)?$').firstMatch(normalized);
    if (m == null) return null;
    final root = _driveToUncRoot['${m.group(1)}:'];
    if (root == null || root.isEmpty) return null;
    final rest = m.group(2) ?? '';
    return normalizeComparablePath('$root$rest');
  }
}

String? _expandWithMappings(String normalized, Map<String, String> mappings) {
  final m = RegExp(r'^([a-z]):(/.*)?$').firstMatch(normalized);
  if (m == null) return null;
  final root = mappings['${m.group(1)}:'];
  if (root == null || root.isEmpty) return null;
  final rest = m.group(2) ?? '';
  return normalizeComparablePath('$root$rest');
}

/// 生成路径别名集合（含盘符展开、UNC share 形态）。
Set<String> pathAliases(
  String path, {
  Map<String, String>? driveUncMappings,
}) {
  final out = <String>{};
  final n = normalizeComparablePath(path);
  if (n.isEmpty) return out;
  out.add(n);

  final expanded = driveUncMappings == null
      ? WindowsDriveUncCache.instance.expandMappedDrive(n)
      : _expandWithMappings(n, driveUncMappings);
  if (expanded != null && expanded.isNotEmpty) {
    out.add(expanded);
  }

  for (final alias in List<String>.of(out)) {
    final share = uncSharePath(alias);
    if (share != null && share.isNotEmpty) {
      out.add('share:$share');
    }
  }
  return out;
}

bool pathsEquivalent(
  String? a,
  String? b, {
  Map<String, String>? driveUncMappings,
}) {
  if (a == null || b == null) return false;
  final aliasesA = pathAliases(a, driveUncMappings: driveUncMappings);
  final aliasesB = pathAliases(b, driveUncMappings: driveUncMappings);
  if (aliasesA.isEmpty || aliasesB.isEmpty) return false;
  return aliasesA.any(aliasesB.contains);
}

/// [path] 是否位于 [root] 之下（含自身；兼容 Z: ↔ UNC）。
bool isPathUnderRoot(
  String path,
  String root, {
  Map<String, String>? driveUncMappings,
}) {
  if (root.isEmpty) return true;

  String localNorm(String s) {
    var n = s.trim().replaceAll('/', Platform.pathSeparator);
    while (n.length > 3 && n.endsWith(Platform.pathSeparator)) {
      n = n.substring(0, n.length - 1);
    }
    return n.toLowerCase();
  }

  bool prefixOf(String pathN, String rootN) {
    if (pathN == rootN) return true;
    final sep = Platform.pathSeparator;
    return pathN.startsWith('$rootN$sep');
  }

  final nRoot = localNorm(root);
  final nPath = localNorm(path);
  if (prefixOf(nPath, nRoot)) return true;

  try {
    final absRoot = localNorm(Directory(root).absolute.path);
    final absPath = localNorm(Directory(path).absolute.path);
    if (prefixOf(absPath, absRoot)) return true;
  } catch (_) {}

  if (!Platform.isWindows) return false;

  final rootAliases = pathAliases(root, driveUncMappings: driveUncMappings);
  final pathAliasesSet = pathAliases(path, driveUncMappings: driveUncMappings);
  for (final ra in rootAliases) {
    for (final pa in pathAliasesSet) {
      if (pa == ra || pa.startsWith('$ra/')) return true;
    }
  }
  return false;
}
