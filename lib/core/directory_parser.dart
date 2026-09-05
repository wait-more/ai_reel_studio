import 'dart:io';

class ScriptNode {
  final String name;
  final String path;
  final ScriptNodeType type;
  List<ScriptNode> children;
  bool isExpanded;
  /// 子节点是否已实际加载。
  /// 为 false 表示该节点是一个"未展开的空壳"，展开时才触发热加载。
  bool isLoaded;

  ScriptNode({
    required this.name,
    required this.path,
    required this.type,
    this.children = const [],
    this.isExpanded = false,
    this.isLoaded = true,
  });
}

enum ScriptNodeType {
  script,    // 剧本根目录
  season,    // 季
  episode,   // 集
  folder,    // 普通文件夹（物料等）
  file,      // 文件
}

/// 目录解析器
///
/// 结构语义（基于路径深度，而非纯数字前缀）:
///
///   scripts/                            ← 项目根
///   └── 001_悬疑_最后一次通话/          ← script (剧本)
///       ├── 剧本.md 分镜.md             ← file
///       ├── 场景素材/ 角色定妆照/       ← folder (物料)
///       └── 剧集/                      ← folder (季容器, 特殊)
///           └── 1_觉醒/               ← season (季)
///               └── 01_猝死穿书/       ← episode (集)
///                   ├── 剧本.md        ← file
///                   └── 场景素材/       ← folder (物料)
class DirectoryParser {
  static final _numberedDirPattern = RegExp(r'^\d+[_\-－](.+)$');

  /// 季容器目录名（其子目录视为季）
  static const _seasonContainerNames = ['剧集', '季', 'seasons', 'S'];

  /// 异步解析项目根（不阻塞主线程）。
  /// 策略：完整构建结构树到"集"层级（script→season→episode），
  /// 所有物料文件夹（folder）只列出其直接子项并标记 isLoaded=false，
  /// 展开时才通过 [loadChildrenAsync] 热加载更深内容。
  static Future<ScriptNode> parseRootAsync(String rootPath) async {
    final root = Directory(rootPath);
    try {
      if (!await root.exists()) {
        return ScriptNode(
            name: 'scripts', path: rootPath, type: ScriptNodeType.folder);
      }

      final children = <ScriptNode>[];
      await for (final entry in root.list()) {
        if (entry is Directory) {
          children.add(
              await _parseDirectoryAsync(entry.path, Inherit.script));
        }
      }
      children.sort((a, b) => a.name.compareTo(b.name));

      return ScriptNode(
        name: 'scripts',
        path: rootPath,
        type: ScriptNodeType.folder,
        children: children,
        isLoaded: true,
      );
    } catch (_) {
      return ScriptNode(
          name: 'scripts', path: rootPath, type: ScriptNodeType.folder);
    }
  }

  /// 递归解析一个目录节点。
  /// 沿结构链（script→seasonContainer→season→episode）逐层深入并加载子节点；
  /// 一旦进入普通物料上下文（folder），只列直接子项并标记懒加载。
  static Future<ScriptNode> _parseDirectoryAsync(
      String dirPath, Inherit inherit) async {
    final dir = Directory(dirPath);
    final name = dirPath.split(Platform.pathSeparator).last;
    final type = _typeFor(dirPath, inherit);

    // 物料文件夹：浅层列一遍，子内容按需热加载
    final isShallow = inherit == Inherit.folder;
    final children = <ScriptNode>[];
    try {
      await for (final entry in dir.list()) {
        if (entry is Directory) {
          final childName =
              entry.path.split(Platform.pathSeparator).last;
          if (!isShallow) {
            // 结构链上：继续递归推断
            children.add(await _parseDirectoryAsync(
                entry.path, _childInherit(inherit, type, childName)));
          } else {
            // 物料夹：直接子目录建为懒加载壳
            children.add(ScriptNode(
              name: childName,
              path: entry.path,
              type: ScriptNodeType.folder,
              children: const [],
              isLoaded: false,
            ));
          }
        } else if (entry is File) {
          children.add(ScriptNode(
            name: entry.path.split(Platform.pathSeparator).last,
            path: entry.path,
            type: ScriptNodeType.file,
          ));
        }
      }
    } catch (_) {}

    children.sort((a, b) => _sortByTypeAndName(a, b));

    final node = ScriptNode(
      name: name,
      path: dirPath,
      type: type,
      children: children,
      // 本函数总是列出当前节点的直接子项（含懒加载壳），故视为已加载
      isLoaded: true,
    );
    return node;
  }

  /// 按需热加载任意目录节点的直接子节点。
  /// [node] 通常是一个 isLoaded=false 的物料文件夹。
  static Future<void> loadChildrenAsync(ScriptNode node) async {
    final dir = Directory(node.path);
    final children = <ScriptNode>[];
    try {
      await for (final entry in dir.list()) {
        if (entry is Directory) {
          children.add(ScriptNode(
            name: entry.path.split(Platform.pathSeparator).last,
            path: entry.path,
            type: ScriptNodeType.folder,
            children: const [],
            isLoaded: false,
          ));
        } else if (entry is File) {
          children.add(ScriptNode(
            name: entry.path.split(Platform.pathSeparator).last,
            path: entry.path,
            type: ScriptNodeType.file,
          ));
        }
      }
    } catch (_) {}

    children.sort((a, b) => _sortByTypeAndName(a, b));
    node
      ..children = children
      ..isLoaded = true;
  }

  static int _sortByTypeAndName(ScriptNode a, ScriptNode b) {
    if (a.type == ScriptNodeType.file && b.type != ScriptNodeType.file) return 1;
    if (a.type != ScriptNodeType.file && b.type == ScriptNodeType.file) return -1;
    return a.name.compareTo(b.name);
  }

  /// 根据继承上下文推断目录类型
  static ScriptNodeType _typeFor(String dirPath, Inherit inherit) {
    final name = dirPath.split(Platform.pathSeparator).last;

    switch (inherit) {
      // scripts/ 下直接子目录 = 剧本
      case Inherit.script:
        return ScriptNodeType.script;

      // 剧集容器（如 "剧集/"）→ 其子目录是季
      case Inherit.seasonContainer:
        return ScriptNodeType.folder; // 自身是普通文件夹，但子目录是季

      // 季 → 子目录是集
      case Inherit.season:
        return ScriptNodeType.season;

      // 集 → 子目录是物料文件夹
      case Inherit.episode:
        return ScriptNodeType.episode;

      // 普通物料文件夹 → 子目录仍是文件夹
      case Inherit.folder:
        return ScriptNodeType.folder;
    }
  }

  /// 子目录应继承的上下文。
  /// [inherit] 当前目录继承的上下文, [type] 当前目录类型, [dirName] 当前目录名。
  static Inherit _childInherit(
      Inherit inherit, ScriptNodeType type, String dirName) {
    switch (inherit) {
      // scripts 下的剧本：若为季容器则进入季上下文，否则物料文件夹
      case Inherit.script:
        return _isSeasonContainer(dirName)
            ? Inherit.seasonContainer
            : Inherit.folder;

      // 季容器：子目录是季
      case Inherit.seasonContainer:
        return Inherit.season;

      // 季：子目录是集
      case Inherit.season:
        return Inherit.episode;

      // 集 / 普通物料：继续是物料文件夹
      case Inherit.episode:
      case Inherit.folder:
        return Inherit.folder;
    }
  }

  static bool _isSeasonContainer(String name) {
    return _seasonContainerNames.contains(name) ||
        _numberedDirPattern.hasMatch(name) && name.length <= 6;
  }
}

/// 继承上下文：决定当前目录的子目录如何分类
enum Inherit {
  script,          // 剧本（scripts 下一级）
  seasonContainer, // 季容器（剧集/）
  season,          // 季
  episode,         // 集
  folder,          // 普通文件夹
}
