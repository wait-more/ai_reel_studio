import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'pipeline_assets.dart';
import 'pipeline_engine.dart';
import 'pipeline_host.dart';
import 'pipeline_models.dart';
import 'pipeline_store.dart';

/// 本机 HTTP 工具桥（供 OpenCode / MCP 客户端调用）。
///
/// 默认 `127.0.0.1:<bridgePort>`，路由：
/// - GET  /health
/// - GET  /pipeline/jobs
/// - GET  /pipeline/jobs/:id
/// - GET  /pipeline/assets/refs
/// - POST /pipeline/resolve_refs
/// - POST /pipeline/parse_intent
/// - POST /pipeline/create_job
/// - POST /pipeline/submit_graph
/// - POST /pipeline/run_job
/// - POST /pipeline/submit_review_batch
/// - POST /pipeline/ack_agent_step
/// - POST /pipeline/revise_scene
/// - POST /pipeline/cancel_job
/// - POST /pipeline/delete_job
/// - GET  /pipeline/config
/// - PUT  /pipeline/config
class PipelineBridge {
  PipelineBridge._();
  static final PipelineBridge instance = PipelineBridge._();

  HttpServer? _server;
  int? _port;
  String? _baseUrl;

  int? get port => _port;
  String? get baseUrl => _baseUrl;
  bool get isRunning => _server != null;

  final _engine = PipelineEngine.instance;
  final _store = PipelineStore.instance;

  Future<void> start({int? preferredPort}) async {
    if (_server != null) return;
    final cfg = await _store.loadConfig();
    final want = preferredPort ?? cfg.bridgePort;
    HttpServer? server;
    Object? lastErr;
    for (final port in [want, 0]) {
      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        break;
      } catch (e) {
        lastErr = e;
      }
    }
    if (server == null) {
      throw StateError('Pipeline bridge 启动失败: $lastErr');
    }
    _server = server;
    _port = server.port;
    _baseUrl = 'http://127.0.0.1:${server.port}';
    await _store.writeBridgeInfo(port: server.port, baseUrl: _baseUrl!);
    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _port = null;
    _baseUrl = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }

  Future<void> restart() async {
    await stop();
    await start();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      _cors(req);
      if (req.method == 'OPTIONS') {
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/health') {
        await _json(req, {
          'ok': true,
          'service': 'aireel-pipeline',
          'port': _port,
          'hostId': PipelineHost.id,
          'hostName': PipelineHost.displayName,
          'baseUrl': _baseUrl,
        });
        return;
      }
      if (req.method == 'GET' && path == '/pipeline/jobs') {
        // 默认 mine：多机 NAS 时避免 Agent 把别机任务当成自己的
        final scope = (req.uri.queryParameters['scope'] ?? 'mine').trim();
        final mineOnly = scope != 'all';
        final jobs = await _store.listJobs(mineOnly: mineOnly);
        await _json(req, {
          'scope': mineOnly ? 'mine' : 'all',
          'hostId': PipelineHost.id,
          'jobs': [
            for (final j in jobs)
              {
                ...j.toJson(),
                'mine': PipelineHost.isMine(j.hostId),
              },
          ],
        });
        return;
      }
      final jobMatch = RegExp(r'^/pipeline/jobs/([^/]+)$').firstMatch(path);
      if (req.method == 'GET' && jobMatch != null) {
        final id = Uri.decodeComponent(jobMatch.group(1)!);
        await _json(req, await _engine.getJobSnapshot(id));
        return;
      }
      if (req.method == 'GET' && path == '/pipeline/config') {
        await _json(req, (await _store.loadConfig()).toJson());
        return;
      }
      if (req.method == 'PUT' && path == '/pipeline/config') {
        final body = await _readJson(req);
        final cfg = PipelineConfig.fromJson(body);
        await _store.saveConfig(cfg);
        await _json(req, cfg.toJson());
        return;
      }
      if (req.method == 'GET' && path == '/pipeline/assets/refs') {
        final q = req.uri.queryParameters['q'] ??
            req.uri.queryParameters['query'];
        final kind = req.uri.queryParameters['kind'];
        final limit =
            int.tryParse(req.uri.queryParameters['limit'] ?? '') ?? 200;
        final items = await PipelineAssets.instance.listReusableRefs(
          query: q,
          kind: kind,
          limit: limit,
        );
        await _json(req, {
          'count': items.length,
          'refs': [for (final e in items) e.toJson()],
        });
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/resolve_refs') {
        final body = await _readJson(req);
        final rawRefs = body['refs'] as List? ?? const [];
        final nodes = <PipelineRefNode>[
          for (final e in rawRefs)
            if (e is Map)
              PipelineRefNode.fromJson(e.cast<String, dynamic>()),
        ];
        final minScore = (body['minScore'] as num?)?.toInt() ?? 40;
        final matches = await PipelineAssets.instance.resolveRefs(
          nodes,
          minScore: minScore,
        );
        await _json(req, {
          'count': matches.length,
          'matches': [for (final m in matches) m.toJson()],
        });
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/parse_intent') {
        final body = await _readJson(req);
        await _json(req, _parseIntent(body));
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/create_job') {
        final body = await _readJson(req);
        final intent = pipelineIntentFromName(body['intent'] as String?);
        final chapter = '${body['chapterPath'] ?? body['chapter'] ?? ''}'.trim();
        if (chapter.isEmpty && intent != PipelineIntent.other) {
          await _json(req, {'error': '缺少 chapterPath'}, status: 400);
          return;
        }
        try {
          final job = await _engine.createJob(
            intent: intent,
            chapterPath: chapter,
            sceneId: body['sceneId'] as String?,
            userBrief: '${body['userBrief'] ?? body['brief'] ?? ''}',
          );
          await _json(req, {
            'job': job.toJson(),
            'scriptRoot': job.chapterPath,
            'refsDir': _store.refsDirForJob(job),
            'clipsTempDir': _store.clipsTempDirForJob(job),
            'clipsDir': _store.clipsTempDirForJob(job),
            'materialsDir': _store.materialsDirForJob(job),
          });
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 400);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/submit_graph') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        final graph = PipelineGraph.fromJson(
          (body['graph'] as Map?)?.cast<String, dynamic>(),
        );
        final reuseExisting = body['reuseExisting'] as bool? ?? true;
        final force = body['force'] as bool? ?? false;
        try {
          final job = await _engine.submitGraph(
            jobId: jobId,
            graph: graph,
            storyboardDir: body['storyboardDir'] as String?,
            reuseExisting: reuseExisting,
            force: force,
          );
          final snap = await _engine.getJobSnapshot(jobId);
          await _json(req, {
            'job': job.toJson(),
            'graph': snap['graph'],
            'reuseExisting': reuseExisting,
          });
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/run_job') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        try {
          final job = await _engine.runJob(
            jobId,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'job': job.toJson()});
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/submit_review_batch') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        final phase = '${body['phase'] ?? 'refs'}';
        final rawItems = body['items'] as List? ?? const [];
        final items = <PipelineReviewItem>[
          for (final e in rawItems)
            if (e is Map)
              PipelineReviewItem.fromJson(e.cast<String, dynamic>()),
        ];
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        try {
          final job = await _engine.submitReviewBatch(
            jobId: jobId,
            phase: phase,
            items: items,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'job': job.toJson()});
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/ack_agent_step') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        try {
          final job = await _engine.ackAgentStep(
            jobId,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'job': job.toJson()});
        } catch (e) {
          final msg = '$e';
          final code = msg.contains('authoring') || msg.contains('无需 ack')
              ? 400
              : 409;
          await _json(req, {'error': msg}, status: code);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/revise_scene') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        final sceneId = '${body['sceneId'] ?? ''}'.trim();
        final feedback = '${body['feedback'] ?? ''}'.trim();
        if (jobId.isEmpty || sceneId.isEmpty) {
          await _json(req, {'error': '缺少 jobId 或 sceneId'}, status: 400);
          return;
        }
        try {
          final job = await _engine.reviseScene(
            jobId: jobId,
            sceneId: sceneId,
            feedback: feedback,
            newPrompt: body['newPrompt'] as String?,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'job': job.toJson()});
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/cancel_job') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        try {
          final job = await _engine.cancelJob(
            jobId,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'job': job.toJson()});
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }
      if (req.method == 'POST' && path == '/pipeline/delete_job') {
        final body = await _readJson(req);
        final jobId = '${body['jobId'] ?? ''}'.trim();
        if (jobId.isEmpty) {
          await _json(req, {'error': '缺少 jobId'}, status: 400);
          return;
        }
        try {
          await _engine.deleteJob(
            jobId,
            force: body['force'] as bool? ?? false,
          );
          await _json(req, {'ok': true, 'jobId': jobId});
        } catch (e) {
          await _json(req, {'error': '$e'}, status: 409);
        }
        return;
      }

      await _json(req, {'error': 'not found', 'path': path}, status: 404);
    } catch (e) {
      try {
        await _json(req, {'error': '$e'}, status: 500);
      } catch (_) {}
    }
  }

  Map<String, dynamic> _parseIntent(Map<String, dynamic> body) {
    final text = '${body['text'] ?? body['message'] ?? ''}'.trim();
    final lower = text.toLowerCase();
    PipelineIntent intent = PipelineIntent.other;
    String? chapter;
    String? scene;

    final ep = RegExp(r'第\s*(\d+)\s*集').firstMatch(text);
    if (ep != null) chapter = '第${ep.group(1)}集';
    final sc = RegExp(r'第\s*(\d+)\s*场').firstMatch(text);
    if (sc != null) scene = 'scene_${sc.group(1)}';

    if (text.contains('返修') ||
        text.contains('重做') ||
        text.contains('不行') ||
        lower.contains('revise')) {
      intent = PipelineIntent.sceneRevise;
    } else if (text.contains('参考图') &&
        (text.contains('只') || text.contains('先'))) {
      intent = PipelineIntent.refOnly;
    } else if (text.contains('做到哪') ||
        text.contains('进度') ||
        lower.contains('status')) {
      intent = PipelineIntent.status;
    } else if (scene != null &&
        (text.contains('只做') || text.contains('单场') || text.contains('这一场'))) {
      intent = PipelineIntent.sceneProduce;
    } else if (chapter != null &&
        (text.contains('制作') ||
            text.contains('做一下') ||
            text.contains('出片') ||
            text.contains('生成'))) {
      intent = PipelineIntent.episodeProduce;
    } else if (chapter != null) {
      intent = PipelineIntent.episodeProduce;
    }

    return {
      'intent': pipelineIntentName(intent),
      'chapterHint': chapter,
      'sceneHint': scene,
      'needClarify': chapter == null &&
          intent != PipelineIntent.other &&
          intent != PipelineIntent.status,
      'raw': text,
    };
  }

  void _cors(HttpRequest req) {
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    req.response.headers.set(
      'Access-Control-Allow-Methods',
      'GET, POST, PUT, OPTIONS',
    );
    req.response.headers.set(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization',
    );
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final raw = await utf8.decoder.bind(req).join();
    if (raw.trim().isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    return {};
  }

  Future<void> _json(
    HttpRequest req,
    Object body, {
    int status = 200,
  }) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }
}
