import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../text_file_io.dart';
import 'pipeline_host.dart';
import 'pipeline_models.dart';

/// `.aireel/pipeline` 落盘。
class PipelineStore {
  PipelineStore._();
  static final PipelineStore instance = PipelineStore._();

  String? get root {
    final r = AppConfig.instance.projectRoot.trim();
    if (r.isEmpty) return null;
    return p.join(r, '.aireel', 'pipeline');
  }

  String? get jobsDir {
    final r = root;
    if (r == null) return null;
    return p.join(r, 'jobs');
  }

  Future<Directory> _ensureDir(String path) async {
    final d = Directory(path);
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<PipelineConfig> loadConfig() async {
    final r = root;
    if (r == null) return const PipelineConfig();
    await _ensureDir(r);
    final f = File(p.join(r, 'config.json'));
    if (!await f.exists()) {
      final cfg = const PipelineConfig();
      await writeTextFileReliable(f.path, _pretty(cfg.toJson()));
      return cfg;
    }
    try {
      final map = jsonDecode(await f.readAsString());
      if (map is Map) {
        return PipelineConfig.fromJson(map.cast<String, dynamic>());
      }
    } catch (_) {}
    return const PipelineConfig();
  }

  Future<void> saveConfig(PipelineConfig config) async {
    final r = root;
    if (r == null) throw StateError('未配置项目根目录');
    await _ensureDir(r);
    await writeTextFileReliable(
      p.join(r, 'config.json'),
      _pretty(config.toJson()),
    );
  }

  String jobDir(String jobId) {
    final d = jobsDir;
    if (d == null) throw StateError('未配置项目根目录');
    return p.join(d, jobId);
  }

  Future<PipelineJob> createJob({
    required PipelineIntent intent,
    required String chapterPath,
    String? sceneId,
    String userBrief = '',
  }) async {
    final jd = jobsDir;
    if (jd == null) throw StateError('未配置项目根目录');
    // 必须落到已存在的剧本/集目录，禁止在项目根「造」新剧名文件夹。
    final resolved = await resolveExistingWorkDir(chapterPath);
    await _ensureDir(jd);
    final id =
        'job_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    final now = DateTime.now().toUtc();
    final job = PipelineJob(
      id: id,
      intent: intent,
      chapterPath: resolved,
      sceneId: sceneId,
      userBrief: userBrief,
      hostId: PipelineHost.id,
      createdAt: now,
      updatedAt: now,
      status: PipelineJobStatus.queued,
      steps: [
        PipelineStep(id: 'authoring', type: PipelineStepType.authoring),
        PipelineStep(id: 'gen_refs', type: PipelineStepType.genRefs),
        PipelineStep(id: 'review_refs', type: PipelineStepType.reviewRefs),
        PipelineStep(id: 'gen_clips', type: PipelineStepType.genClips),
        PipelineStep(id: 'review_clips', type: PipelineStepType.reviewClips),
        PipelineStep(id: 'finalize', type: PipelineStepType.finalize),
      ],
      currentStepId: 'authoring',
    );
    final dir = await _ensureDir(jobDir(id));
    await writeTextFileReliable(
      p.join(dir.path, 'job.json'),
      _pretty(job.toJson()),
    );
    await writeTextFileReliable(
      p.join(dir.path, 'graph.json'),
      _pretty(const {'refs': [], 'shots': []}),
    );
    await appendEvent(id, 'created', {'intent': pipelineIntentName(intent)});
    return job;
  }

  /// [mineOnly] 为 true 时只返回本机创建的 Job（多机 NAS 防串台）。
  Future<List<PipelineJob>> listJobs({bool mineOnly = false}) async {
    final jd = jobsDir;
    if (jd == null) return const [];
    final dir = Directory(jd);
    if (!await dir.exists()) return const [];
    final out = <PipelineJob>[];
    await for (final e in dir.list()) {
      if (e is! Directory) continue;
      try {
        out.add(await loadJob(p.basename(e.path)));
      } catch (_) {}
    }
    out.sort((a, b) {
      final ta = a.updatedAt ?? a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final tb = b.updatedAt ?? b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });
    if (!mineOnly) return out;
    return [
      for (final j in out)
        if (PipelineHost.isMine(j.hostId)) j,
    ];
  }

  Future<PipelineJob> loadJob(String jobId) async {
    final f = File(p.join(jobDir(jobId), 'job.json'));
    if (!await f.exists()) throw StateError('Job 不存在: $jobId');
    final map = jsonDecode(await f.readAsString());
    if (map is! Map) throw StateError('job.json 无效');
    return PipelineJob.fromJson(map.cast<String, dynamic>());
  }

  /// 串行化同一 job 的写盘，避免并行 worker 抢写把主线程拖死。
  final _writeLocks = <String, Future<void>>{};

  Future<void> _withWriteLock(String jobId, Future<void> Function() body) async {
    final prev = _writeLocks[jobId] ?? Future<void>.value();
    final gate = Completer<void>();
    _writeLocks[jobId] = gate.future;
    await prev;
    try {
      await body();
    } finally {
      gate.complete();
      if (identical(_writeLocks[jobId], gate.future)) {
        _writeLocks.remove(jobId);
      }
    }
  }

  Future<void> saveJob(PipelineJob job) async {
    await _withWriteLock(job.id, () async {
      job.updatedAt = DateTime.now().toUtc();
      final dir = await _ensureDir(jobDir(job.id));
      await writeTextFileReliable(
        p.join(dir.path, 'job.json'),
        _pretty(job.toJson()),
      );
    });
  }

  /// 删除 Job 账本目录（含临时成片）；不删剧目录「参考图 / 分镜素材」。
  Future<void> deleteJob(String jobId) async {
    final id = jobId.trim();
    if (id.isEmpty) throw StateError('jobId 为空');
    final dir = Directory(jobDir(id));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<PipelineGraph> loadGraph(String jobId) async {
    final f = File(p.join(jobDir(jobId), 'graph.json'));
    if (!await f.exists()) return PipelineGraph();
    try {
      final map = jsonDecode(await f.readAsString());
      if (map is Map) {
        return PipelineGraph.fromJson(map.cast<String, dynamic>());
      }
    } catch (_) {}
    return PipelineGraph();
  }

  Future<void> saveGraph(String jobId, PipelineGraph graph) async {
    await _withWriteLock(jobId, () async {
      final dir = await _ensureDir(jobDir(jobId));
      await writeTextFileReliable(
        p.join(dir.path, 'graph.json'),
        graph.encodePretty(),
      );
    });
  }

  Future<void> appendEvent(
    String jobId,
    String type,
    Map<String, dynamic> payload,
  ) async {
    final dir = await _ensureDir(jobDir(jobId));
    final f = File(p.join(dir.path, 'events.jsonl'));
    final line = jsonEncode({
      'at': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      ...payload,
    });
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  /// 解析为**已存在**的工作目录（剧本/集所在原目录）。
  ///
  /// - 文件 → 其所在目录  
  /// - 已有目录 → 该目录  
  /// - 名称提示（如「第14集」「001_悬疑」）→ 在项目内搜索已有文件夹  
  /// - 找不到则抛错，**绝不**在项目根新建剧名目录
  Future<String> resolveExistingWorkDir(String chapterPath) async {
    final project = AppConfig.instance.projectRoot.trim();
    if (project.isEmpty) {
      throw StateError('未配置项目根目录');
    }
    final projectNorm = p.normalize(project);
    final raw = chapterPath.trim();
    if (raw.isEmpty) {
      throw StateError('chapterPath 为空：请传入已有剧本/集目录或文件路径');
    }

    var candidate = raw;
    if (!p.isAbsolute(candidate)) {
      candidate = p.normalize(p.join(projectNorm, candidate));
    } else {
      candidate = p.normalize(candidate);
    }

    final existing = await _existingDirOf(candidate);
    if (existing != null &&
        _isUnderProject(existing, projectNorm) &&
        !p.equals(existing, projectNorm)) {
      // 仅当 candidate 自身存在（或是已有文件的父目录）才采纳；
      // 若只是「不存在路径的祖先=项目根」，不能算命中。
      final selfExists = await FileSystemEntity.type(candidate, followLinks: false);
      if (selfExists == FileSystemEntityType.directory ||
          selfExists == FileSystemEntityType.file) {
        return existing;
      }
      // candidate 不存在：只有向上找到的祖先仍在项目内且不是根时，
      // 且路径前缀匹配（说明写深了一层），才用祖先。
      if (!p.equals(existing, projectNorm) &&
          p.isWithin(existing, candidate)) {
        return existing;
      }
    }

    // 模糊：用原始字符串在项目里找已有目录
    final hit = await findExistingDirByHint(raw, projectNorm);
    if (hit != null && !p.equals(hit, projectNorm)) return hit;

    throw StateError(
      '找不到已有目录：$raw\n'
      '请把 chapterPath 设为项目里已存在的剧本/集文件夹或其中的剧本文件，'
      '不要传尚未存在的剧名（否则会在根目录误建文件夹）。',
    );
  }

  /// 兼容旧名：同步场景尽量用 [job.chapterPath]（创建时已解析为绝对存在路径）。
  String resolveScriptRoot(String chapterPath) {
    final project = AppConfig.instance.projectRoot.trim();
    final projectNorm = p.normalize(project);
    var path = chapterPath.trim();
    if (path.isEmpty) {
      throw StateError('chapterPath 为空');
    }
    if (!p.isAbsolute(path)) {
      path = p.normalize(p.join(projectNorm, path));
    } else {
      path = p.normalize(path);
    }
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        path = p.dirname(path);
      } else if (type == FileSystemEntityType.notFound) {
        throw StateError('工作目录不存在，拒绝新建剧名目录: $path');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('工作目录无效: $path');
    }
    if (!_isUnderProject(path, projectNorm) && path != projectNorm) {
      throw StateError('chapterPath 必须在项目根内: $path');
    }
    // 禁止把项目根本身当工作目录（避免物料堆在根上）
    if (p.equals(path, projectNorm)) {
      throw StateError('请指定具体剧本/集目录，不能用项目根当 chapterPath');
    }
    return path;
  }

  /// 参考图：落在剧本/集目录下（跨 Job 可复用）。
  Future<String> ensureRefsDirForJob(PipelineJob job) async {
    final dest = refsDirForJob(job);
    final base = resolveScriptRoot(job.chapterPath);
    if (!await Directory(base).exists()) {
      throw StateError('原目录不存在，拒绝创建: $base');
    }
    await Directory(dest).create(recursive: true);
    return dest;
  }

  /// 成片临时目录：按 Job 隔离，避免多任务同名覆盖。
  /// `.aireel/pipeline/jobs/<jobId>/clips/`
  Future<String> ensureClipsDirForJob(PipelineJob job) async {
    final dest = clipsTempDirForJob(job);
    await Directory(dest).create(recursive: true);
    return dest;
  }

  String refsDirForJob(PipelineJob job) {
    final base = resolveScriptRoot(job.chapterPath);
    return p.join(base, '参考图');
  }

  /// 兼容旧调用名：现为 Job 临时成片目录。
  String clipsDirForJob(PipelineJob job) => clipsTempDirForJob(job);

  String clipsTempDirForJob(PipelineJob job) {
    return p.join(jobDir(job.id), 'clips');
  }

  /// 分镜脚本根：优先 [PipelineJob.storyboardDir]，否则用 chapter 工作目录。
  String storyboardRootForJob(PipelineJob job) {
    final raw = job.storyboardDir?.trim() ?? '';
    if (raw.isEmpty) {
      return resolveScriptRoot(job.chapterPath);
    }
    final project = AppConfig.instance.projectRoot.trim();
    final projectNorm = p.normalize(project);
    var path = raw;
    if (!p.isAbsolute(path)) {
      path = p.normalize(p.join(projectNorm, path));
    } else {
      path = p.normalize(path);
    }
    try {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        path = p.dirname(path);
      } else if (type == FileSystemEntityType.notFound) {
        throw StateError('分镜脚本目录不存在: $path');
      }
    } catch (e) {
      if (e is StateError) rethrow;
      throw StateError('分镜脚本目录无效: $path');
    }
    return path;
  }

  /// 最终成片落盘：`<分镜脚本目录>/分镜素材/`
  String materialsDirForJob(PipelineJob job) {
    return p.join(storyboardRootForJob(job), '分镜素材');
  }

  Future<String> ensureMaterialsDirForJob(PipelineJob job) async {
    final dest = materialsDirForJob(job);
    final root = storyboardRootForJob(job);
    if (!await Directory(root).exists()) {
      throw StateError('分镜脚本目录不存在，拒绝创建分镜素材: $root');
    }
    await Directory(dest).create(recursive: true);
    return dest;
  }

  /// 把 Job 临时成片复制到「分镜素材」，并回写 [PipelineShotNode.outputPath]。
  /// 返回成功落盘条数。
  Future<int> publishClipsToMaterials(
    PipelineJob job,
    PipelineGraph graph,
  ) async {
    final materials = await ensureMaterialsDirForJob(job);
    var n = 0;
    for (final shot in graph.shots) {
      final src = shot.outputPath?.trim() ?? '';
      if (src.isEmpty) continue;
      final srcFile = File(src);
      if (!await srcFile.exists()) continue;
      // 已在最终目录则跳过复制
      final materialsNorm = p.normalize(materials);
      if (p.equals(p.dirname(src), materialsNorm) ||
          p.isWithin(materialsNorm, src)) {
        shot.outputPath = p.normalize(src);
        n++;
        continue;
      }
      var ext = p.extension(src);
      if (ext.isEmpty) ext = '.mp4';
      final destPath = p.join(materials, '${shot.id}$ext');
      await srcFile.copy(destPath);
      shot.outputPath = p.normalize(destPath);
      n++;
    }
    return n;
  }

  /// 清理 Job 下临时媒体（成片缓存等），保留 job.json / graph.json / report。
  Future<void> cleanupJobTempMedia(String jobId) async {
    final id = jobId.trim();
    if (id.isEmpty) return;
    final clips = Directory(p.join(jobDir(id), 'clips'));
    if (await clips.exists()) {
      try {
        await clips.delete(recursive: true);
      } catch (_) {}
    }
    // 兼容旧版误写在剧目录「成片」的路径不在此删；只清 .aireel 临时区。
    final legacy = Directory(p.join(jobDir(id), '成片'));
    if (await legacy.exists()) {
      try {
        await legacy.delete(recursive: true);
      } catch (_) {}
    }
  }

  bool _isUnderProject(String path, String projectNorm) {
    final rel = p.relative(p.normalize(path), from: projectNorm);
    return rel == '.' || !rel.startsWith('..');
  }

  Future<String?> _existingDirOf(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        return p.normalize(path);
      }
      if (type == FileSystemEntityType.file) {
        return p.normalize(p.dirname(path));
      }
    } catch (_) {}
    // 路径不存在时，向上找已存在的祖先（但仍须由调用方校验不能是项目根误用）
    var cur = path;
    for (var i = 0; i < 8; i++) {
      final parent = p.dirname(cur);
      if (parent == cur) break;
      try {
        if (await Directory(parent).exists()) return p.normalize(parent);
      } catch (_) {}
      cur = parent;
    }
    return null;
  }

  /// 按提示在项目内找已有目录（不创建）。
  Future<String?> findExistingDirByHint(String hint, String projectNorm) async {
    final h = hint.trim();
    if (h.isEmpty) return null;
    final baseName = p.basename(h);
    final ep = RegExp(r'第\s*(\d+)\s*集').firstMatch(h);
    final epNum = ep?.group(1);
    final needle = baseName.toLowerCase();

    String? best;
    var bestScore = 0;

    Future<void> consider(String dirPath) async {
      final name = p.basename(dirPath);
      final lower = name.toLowerCase();
      var score = 0;
      if (lower == needle) {
        score = 100;
      } else if (needle.isNotEmpty && lower.contains(needle)) {
        score = 70;
      } else if (epNum != null) {
        final n = int.tryParse(epNum);
        if (n != null) {
          final padded = n.toString().padLeft(2, '0');
          if (RegExp('(^|[^0-9])0*$n([^0-9]|\$)').hasMatch(name) ||
              lower.startsWith('${padded}_') ||
              lower.startsWith('$padded-') ||
              name.contains('第$n集') ||
              name.contains('第$epNum集')) {
            score = 80;
          }
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = dirPath;
      }
    }

    Future<void> walk(Directory dir, int depth) async {
      if (depth > 6) return;
      try {
        await for (final e in dir.list(followLinks: false)) {
          if (e is! Directory) continue;
          final name = p.basename(e.path);
          if (name.startsWith('.')) continue;
          if (name == '参考图' ||
              name == '成片' ||
              name == '分镜素材' ||
              name == 'node_modules' ||
              name == 'build') {
            continue;
          }
          await consider(e.path);
          await walk(e, depth + 1);
        }
      } catch (_) {}
    }

    final root = Directory(projectNorm);
    if (!await root.exists()) return null;
    await walk(root, 0);
    if (best != null && bestScore >= 70) return p.normalize(best!);
    return null;
  }

  Future<void> writeBridgeInfo({required int port, required String baseUrl}) async {
    final r = root;
    if (r == null) return;
    await _ensureDir(r);
    final payload = {
      'hostId': PipelineHost.id,
      'hostName': PipelineHost.displayName,
      'port': port,
      'baseUrl': baseUrl,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    // 兼容旧 skill：仍写 bridge.json（本机启动时覆盖为自己的端口）
    await writeTextFileReliable(p.join(r, 'bridge.json'), _pretty(payload));
    // 多机：每台机器单独一份，避免互相覆盖后 Agent 打到错误端口
    final bridges = await _ensureDir(p.join(r, 'bridges'));
    await writeTextFileReliable(
      p.join(bridges.path, '${PipelineHost.id}.json'),
      _pretty(payload),
    );
  }

  String _pretty(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}
