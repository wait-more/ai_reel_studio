import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'windows_path.dart';

/// 单个文档的阅读/编辑位置。
class EditorViewState {
  final int caretOffset;
  final double scrollOffset;
  /// 非空选区（与 caret 独立记忆，失焦后仍可恢复）。
  final int? selectionBase;
  final int? selectionExtent;

  const EditorViewState({
    this.caretOffset = 0,
    this.scrollOffset = 0,
    this.selectionBase,
    this.selectionExtent,
  });

  bool get hasSelection {
    final a = selectionBase;
    final b = selectionExtent;
    return a != null && b != null && a != b;
  }

  Map<String, dynamic> toJson() => {
        'caret': caretOffset,
        'scroll': scrollOffset,
        if (selectionBase != null) 'selBase': selectionBase,
        if (selectionExtent != null) 'selExtent': selectionExtent,
      };

  factory EditorViewState.fromJson(Map<String, dynamic> json) {
    return EditorViewState(
      caretOffset: (json['caret'] as num?)?.toInt() ?? 0,
      scrollOffset: (json['scroll'] as num?)?.toDouble() ?? 0,
      selectionBase: (json['selBase'] as num?)?.toInt(),
      selectionExtent: (json['selExtent'] as num?)?.toInt(),
    );
  }
}

/// 工作区快照：目录树展开 + 中间栏（模式/Tabs/选中）+ 文档位置。
class WorkspaceSnapshot {
  final List<String> expandedPaths;
  final List<String> openTabs;
  /// Cursor 风格预览标签（斜体、可被替换）；须属于 [openTabs]。
  final String? previewTabPath;
  final String? selectedFile;
  final String? selectedDir;
  final String contentMode;
  /// 路径 → 光标/滚动位置
  final Map<String, EditorViewState> fileViews;

  const WorkspaceSnapshot({
    this.expandedPaths = const [],
    this.openTabs = const [],
    this.previewTabPath,
    this.selectedFile,
    this.selectedDir,
    this.contentMode = 'editor',
    this.fileViews = const {},
  });

  Map<String, dynamic> toJson() => {
        'expandedPaths': expandedPaths,
        'openTabs': openTabs,
        if (previewTabPath != null) 'previewTabPath': previewTabPath,
        'selectedFile': selectedFile,
        'selectedDir': selectedDir,
        'contentMode': contentMode,
        'fileViews': {
          for (final e in fileViews.entries) e.key: e.value.toJson(),
        },
      };

  factory WorkspaceSnapshot.fromJson(Map<String, dynamic> json) {
    List<String> asStringList(dynamic v) {
      if (v is! List) return const [];
      return v.whereType<String>().toList();
    }

    final mode = json['contentMode'] as String? ?? 'editor';
    final viewsRaw = json['fileViews'];
    final views = <String, EditorViewState>{};
    if (viewsRaw is Map) {
      for (final e in viewsRaw.entries) {
        final key = e.key;
        final val = e.value;
        if (key is! String) continue;
        if (val is Map<String, dynamic>) {
          views[key] = EditorViewState.fromJson(val);
        } else if (val is Map) {
          views[key] = EditorViewState.fromJson(
            val.map((k, v) => MapEntry(k.toString(), v)),
          );
        }
      }
    }

    return WorkspaceSnapshot(
      expandedPaths: asStringList(json['expandedPaths']),
      openTabs: asStringList(json['openTabs']),
      previewTabPath: json['previewTabPath'] as String?,
      selectedFile: json['selectedFile'] as String?,
      selectedDir: json['selectedDir'] as String?,
      contentMode: (mode == 'assets' || mode == 'editor' || mode == 'comfy')
          ? mode
          : 'editor',
      fileViews: views,
    );
  }

  /// 丢弃不存在或不在 [root] 下的路径；[root] 默认当前项目根。
  WorkspaceSnapshot sanitized({String? projectRoot}) {
    final root = (projectRoot ?? AppConfig.instance.projectRoot).trim();

    bool alive(String path) {
      if (!isPathUnderRoot(path, root)) return false;
      try {
        return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
      } catch (_) {
        return false;
      }
    }

    final tabs = openTabs.where(alive).toList();
    final preview = (previewTabPath != null &&
            tabs.contains(previewTabPath) &&
            alive(previewTabPath!))
        ? previewTabPath
        : null;
    final file = (selectedFile != null && alive(selectedFile!))
        ? selectedFile
        : (tabs.isNotEmpty ? tabs.last : null);
    var dir = (selectedDir != null &&
            Directory(selectedDir!).existsSync() &&
            isPathUnderRoot(selectedDir!, root))
        ? selectedDir
        : null;
    // 素材模式且目录丢失时，回落到项目根，避免启动后空白「请选择」
    if (dir == null &&
        contentMode == 'assets' &&
        root.isNotEmpty &&
        Directory(root).existsSync()) {
      dir = root;
    }

    return WorkspaceSnapshot(
      expandedPaths: expandedPaths.where(alive).toList(),
      openTabs: tabs,
      previewTabPath: preview,
      selectedFile: file,
      selectedDir: dir,
      contentMode: contentMode,
      fileViews: {
        for (final e in fileViews.entries)
          if (alive(e.key)) e.key: e.value,
      },
    );
  }
}

/// 工作区记忆：按项目根分桶读写 SharedPreferences，变更去抖写入。
class WorkspaceMemory {
  WorkspaceMemory._();
  static final WorkspaceMemory instance = WorkspaceMemory._();

  /// 旧版全局单 key；首次按根加载时迁到当前根并删除。
  static const _legacyPrefsKey = 'workspace_snapshot_v1';
  static const _prefsKeyPrefix = 'workspace_snapshot_v1:';
  Timer? _debounce;

  String _keyFor(String projectRoot) =>
      '$_prefsKeyPrefix${prefsRootKey(projectRoot)}';

  Future<WorkspaceSnapshot> load({String? projectRoot}) async {
    final root =
        (projectRoot ?? AppConfig.instance.projectRoot).trim();
    final prefs = await SharedPreferences.getInstance();
    final key = _keyFor(root);
    var raw = prefs.getString(key);
    if ((raw == null || raw.isEmpty) && root.isNotEmpty) {
      final legacy = prefs.getString(_legacyPrefsKey);
      if (legacy != null && legacy.isNotEmpty) {
        await prefs.setString(key, legacy);
        await prefs.remove(_legacyPrefsKey);
        raw = legacy;
      }
    }
    if (raw == null || raw.isEmpty) return const WorkspaceSnapshot();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return WorkspaceSnapshot.fromJson(map).sanitized(projectRoot: root);
    } catch (_) {
      return const WorkspaceSnapshot();
    }
  }

  /// 立刻写入（启动恢复后的首次、或关闭前 / 换根前可调用）。
  Future<void> saveNow(
    WorkspaceSnapshot snap, {
    String? projectRoot,
  }) async {
    _debounce?.cancel();
    final root =
        (projectRoot ?? AppConfig.instance.projectRoot).trim();
    if (root.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyFor(root),
      jsonEncode(snap.sanitized(projectRoot: root).toJson()),
    );
  }

  /// 去抖保存，避免连续点选狂写磁盘。
  void scheduleSave(WorkspaceSnapshot snap, {String? projectRoot}) {
    final root =
        (projectRoot ?? AppConfig.instance.projectRoot).trim();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      saveNow(snap, projectRoot: root);
    });
  }
}
