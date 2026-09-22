import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 最近项目条目（路径 + 最近打开时间）。
class ProjectEntry {
  final String path;
  final DateTime lastOpenedAt;

  const ProjectEntry({
    required this.path,
    required this.lastOpenedAt,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'lastOpenedAt': lastOpenedAt.toUtc().toIso8601String(),
      };

  factory ProjectEntry.fromJson(Map<String, dynamic> json) {
    final raw = json['lastOpenedAt']?.toString();
    DateTime at;
    try {
      at = raw == null || raw.isEmpty
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : DateTime.parse(raw).toUtc();
    } catch (_) {
      at = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    return ProjectEntry(
      path: (json['path'] as String? ?? '').trim(),
      lastOpenedAt: at,
    );
  }

  bool get exists {
    final p = path.trim();
    if (p.isEmpty) return false;
    try {
      return Directory(p).existsSync();
    } catch (_) {
      return false;
    }
  }
}

/// 本机「最近项目」索引（全局一份，不按根隔离）。
class ProjectRegistry {
  ProjectRegistry._();
  static final ProjectRegistry instance = ProjectRegistry._();

  static const _prefsKey = 'project_registry_v1';
  static const maxEntries = 20;

  List<ProjectEntry>? _cache;

  Future<List<ProjectEntry>> list() async {
    await _ensureLoaded();
    return List.unmodifiable(_cache!);
  }

  /// 打开或切换成功后调用：置顶并截断上限。
  Future<List<ProjectEntry>> touch(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return list();
    await _ensureLoaded();
    final key = prefsRootKey(trimmed);
    final now = DateTime.now().toUtc();
    final next = <ProjectEntry>[
      ProjectEntry(path: trimmed, lastOpenedAt: now),
      for (final e in _cache!)
        if (prefsRootKey(e.path) != key) e,
    ];
    if (next.length > maxEntries) {
      next.removeRange(maxEntries, next.length);
    }
    _cache = next;
    await _persist();
    return list();
  }

  /// 仅移出列表，不删该根下的 workspace / bindings 等桶。
  Future<List<ProjectEntry>> remove(String path) async {
    await _ensureLoaded();
    final key = prefsRootKey(path);
    _cache = [
      for (final e in _cache!)
        if (prefsRootKey(e.path) != key) e,
    ];
    await _persist();
    return list();
  }

  /// 目录不存在的项移出列表。返回被移除条数。
  Future<int> pruneMissing() async {
    await _ensureLoaded();
    final before = _cache!.length;
    _cache = [for (final e in _cache!) if (e.exists) e];
    final removed = before - _cache!.length;
    if (removed > 0) await _persist();
    return removed;
  }

  /// 列表为空且当前根非空时，把当前根记入（升级迁移）。
  Future<void> migrateCurrentRootIfEmpty() async {
    await _ensureLoaded();
    if (_cache!.isNotEmpty) return;
    final root = AppConfig.instance.projectRoot.trim();
    if (root.isEmpty) return;
    await touch(root);
  }

  Future<void> _ensureLoaded() async {
    if (_cache != null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final items = <ProjectEntry>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is! Map) continue;
            final e = ProjectEntry.fromJson(Map<String, dynamic>.from(item));
            if (e.path.isEmpty) continue;
            items.add(e);
          }
        }
      } catch (_) {}
    }
    // 同根去重，保留较新的 lastOpenedAt。
    final byKey = <String, ProjectEntry>{};
    for (final e in items) {
      final k = prefsRootKey(e.path);
      final prev = byKey[k];
      if (prev == null || e.lastOpenedAt.isAfter(prev.lastOpenedAt)) {
        byKey[k] = e;
      }
    }
    final merged = byKey.values.toList()
      ..sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    if (merged.length > maxEntries) {
      merged.removeRange(maxEntries, merged.length);
    }
    _cache = merged;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode([for (final e in _cache!) e.toJson()]),
    );
  }
}
