import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 单个 Shell Tab 的会话快照（一期：结构 + 启动命令，不含滚动缓冲）。
class ShellTabSnapshot {
  /// shell | agent
  final String kind;
  final String? cwd;
  final String? launchCommand;
  final String? agentHint;

  const ShellTabSnapshot({
    this.kind = 'shell',
    this.cwd,
    this.launchCommand,
    this.agentHint,
  });

  bool get isAgent => kind == 'agent' || (agentHint != null && agentHint!.isNotEmpty);

  Map<String, dynamic> toJson() => {
        'kind': kind,
        if (cwd != null) 'cwd': cwd,
        if (launchCommand != null) 'launchCommand': launchCommand,
        if (agentHint != null) 'agentHint': agentHint,
      };

  factory ShellTabSnapshot.fromJson(Map<String, dynamic> json) {
    return ShellTabSnapshot(
      kind: json['kind'] as String? ?? 'shell',
      cwd: json['cwd'] as String?,
      launchCommand: json['launchCommand'] as String?,
      agentHint: json['agentHint'] as String?,
    );
  }
}

/// 某一项目下的右侧 Shell 工作台快照。
class ShellSessionSnapshot {
  final String projectRoot;
  final List<ShellTabSnapshot> tabs;
  final int activeIndex;
  final bool shellVisible;

  const ShellSessionSnapshot({
    this.projectRoot = '',
    this.tabs = const [],
    this.activeIndex = 0,
    this.shellVisible = true,
  });

  Map<String, dynamic> toJson() => {
        'projectRoot': projectRoot,
        'tabs': tabs.map((e) => e.toJson()).toList(),
        'activeIndex': activeIndex,
        'shellVisible': shellVisible,
      };

  factory ShellSessionSnapshot.fromJson(Map<String, dynamic> json) {
    final rawTabs = json['tabs'];
    final tabs = <ShellTabSnapshot>[];
    if (rawTabs is List) {
      for (final e in rawTabs) {
        if (e is Map<String, dynamic>) {
          tabs.add(ShellTabSnapshot.fromJson(e));
        } else if (e is Map) {
          tabs.add(ShellTabSnapshot.fromJson(
            e.map((k, v) => MapEntry(k.toString(), v)),
          ));
        }
      }
    }
    return ShellSessionSnapshot(
      projectRoot: json['projectRoot'] as String? ?? '',
      tabs: tabs,
      activeIndex: (json['activeIndex'] as num?)?.toInt() ?? 0,
      shellVisible: json['shellVisible'] as bool? ?? true,
    );
  }

  ShellSessionSnapshot sanitized() {
    final root = projectRoot.isNotEmpty
        ? projectRoot
        : AppConfig.instance.projectRoot;
    final cleaned = <ShellTabSnapshot>[];
    for (final t in tabs) {
      var cwd = t.cwd;
      if (cwd != null && cwd.isNotEmpty) {
        try {
          if (!Directory(cwd).existsSync()) {
            cwd = root.isNotEmpty ? root : null;
          }
        } catch (_) {
          cwd = root.isNotEmpty ? root : null;
        }
      } else if (root.isNotEmpty) {
        cwd = root;
      }
      cleaned.add(ShellTabSnapshot(
        kind: t.isAgent ? 'agent' : 'shell',
        cwd: cwd,
        launchCommand: t.launchCommand,
        agentHint: t.agentHint,
      ));
    }
    if (cleaned.isEmpty) {
      return ShellSessionSnapshot(
        projectRoot: root,
        tabs: const [],
        activeIndex: 0,
        shellVisible: shellVisible,
      );
    }
    final ai = activeIndex.clamp(0, cleaned.length - 1);
    return ShellSessionSnapshot(
      projectRoot: root,
      tabs: cleaned,
      activeIndex: ai,
      shellVisible: shellVisible,
    );
  }
}

/// 按项目根持久化 Shell 会话（一期）。
class ShellSessionMemory {
  ShellSessionMemory._();
  static final ShellSessionMemory instance = ShellSessionMemory._();

  static const _prefsKey = 'shell_sessions_v1';
  Timer? _debounce;

  String _mapKey(String projectRoot) {
    final root = projectRoot.trim().isEmpty
        ? '_default'
        : projectRoot.replaceAll('/', Platform.pathSeparator).toLowerCase();
    return root;
  }

  Future<Map<String, dynamic>> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw);
      if (map is Map<String, dynamic>) return map;
      if (map is Map) {
        return map.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return {};
  }

  Future<ShellSessionSnapshot> loadFor(String projectRoot) async {
    final all = await _loadAll();
    final key = _mapKey(projectRoot);
    final raw = all[key];
    if (raw is! Map) {
      return ShellSessionSnapshot(projectRoot: projectRoot);
    }
    try {
      final map = raw is Map<String, dynamic>
          ? raw
          : raw.map((k, v) => MapEntry(k.toString(), v));
      return ShellSessionSnapshot.fromJson(
        map.map((k, v) => MapEntry(k.toString(), v)),
      ).sanitized().withProjectRoot(projectRoot);
    } catch (_) {
      return ShellSessionSnapshot(projectRoot: projectRoot);
    }
  }

  Future<void> saveNow(ShellSessionSnapshot snap) async {
    _debounce?.cancel();
    final cleaned = snap.sanitized();
    final all = await _loadAll();
    all[_mapKey(cleaned.projectRoot)] = cleaned.toJson();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(all));
  }

  void scheduleSave(ShellSessionSnapshot snap) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      saveNow(snap);
    });
  }
}

extension ShellSessionSnapshotX on ShellSessionSnapshot {
  ShellSessionSnapshot withProjectRoot(String root) => ShellSessionSnapshot(
        projectRoot: root,
        tabs: tabs,
        activeIndex: activeIndex,
        shellVisible: shellVisible,
      );
}
