import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../comfy/comfy_client.dart';
import '../comfy/comfy_discover.dart';
import '../comfy/comfy_models.dart';
import '../comfy/comfy_template_store.dart';
import '../config.dart';
import 'pipeline_models.dart';

class _ServerLease {
  _ServerLease(this.server) : client = ComfyClient(
          baseUrl: server.baseUrl,
          apiKey: server.apiKey.isEmpty ? null : server.apiKey,
        );

  final ComfyServer server;
  final ComfyClient client;
  bool busy = false;
}

String _comfyUrlKey(String baseUrl) =>
    baseUrl.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');

/// 进程内共享 Comfy「桶」：多 Job 共用 busy/排队，避免各自以为整池空闲一起打满。
class _ComfyBucketPool {
  _ComfyBucketPool._();
  static final instance = _ComfyBucketPool._();

  final _byUrl = <String, _ServerLease>{};
  final _wake = Queue<Completer<void>>();
  Future<void>? _probeGate;

  Future<List<_ServerLease>> ensureOnline(List<ComfyServer> candidates) async {
    // 串行探测，避免并发 prepare 只跑第一批候选、漏掉其它 Job 的服务器。
    final prev = _probeGate;
    final done = Completer<void>();
    _probeGate = done.future;
    try {
      if (prev != null) await prev;
      await _probeAll(candidates);
    } finally {
      done.complete();
      if (identical(_probeGate, done.future)) _probeGate = null;
    }
    final out = <_ServerLease>[];
    for (final s in candidates) {
      final lease = _byUrl[_comfyUrlKey(s.baseUrl)];
      if (lease != null) out.add(lease);
    }
    return out;
  }

  Future<void> _probeAll(List<ComfyServer> candidates) async {
    final missing = <ComfyServer>[];
    for (final s in candidates) {
      final key = _comfyUrlKey(s.baseUrl);
      if (key.isEmpty) continue;
      if (!_byUrl.containsKey(key)) missing.add(s);
    }
    if (missing.isEmpty) return;
    final probed = await Future.wait([
      for (final s in missing) _probe(s),
    ]);
    for (final lease in probed) {
      if (lease == null) continue;
      final key = _comfyUrlKey(lease.server.baseUrl);
      _byUrl.putIfAbsent(key, () => lease);
    }
  }

  Future<_ServerLease?> _probe(ComfyServer server) async {
    final lease = _ServerLease(server);
    try {
      final ok = await lease.client.ping();
      if (!ok) {
        lease.client.close();
        return null;
      }
      return lease;
    } catch (_) {
      lease.client.close();
      return null;
    }
  }

  Future<_ServerLease> _pickLeastLoaded(List<_ServerLease> candidates) async {
    if (candidates.length == 1) return candidates.first;
    final scores = await Future.wait([
      for (final c in candidates) _queueLoadScore(c),
    ]);
    var bestI = 0;
    for (var i = 1; i < scores.length; i++) {
      if (scores[i] < scores[bestI]) bestI = i;
    }
    return candidates[bestI];
  }

  Future<int> _queueLoadScore(_ServerLease lease) async {
    try {
      final q = await lease.client.getQueue().timeout(
        const Duration(seconds: 3),
      );
      return q.runningCount * 100 + q.pendingCount;
    } catch (_) {
      // 探队列失败：仍可用，但优先级降低
      return 10 * 1000;
    }
  }

  Future<_ServerLease> acquire(Set<String> allowedUrls) async {
    if (allowedUrls.isEmpty) {
      throw StateError('没有可用的 ComfyUI 实例（请在设置里启用并确保在线）');
    }
    while (true) {
      final free = [
        for (final url in allowedUrls)
          if (_byUrl[url] case final lease? when !lease.busy) lease,
      ];
      if (free.isNotEmpty) {
        final best = await _pickLeastLoaded(free);
        if (!best.busy &&
            allowedUrls.contains(_comfyUrlKey(best.server.baseUrl))) {
          best.busy = true;
          return best;
        }
        continue;
      }
      final signal = Completer<void>();
      _wake.add(signal);
      await signal.future;
    }
  }

  void release(_ServerLease lease) {
    lease.busy = false;
    while (_wake.isNotEmpty) {
      final c = _wake.removeFirst();
      if (!c.isCompleted) c.complete();
    }
  }
}

/// 流水线内调用已有 Comfy 模板；默认打满所有已启用实例。
///
/// 租约走进程内共享池，多 Job 并行时互相可见占用。
class PipelineComfyRunner {
  PipelineComfyRunner(this.config);

  final PipelineConfig config;

  final _allowedUrls = <String>{};
  var _prepared = false;

  /// 在线且可用的实例数（prepare 后有效）。
  int get onlineServerCount => _allowedUrls.length;

  List<String> get onlineServerNames {
    final pool = _ComfyBucketPool.instance;
    return [
      for (final url in _allowedUrls)
        if (pool._byUrl[url] case final lease?)
          '${lease.server.name}(${lease.server.baseUrl})',
    ];
  }

  List<ComfyServer> _candidateServers() {
    final want = config.comfyServerId.trim();
    final candidates = <ComfyServer>[
      for (final s in AppConfig.instance.comfyServers)
        if (s.enabled && s.baseUrl.trim().isNotEmpty)
          if (want.isEmpty || s.id == want) s,
    ];
    if (candidates.isEmpty) {
      final sel = AppConfig.instance.comfySelectedServer;
      if (sel.baseUrl.trim().isNotEmpty) candidates.add(sel);
    }
    return candidates;
  }

  /// 探测并建立实例池。`comfyServerId` 非空时只用指定实例；否则用全部 enabled。
  Future<void> prepare() async {
    if (_prepared) return;
    final candidates = _candidateServers();
    final online = await _ComfyBucketPool.instance.ensureOnline(candidates);
    _allowedUrls
      ..clear()
      ..addAll({
        for (final s in online) _comfyUrlKey(s.server.baseUrl),
      });
    _prepared = true;
  }

  /// Job 结束不必拆共享连接；其它任务可能仍在用同一批实例。
  void close() {}

  Future<_ServerLease> _acquire() async {
    await prepare();
    if (_allowedUrls.isEmpty) {
      throw StateError('没有可用的 ComfyUI 实例（请在设置里启用并确保在线）');
    }
    return _ComfyBucketPool.instance.acquire(Set<String>.of(_allowedUrls));
  }

  void _release(_ServerLease lease) {
    _ComfyBucketPool.instance.release(lease);
  }

  Future<T> withServer<T>(
    Future<T> Function(ComfyClient client, ComfyServer server) body,
  ) async {
    final lease = await _acquire();
    try {
      return await body(lease.client, lease.server);
    } finally {
      _release(lease);
    }
  }

  /// 有效并行度：配置 >0 时取 min(配置, 在线数)；否则 = 在线实例数（打满桶）。
  Future<int> effectiveConcurrency() async {
    await prepare();
    if (_allowedUrls.isEmpty) return 1;
    final cfg = config.comfyConcurrency;
    if (cfg <= 0) return _allowedUrls.length;
    return cfg.clamp(1, _allowedUrls.length);
  }

  /// 派发用的 worker 数：略大于实例数，让空位一出现就被 waiter 接住。
  Future<int> dispatchWorkerCount(int itemCount) async {
    final slots = await effectiveConcurrency();
    if (itemCount <= 0) return 1;
    // worker 数 = min(任务数, max(slots, slots)) —— 实质打满 slots；
    // 多留 0：真正节流在 _acquire。这里用 slots 即可。
    return slots.clamp(1, itemCount);
  }

  Future<ComfyTemplate?> _template(String id) async {
    final tid = id.trim();
    if (tid.isEmpty) return null;
    final all = await ComfyTemplateStore.loadTemplates();
    for (final t in all) {
      if (t.id == tid) return t;
    }
    return null;
  }

  String _templateIdForRefKind(String kind) {
    switch (kind) {
      case 'scene':
        return config.refSceneTemplateId;
      case 'prop':
        return config.refPropTemplateId;
      case 'audio':
        return '';
      default:
        return config.refCharacterTemplateId;
    }
  }

  Future<String?> generateRef({
    required PipelineRefNode node,
    required String destDir,
  }) async {
    final templateId = _templateIdForRefKind(node.kind);
    return _runTemplateToFile(
      templateId: templateId,
      promptText: node.prompt.isNotEmpty ? node.prompt : node.title,
      destDir: destDir,
      preferredName: node.id,
    );
  }

  Future<String?> generateClip({
    required PipelineShotNode shot,
    required PipelineGraph graph,
    required String destDir,
  }) async {
    final imagePaths = <String>[];
    final audioPaths = <String>[];
    for (final id in shot.refIds) {
      for (final r in graph.refs) {
        if (r.id == id &&
            r.outputPath != null &&
            r.outputPath!.trim().isNotEmpty) {
          if (r.kind == 'audio') {
            audioPaths.add(r.outputPath!);
          } else {
            imagePaths.add(r.outputPath!);
          }
        }
      }
    }
    return _runTemplateToFile(
      templateId: config.shotVideoTemplateId,
      promptText: shot.prompt.isNotEmpty ? shot.prompt : shot.title,
      destDir: destDir,
      preferredName: shot.id,
      extraImagePaths: imagePaths,
      extraAudioPaths: audioPaths,
      durationSeconds: shot.duration,
    );
  }

  Future<String?> _runTemplateToFile({
    required String templateId,
    required String promptText,
    required String destDir,
    required String preferredName,
    List<String> extraImagePaths = const [],
    List<String> extraAudioPaths = const [],
    double? durationSeconds,
  }) async {
    final template = await _template(templateId);
    if (template == null) return null;

    return withServer((client, server) async {
      final online = await client.ping();
      if (!online) {
        throw ComfyApiException('无法连接 ComfyUI（${server.baseUrl}）');
      }

      final workflow = await ComfyTemplateStore.loadWorkflowMap(template);
      final nodes = template.nodes;
      final values = <String, dynamic>{};
      final enabled = <String, bool>{
        for (final n in nodes) n.nodeId: n.defaultEnabled,
      };

      var textFilled = false;
      var imageIdx = 0;
      var audioIdx = 0;
      for (final node in nodes) {
        final isLoaderNode = node.classType == 'LoadImage' ||
            node.classType == 'LoadAudio' ||
            node.classType == 'VHS_LoadVideo';
        for (final field in node.fields) {
          final w = field.widget;
          if (!textFilled && w == ComfyWidgetKind.multiline) {
            values[field.id] = promptText;
            textFilled = true;
          } else if (!textFilled &&
              w == ComfyWidgetKind.text &&
              !isLoaderNode) {
            values[field.id] = promptText;
            textFilled = true;
          } else if (w == ComfyWidgetKind.image &&
              imageIdx < extraImagePaths.length) {
            final file = File(extraImagePaths[imageIdx++]);
            if (await file.exists()) {
              final uploaded = await client.ensureInputFile(file);
              values[field.id] = uploaded.name;
            }
          } else if (w == ComfyWidgetKind.audio &&
              audioIdx < extraAudioPaths.length) {
            final file = File(extraAudioPaths[audioIdx++]);
            if (await file.exists()) {
              final uploaded = await client.ensureInputFile(file);
              values[field.id] = uploaded.name;
            }
          } else if (w == ComfyWidgetKind.float &&
              durationSeconds != null &&
              (node.label.toLowerCase().contains('duration') ||
                  field.label.contains('时长'))) {
            values[field.id] = durationSeconds;
          }
        }
      }

      for (final node in nodes) {
        final ct = node.classType;
        final isLoader =
            ct == 'LoadImage' || ct == 'LoadAudio' || ct == 'VHS_LoadVideo';
        if (!isLoader) continue;
        if (node.fields.any((f) => values.containsKey(f.id))) continue;
        enabled[node.nodeId] = false;
      }

      final prompt = ComfyDiscover.applyExposedValues(
        workflow,
        nodes,
        values,
        enabledByNode: enabled,
      );
      ComfyDiscover.randomizeSeedInputs(prompt);
      final history = await client.runPrompt(prompt);
      await Directory(destDir).create(recursive: true);
      final saved = await client.saveOutputsToDir(
        historyEntry: history,
        destDir: destDir,
        preferredFileName: preferredName,
      );
      if (saved.isEmpty) return null;
      return p.normalize(saved.first);
    });
  }

  bool get hasAnyRefTemplate =>
      config.refCharacterTemplateId.trim().isNotEmpty ||
      config.refSceneTemplateId.trim().isNotEmpty ||
      config.refPropTemplateId.trim().isNotEmpty;

  bool get hasVideoTemplate => config.shotVideoTemplateId.trim().isNotEmpty;
}

/// 有限并行执行；[concurrency] 为同时进行的任务数。
Future<void> pipelineMapPool<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) work,
) async {
  if (items.isEmpty) return;
  final n = concurrency.clamp(1, items.length);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= items.length) return;
      await work(items[i]);
    }
  }

  await Future.wait([for (var i = 0; i < n; i++) worker()]);
}

/// 带依赖的连续派发：谁先做完就立刻把下一个「依赖已满足」的任务塞进空闲槽，
/// 不再等整波结束（避免有空闲实例却干等）。
///
/// [work] 返回 true 表示该节点成功，可供下游依赖。
Future<void> pipelineDepsMapPool<T>({
  required List<T> items,
  required String Function(T item) idOf,
  required List<String> Function(T item) depsOf,
  required Set<String> initiallyDone,
  required int concurrency,
  required Future<bool> Function(T item) work,
}) async {
  if (items.isEmpty) return;
  final byId = <String, T>{for (final i in items) idOf(i): i};
  final pending = <String>{for (final i in items) idOf(i)};
  final done = <String>{...initiallyDone};
  final running = <String>{};
  final launched = <Future<void>>[];
  var wake = Completer<void>()..complete();
  final slots = concurrency.clamp(1, items.length);

  void kick() {
    if (!wake.isCompleted) wake.complete();
  }

  List<T> readyNow() {
    final out = <T>[];
    for (final id in pending) {
      if (running.contains(id)) continue;
      final item = byId[id];
      if (item == null) continue;
      final deps = depsOf(item);
      final ok = deps.every((d) => done.contains(d) || !byId.containsKey(d));
      if (ok) out.add(item);
    }
    return out;
  }

  while (pending.isNotEmpty || running.isNotEmpty) {
    var ready = readyNow();
    if (ready.isEmpty && running.isEmpty && pending.isNotEmpty) {
      // 依赖环 / 依赖失败：打破僵局，剩余直接派
      ready = [
        for (final id in pending)
          if (byId[id] case final item?) item,
      ];
    }

    while (running.length < slots && ready.isNotEmpty) {
      final item = ready.removeAt(0);
      final id = idOf(item);
      if (running.contains(id) || !pending.contains(id)) continue;
      running.add(id);
      launched.add(() async {
        try {
          final ok = await work(item);
          if (ok) done.add(id);
        } finally {
          running.remove(id);
          pending.remove(id);
          kick();
        }
      }());
    }

    if (pending.isEmpty && running.isEmpty) break;
    if (running.isEmpty) break;

    wake = Completer<void>();
    // 派发循环与 kick 之间可能丢信号：重建 wake 后再看一眼。
    if (running.length < slots && readyNow().isNotEmpty) {
      kick();
    }
    await wake.future;
  }

  await Future.wait(launched);
}
