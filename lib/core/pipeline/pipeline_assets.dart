import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import 'pipeline_models.dart';
import 'pipeline_store.dart';

/// 项目内可复用的参考图条目。
class PipelineReusableRef {
  const PipelineReusableRef({
    required this.path,
    required this.fileName,
    required this.stem,
    this.kindHint = '',
    this.refIdHint = '',
    this.titleHint = '',
    this.source = '',
    this.jobId = '',
  });

  final String path;
  final String fileName;
  final String stem;
  final String kindHint; // character | scene | prop | ''
  final String refIdHint;
  final String titleHint;
  final String source; // job_graph | assets_refs | project_folder
  final String jobId;

  Map<String, dynamic> toJson() => {
        'path': path,
        'fileName': fileName,
        'stem': stem,
        'kindHint': kindHint,
        'refIdHint': refIdHint,
        'titleHint': titleHint,
        'source': source,
        'jobId': jobId,
      };
}

class PipelineRefMatch {
  const PipelineRefMatch({
    required this.refId,
    required this.path,
    required this.score,
    required this.reason,
    this.candidate,
  });

  final String refId;
  final String path;
  final int score;
  final String reason;
  final PipelineReusableRef? candidate;

  Map<String, dynamic> toJson() => {
        'refId': refId,
        'path': path,
        'score': score,
        'reason': reason,
        if (candidate != null) 'candidate': candidate!.toJson(),
      };
}

/// 扫描项目里已有参考图，供 Agent / submit_graph 复用。
class PipelineAssets {
  PipelineAssets._();
  static final PipelineAssets instance = PipelineAssets._();

  static const _imageExts = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
    '.bmp',
    '.tif',
    '.tiff',
  };

  /// 常见物料目录名（相对项目任意深度，命中即扫一层图片）。
  static const _folderHints = {
    '角色定妆照': 'character',
    '角色参考': 'character',
    '角色': 'character',
    'characters': 'character',
    'character': 'character',
    '定妆': 'character',
    '场景素材': 'scene',
    '场景参考': 'scene',
    '场景': 'scene',
    'scenes': 'scene',
    'scene': 'scene',
    '道具': 'prop',
    '道具参考': 'prop',
    'props': 'prop',
    'prop': 'prop',
    'refs': '',
    '参考图': '',
    '成片': '',
    '分镜素材': '',
  };

  Future<List<PipelineReusableRef>> listReusableRefs({
    String? query,
    String? kind,
    int limit = 200,
  }) async {
    final root = AppConfig.instance.projectRoot.trim();
    if (root.isEmpty) return const [];

    final byPath = <String, PipelineReusableRef>{};

    // 1) 历史 Job graph 里已 ready 的路径（最准）
    await _collectFromJobGraphs(byPath);

    // 2) 兼容旧路径 assets/refs/**，以及各剧下的 参考图/**
    await _collectImagesUnder(
      p.join(root, 'assets', 'refs'),
      byPath,
      source: 'assets_refs',
      kindHint: '',
    );

    // 3) 项目内常见物料文件夹
    await _collectHintFolders(root, byPath);

    var list = byPath.values.toList();
    final kindFilter = (kind ?? '').trim().toLowerCase();
    if (kindFilter.isNotEmpty) {
      list = list
          .where((e) =>
              e.kindHint.isEmpty || e.kindHint.toLowerCase() == kindFilter)
          .toList();
    }
    final q = (query ?? '').trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) {
        return e.stem.toLowerCase().contains(q) ||
            e.fileName.toLowerCase().contains(q) ||
            e.refIdHint.toLowerCase().contains(q) ||
            e.titleHint.toLowerCase().contains(q) ||
            e.path.toLowerCase().contains(q);
      }).toList();
    }

    list.sort((a, b) {
      final ka = a.refIdHint.isNotEmpty ? 0 : 1;
      final kb = b.refIdHint.isNotEmpty ? 0 : 1;
      if (ka != kb) return ka.compareTo(kb);
      return b.path.compareTo(a.path);
    });
    if (list.length > limit) list = list.sublist(0, limit);
    return list;
  }

  /// 为 graph refs 找最佳已有图；不改磁盘。
  Future<List<PipelineRefMatch>> resolveRefs(
    List<PipelineRefNode> refs, {
    int minScore = 40,
  }) async {
    final catalog = await listReusableRefs(limit: 500);
    final out = <PipelineRefMatch>[];
    for (final ref in refs) {
      if (ref.outputPath != null &&
          ref.outputPath!.trim().isNotEmpty &&
          await File(ref.outputPath!).exists()) {
        out.add(PipelineRefMatch(
          refId: ref.id,
          path: ref.outputPath!,
          score: 100,
          reason: 'already_set',
        ));
        continue;
      }
      final best = _bestMatch(ref, catalog);
      if (best == null || best.score < minScore) continue;
      out.add(best);
    }
    return out;
  }

  /// 把匹配结果写回 graph（status=ready, outputPath=...）。
  Future<PipelineGraph> applyMatchesToGraph(
    PipelineGraph graph,
    List<PipelineRefMatch> matches,
  ) async {
    final byId = {for (final m in matches) m.refId: m};
    for (final ref in graph.refs) {
      final m = byId[ref.id];
      if (m == null) continue;
      if (ref.outputPath != null &&
          ref.outputPath!.trim().isNotEmpty &&
          ref.status == 'ready') {
        continue;
      }
      final f = File(m.path);
      if (!await f.exists()) continue;
      ref.outputPath = p.normalize(m.path);
      ref.status = 'ready';
      ref.reviewNote = '复用已有参考图（${m.reason}）';
    }
    return graph;
  }

  PipelineRefMatch? _bestMatch(
    PipelineRefNode ref,
    List<PipelineReusableRef> catalog,
  ) {
    PipelineRefMatch? best;
    for (final c in catalog) {
      if (ref.kind.isNotEmpty &&
          c.kindHint.isNotEmpty &&
          c.kindHint != ref.kind) {
        continue;
      }
      final score = _score(ref, c);
      if (score <= 0) continue;
      if (best == null || score > best.score) {
        best = PipelineRefMatch(
          refId: ref.id,
          path: c.path,
          score: score,
          reason: _reason(ref, c, score),
          candidate: c,
        );
      }
    }
    return best;
  }

  int _score(PipelineRefNode ref, PipelineReusableRef c) {
    final id = _norm(ref.id);
    final title = _norm(ref.title);
    final stem = _norm(c.stem);
    final cid = _norm(c.refIdHint);
    final ctitle = _norm(c.titleHint);
    final file = _norm(c.fileName);

    if (id.isNotEmpty && (cid == id || stem == id)) return 95;
    if (title.isNotEmpty && (ctitle == title || stem == title)) return 90;
    if (id.isNotEmpty && (stem.contains(id) || file.contains(id) || cid.contains(id))) {
      return 75;
    }
    if (title.isNotEmpty &&
        (stem.contains(title) ||
            file.contains(title) ||
            ctitle.contains(title) ||
            title.contains(stem))) {
      return 70;
    }
    // 弱匹配：去掉常见前缀后再比
    final idCore = id.replaceFirst(RegExp(r'^(char|character|ref|scene|prop)_'), '');
    final titleCore = title.replaceFirst(RegExp(r'^(角色|场景|道具)'), '');
    if (idCore.length >= 2 && stem.contains(idCore)) return 55;
    if (titleCore.length >= 2 && stem.contains(titleCore)) return 50;
    return 0;
  }

  String _reason(PipelineRefNode ref, PipelineReusableRef c, int score) {
    if (score >= 90) return 'exact:${c.source}';
    if (score >= 70) return 'name:${c.source}';
    return 'fuzzy:${c.source}';
  }

  String _norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'[\s_\-－]+'), '');

  Future<void> _collectFromJobGraphs(
    Map<String, PipelineReusableRef> byPath,
  ) async {
    final jobsDir = PipelineStore.instance.jobsDir;
    if (jobsDir == null) return;
    final dir = Directory(jobsDir);
    if (!await dir.exists()) return;
    await for (final e in dir.list()) {
      if (e is! Directory) continue;
      final jobId = p.basename(e.path);
      final gf = File(p.join(e.path, 'graph.json'));
      if (!await gf.exists()) continue;
      try {
        final map = jsonDecode(await gf.readAsString());
        if (map is! Map) continue;
        final graph = PipelineGraph.fromJson(map.cast<String, dynamic>());
        for (final r in graph.refs) {
          final path = r.outputPath?.trim() ?? '';
          if (path.isEmpty) continue;
          if (r.status != 'ready' && r.status != 'pending') {
            // failed 也可作候选，但降权：仍收录
          }
          if (!await File(path).exists()) continue;
          byPath.putIfAbsent(
            p.normalize(path),
            () => PipelineReusableRef(
              path: p.normalize(path),
              fileName: p.basename(path),
              stem: p.basenameWithoutExtension(path),
              kindHint: r.kind,
              refIdHint: r.id,
              titleHint: r.title,
              source: 'job_graph',
              jobId: jobId,
            ),
          );
        }
      } catch (_) {}
    }
  }

  Future<void> _collectHintFolders(
    String root,
    Map<String, PipelineReusableRef> byPath,
  ) async {
    final rootDir = Directory(root);
    if (!await rootDir.exists()) return;
    // 限制深度，避免扫爆网盘
    await _walkHint(rootDir, byPath, depth: 0, maxDepth: 5);
  }

  Future<void> _walkHint(
    Directory dir,
    Map<String, PipelineReusableRef> byPath, {
    required int depth,
    required int maxDepth,
  }) async {
    if (depth > maxDepth) return;
    final name = p.basename(dir.path);
    final kind = _folderHints[name];
    if (kind != null) {
      await _collectImagesUnder(
        dir.path,
        byPath,
        source: 'project_folder',
        kindHint: kind,
        recursive: true,
        maxDepth: 2,
      );
      // 命中物料夹后仍继续向下找其它同类夹
    }
    if (depth == maxDepth) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is! Directory) continue;
        final base = p.basename(e.path);
        if (base.startsWith('.')) continue;
        if (base == 'node_modules' || base == 'build') continue;
        await _walkHint(e, byPath, depth: depth + 1, maxDepth: maxDepth);
      }
    } catch (_) {}
  }

  Future<void> _collectImagesUnder(
    String dirPath,
    Map<String, PipelineReusableRef> byPath, {
    required String source,
    required String kindHint,
    bool recursive = true,
    int maxDepth = 3,
    String jobId = '',
  }) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    await _collectImagesWalk(
      dir,
      byPath,
      source: source,
      kindHint: kindHint,
      jobId: jobId,
      depth: 0,
      maxDepth: recursive ? maxDepth : 0,
    );
  }

  Future<void> _collectImagesWalk(
    Directory dir,
    Map<String, PipelineReusableRef> byPath, {
    required String source,
    required String kindHint,
    required String jobId,
    required int depth,
    required int maxDepth,
  }) async {
    try {
      await for (final e in dir.list(followLinks: false)) {
        if (e is File) {
          final ext = p.extension(e.path).toLowerCase();
          if (!_imageExts.contains(ext)) continue;
          final norm = p.normalize(e.path);
          byPath.putIfAbsent(
            norm,
            () => PipelineReusableRef(
              path: norm,
              fileName: p.basename(norm),
              stem: p.basenameWithoutExtension(norm),
              kindHint: kindHint.isNotEmpty
                  ? kindHint
                  : _guessKindFromPath(norm),
              source: source,
              jobId: jobId,
            ),
          );
        } else if (e is Directory && depth < maxDepth) {
          final base = p.basename(e.path);
          if (base.startsWith('.')) continue;
          final childKind = _folderHints[base] ?? kindHint;
          await _collectImagesWalk(
            e,
            byPath,
            source: source,
            kindHint: childKind,
            jobId: jobId,
            depth: depth + 1,
            maxDepth: maxDepth,
          );
        }
      }
    } catch (_) {}
  }

  String _guessKindFromPath(String path) {
    final lower = path.toLowerCase();
    if (lower.contains('character') ||
        lower.contains('角色') ||
        lower.contains('定妆')) {
      return 'character';
    }
    if (lower.contains('scene') || lower.contains('场景')) return 'scene';
    if (lower.contains('prop') || lower.contains('道具')) return 'prop';
    return '';
  }
}
