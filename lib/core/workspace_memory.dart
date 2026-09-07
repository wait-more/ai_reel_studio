import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

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
  final String? selectedFile;
  final String? selectedDir;
  final String contentMode;
  /// 路径 → 光标/滚动位置
  final Map<String, EditorViewState> fileViews;

  const WorkspaceSnapshot({
    this.expandedPaths = const [],
    this.openTabs = const [],
    this.selectedFile,
    this.selectedDir,
    this.contentMode = 'editor',
    this.fileViews = const {},
  });

  Map<String, dynamic> toJson() => {
        'expandedPaths': expandedPaths,
        'openTabs': openTabs,
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
      selectedFile: json['selectedFile'] as String?,
      selectedDir: json['selectedDir'] as String?,
      contentMode: (mode == 'assets' || mode == 'editor' || mode == 'comfy')
          ? mode
          : 'editor',
      fileViews: views,
    );
  }

  /// 丢弃不存在或不在当前项目根下的路径。
  WorkspaceSnapshot sanitized() {
    final root = AppConfig.instance.projectRoot;
    bool underRoot(String path) {
      if (root.isEmpty) return true;
      final nRoot = root.replaceAll('/', Platform.pathSeparator);
      final nPath = path.replaceAll('/', Platform.pathSeparator);
      return nPath.toLowerCase().startsWith(nRoot.toLowerCase());
    }

    bool alive(String path) {
      if (!underRoot(path)) return false;
      try {
        return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
      } catch (_) {
        return false;
      }
    }

    final tabs = openTabs.where(alive).toList();
    final file = (selectedFile != null && alive(selectedFile!))
        ? selectedFile
        : (tabs.isNotEmpty ? tabs.last : null);
    final dir = (selectedDir != null &&
            Directory(selectedDir!).existsSync() &&
            underRoot(selectedDir!))
        ? selectedDir
        : null;

    return WorkspaceSnapshot(
      expandedPaths: expandedPaths.where(alive).toList(),
      openTabs: tabs,
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

/// 工作区记忆：读写 SharedPreferences，变更去抖写入。
class WorkspaceMemory {
  WorkspaceMemory._();
  static final WorkspaceMemory instance = WorkspaceMemory._();

  static const _prefsKey = 'workspace_snapshot_v1';
  Timer? _debounce;

  Future<WorkspaceSnapshot> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return const WorkspaceSnapshot();
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return WorkspaceSnapshot.fromJson(map).sanitized();
    } catch (_) {
      return const WorkspaceSnapshot();
    }
  }

  /// 立刻写入（启动恢复后的首次、或关闭前可调用）。
  Future<void> saveNow(WorkspaceSnapshot snap) async {
    _debounce?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(snap.sanitized().toJson()),
    );
  }

  /// 去抖保存，避免连续点选狂写磁盘。
  void scheduleSave(WorkspaceSnapshot snap) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      saveNow(snap);
    });
  }
}
