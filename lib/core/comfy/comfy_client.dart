import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// ComfyUI HTTP API 客户端（桌面端，dart:io）。
class ComfyClient {
  ComfyClient({
    required this.baseUrl,
    this.apiKey,
  });

  final String baseUrl;
  final String? apiKey;

  final _http = HttpClient();

  String get _root {
    var u = baseUrl.trim();
    if (u.endsWith('/')) u = u.substring(0, u.length - 1);
    return u;
  }

  void close() => _http.close(force: true);

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = _root;
    final joined = path.startsWith('/') ? '$root$path' : '$root/$path';
    final base = Uri.parse(joined);
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: query);
  }

  Future<void> _auth(HttpClientRequest req) async {
    final key = apiKey?.trim();
    if (key != null && key.isNotEmpty) {
      req.headers.set('Authorization', 'Bearer $key');
    }
  }

  /// 探测服务是否可用。
  Future<bool> ping({Duration timeout = const Duration(seconds: 3)}) async {
    try {
      final req = await _http.getUrl(_uri('/system_stats')).timeout(timeout);
      await _auth(req);
      final res = await req.close().timeout(timeout);
      await res.drain<void>();
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      try {
        final req = await _http.getUrl(_uri('/queue')).timeout(timeout);
        await _auth(req);
        final res = await req.close().timeout(timeout);
        await res.drain<void>();
        return res.statusCode >= 200 && res.statusCode < 300;
      } catch (_) {
        return false;
      }
    }
  }

  /// 上传本地文件到 Comfy input，返回 Comfy 侧文件名。
  Future<String> uploadImage(File file, {String? overwriteName}) =>
      uploadInputFile(file, overwriteName: overwriteName);

  /// 通用 input 目录上传（图/音/视频均走 /upload/image）。
  Future<String> uploadInputFile(File file, {String? overwriteName}) async {
    final bytes = await file.readAsBytes();
    final filename = overwriteName ?? p.basename(file.path);
    final boundary = '----aireel${DateTime.now().millisecondsSinceEpoch}';

    final body = BytesBuilder();
    void writeStr(String s) => body.add(utf8.encode(s));

    writeStr('--$boundary\r\n');
    writeStr(
      'Content-Disposition: form-data; name="image"; '
      'filename="$filename"\r\n',
    );
    writeStr('Content-Type: application/octet-stream\r\n\r\n');
    body.add(bytes);
    writeStr('\r\n--$boundary\r\n');
    writeStr('Content-Disposition: form-data; name="overwrite"\r\n\r\n');
    writeStr('true\r\n');
    writeStr('--$boundary--\r\n');

    final req = await _http.postUrl(_uri('/upload/image'));
    await _auth(req);
    req.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    req.add(body.takeBytes());
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ComfyApiException('上传失败 (${res.statusCode}): $text');
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
    final name = map['name'] as String?;
    if (name == null || name.isEmpty) {
      throw ComfyApiException('上传响应缺少 name: $text');
    }
    return name;
  }

  static String createClientId() =>
      'aireel_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(1 << 20)}';

  Uri _wsUri(String clientId) {
    final root = Uri.parse(_root);
    final scheme = root.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: root.host,
      port: root.hasPort ? root.port : null,
      path: '/ws',
      queryParameters: {'clientId': clientId},
    );
  }

  /// 提交 prompt，返回 prompt_id。须与 WebSocket 使用同一 [clientId] 才能收到进度。
  Future<String> queuePrompt(
    Map<String, dynamic> workflow, {
    String? clientId,
  }) async {
    final cid = clientId ?? createClientId();
    final payload = {
      'prompt': workflow,
      'client_id': cid,
    };
    final req = await _http.postUrl(_uri('/prompt'));
    await _auth(req);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ComfyApiException('提交失败 (${res.statusCode}): $text');
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
    if (map['node_errors'] != null &&
        map['node_errors'] is Map &&
        (map['node_errors'] as Map).isNotEmpty) {
      throw ComfyApiException('节点错误: ${jsonEncode(map['node_errors'])}');
    }
    final id = map['prompt_id'] as String?;
    if (id == null || id.isEmpty) {
      throw ComfyApiException('响应缺少 prompt_id: $text');
    }
    return id;
  }

  /// 先连 WS，再提交并等待完成（含采样进度）。返回 history 条目。
  Future<Map<String, dynamic>> runPrompt(
    Map<String, dynamic> workflow, {
    Duration timeout = const Duration(minutes: 30),
    Duration pollInterval = const Duration(milliseconds: 900),
    ComfyCancelToken? cancelToken,
    void Function(ComfyRunStatus status)? onStatus,
    void Function(String promptId)? onPromptId,
  }) async {
    final clientId = createClientId();
    final started = DateTime.now();
    final completer = Completer<Map<String, dynamic>>();
    WebSocket? socket;
    StreamSubscription<dynamic>? sub;
    Timer? pollTimer;
    String? promptId;
    var phase = ComfyRunPhase.waiting;
    var progressValue = 0;
    var progressMax = 0;
    String? currentNodeId;
    var queueRemaining = 0;
    var pendingIndex = 0;

    void emit(String detail) {
      onStatus?.call(
        ComfyRunStatus(
          phase: phase,
          detail: detail,
          queuePosition: phase == ComfyRunPhase.queued ? pendingIndex : null,
          runningCount: phase == ComfyRunPhase.running ? 1 : 0,
          pendingCount: queueRemaining,
          elapsed: DateTime.now().difference(started),
          promptId: promptId,
          progressValue: progressValue,
          progressMax: progressMax,
          currentNodeId: currentNodeId,
        ),
      );
    }

    Future<void> completeWithHistory() async {
      final id = promptId;
      if (id == null) return;
      for (var i = 0; i < 40; i++) {
        if (completer.isCompleted) return;
        final hist = await getHistory(id);
        if (hist != null) {
          final status = hist['status'];
          if (status is Map && status['status_str'] == 'error') {
            final msgs = status['messages'];
            if (!completer.isCompleted) {
              completer.completeError(
                ComfyApiException(
                  'Comfy 执行失败: ${jsonEncode(msgs ?? status)}',
                ),
              );
            }
            return;
          }
          phase = ComfyRunPhase.completed;
          emit('执行完成');
          if (!completer.isCompleted) completer.complete(hist);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!completer.isCompleted) {
        completer.completeError(ComfyApiException('生成完成但无法读取 history'));
      }
    }

    void handleWsMessage(dynamic event) {
      if (event is! String) return; // 忽略预览二进制帧
      Map<String, dynamic>? msg;
      try {
        final decoded = jsonDecode(event);
        if (decoded is Map<String, dynamic>) {
          msg = decoded;
        } else if (decoded is Map) {
          msg = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {
        return;
      }
      if (msg == null) return;
      final type = msg['type']?.toString();
      final dataRaw = msg['data'];
      final data = dataRaw is Map
          ? Map<String, dynamic>.from(dataRaw)
          : <String, dynamic>{};

      if (type == 'status') {
        final status = data['status'];
        if (status is Map) {
          final exec = status['exec_info'];
          if (exec is Map) {
            queueRemaining =
                (exec['queue_remaining'] as num?)?.toInt() ?? queueRemaining;
          }
        }
        if (phase == ComfyRunPhase.queued || phase == ComfyRunPhase.waiting) {
          emit(
            queueRemaining > 0
                ? '排队中（队列剩余 $queueRemaining）'
                : '已提交，等待执行…',
          );
        }
        return;
      }

      final pid = data['prompt_id']?.toString();
      if (promptId != null && pid != null && pid != promptId) return;

      switch (type) {
        case 'execution_start':
          phase = ComfyRunPhase.running;
          emit('开始执行…');
        case 'executing':
          final node = data['node'];
          final nodeStr = node?.toString();
          if (node == null || nodeStr == null || nodeStr.isEmpty) {
            phase = ComfyRunPhase.completed;
            emit('执行完成，读取结果…');
            unawaited(completeWithHistory());
          } else {
            phase = ComfyRunPhase.running;
            currentNodeId = nodeStr;
            progressValue = 0;
            progressMax = 0;
            emit('执行节点 $nodeStr…');
          }
        case 'progress':
          phase = ComfyRunPhase.running;
          progressValue = (data['value'] as num?)?.toInt() ?? progressValue;
          progressMax = (data['max'] as num?)?.toInt() ?? progressMax;
          currentNodeId = data['node']?.toString() ?? currentNodeId;
          final pct = progressMax > 0
              ? (100 * progressValue / progressMax).round()
              : 0;
          final nodeHint =
              currentNodeId == null ? '' : '节点 $currentNodeId · ';
          emit('$nodeHint$progressValue / $progressMax（$pct%）');
        case 'progress_state':
          phase = ComfyRunPhase.running;
          final nodes = data['nodes'];
          if (nodes is Map) {
            var sumV = 0;
            var sumM = 0;
            String? runningNode;
            for (final entry in nodes.entries) {
              final n = entry.value;
              if (n is! Map) continue;
              final state = n['state']?.toString();
              final v = (n['value'] as num?)?.toInt() ?? 0;
              final m = (n['max'] as num?)?.toInt() ?? 0;
              if (state == 'running') {
                runningNode = entry.key.toString();
                progressValue = v;
                progressMax = m;
              }
              sumV += v;
              sumM += m;
            }
            if (runningNode != null) currentNodeId = runningNode;
            if (progressMax <= 0 && sumM > 0) {
              progressValue = sumV;
              progressMax = sumM;
            }
            final pct = progressMax > 0
                ? (100 * progressValue / progressMax).round()
                : 0;
            emit(
              currentNodeId == null
                  ? '执行中 $progressValue / $progressMax（$pct%）'
                  : '节点 $currentNodeId · $progressValue / $progressMax（$pct%）',
            );
          }
        case 'execution_success':
          phase = ComfyRunPhase.completed;
          emit('执行完成，读取结果…');
          unawaited(completeWithHistory());
        case 'execution_interrupted':
          if (!completer.isCompleted) {
            completer.completeError(const ComfyCancelledException());
          }
        case 'execution_error':
          final err = data['exception_message']?.toString() ??
              data['exception_type']?.toString() ??
              jsonEncode(data);
          if (!completer.isCompleted) {
            completer.completeError(ComfyApiException('Comfy 执行失败: $err'));
          }
        default:
          break;
      }
    }

    try {
      phase = ComfyRunPhase.waiting;
      emit('连接进度通道…');
      final headers = <String, dynamic>{};
      final key = apiKey?.trim();
      if (key != null && key.isNotEmpty) {
        headers['Authorization'] = 'Bearer $key';
      }
      try {
        socket = await WebSocket.connect(
          _wsUri(clientId).toString(),
          headers: headers.isEmpty ? null : headers,
        ).timeout(const Duration(seconds: 8));
        sub = socket.listen(
          handleWsMessage,
          onError: (Object e) {},
          onDone: () {},
          cancelOnError: false,
        );
      } catch (_) {
        // WS 不可用时退化为 HTTP 队列轮询（仍可完成，只是进度较弱）。
        socket = null;
        emit('进度通道不可用，改用队列轮询…');
      }

      if (cancelToken?.isCancelled == true) {
        throw const ComfyCancelledException();
      }

      phase = ComfyRunPhase.queued;
      emit('提交工作流…');
      final submittedId = await queuePrompt(workflow, clientId: clientId);
      promptId = submittedId;
      onPromptId?.call(submittedId);
      emit(
        queueRemaining > 0
            ? '排队中（队列剩余 $queueRemaining）'
            : '已提交，等待执行…',
      );

      pollTimer = Timer.periodic(pollInterval, (_) async {
        if (completer.isCompleted) return;
        if (cancelToken?.isCancelled == true) {
          final id = promptId;
          if (id != null) await _tryCancelPrompt(id);
          if (!completer.isCompleted) {
            completer.completeError(const ComfyCancelledException());
          }
          return;
        }
        final id = promptId;
        if (id == null) return;

        try {
          final hist = await getHistory(id);
          if (hist != null && !completer.isCompleted) {
            final status = hist['status'];
            if (status is Map && status['status_str'] == 'error') {
              final msgs = status['messages'];
              completer.completeError(
                ComfyApiException(
                  'Comfy 执行失败: ${jsonEncode(msgs ?? status)}',
                ),
              );
              return;
            }
            // 仅在已不在队列中时把 history 当完成，避免个别版本提前写入 history。
            try {
              final q = await getQueue();
              final p = q.phaseOf(id);
              if (p == ComfyRunPhase.waiting) {
                phase = ComfyRunPhase.completed;
                emit('执行完成');
                completer.complete(hist);
                return;
              }
              if (p == ComfyRunPhase.running && phase != ComfyRunPhase.running) {
                phase = ComfyRunPhase.running;
                emit('正在执行…');
              } else if (p == ComfyRunPhase.queued) {
                phase = ComfyRunPhase.queued;
                pendingIndex = q.pendingIndexOf(id) ?? 0;
                queueRemaining = q.pendingCount;
                emit(
                  pendingIndex <= 0
                      ? '排队中（即将执行，前有 0 个）'
                      : '排队中（第 ${pendingIndex + 1} 位，前有 $pendingIndex 个）',
                );
              }
            } catch (_) {
              phase = ComfyRunPhase.completed;
              emit('执行完成');
              completer.complete(hist);
            }
            return;
          }

          final q = await getQueue();
          final p = q.phaseOf(id);
          queueRemaining = q.pendingCount;
          if (p == ComfyRunPhase.running) {
            if (phase != ComfyRunPhase.running) {
              phase = ComfyRunPhase.running;
              emit('正在执行…');
            }
          } else if (p == ComfyRunPhase.queued) {
            phase = ComfyRunPhase.queued;
            pendingIndex = q.pendingIndexOf(id) ?? 0;
            emit(
              pendingIndex <= 0
                  ? '排队中…'
                  : '排队中（第 ${pendingIndex + 1} 位，前有 $pendingIndex 个）',
            );
          }
        } catch (_) {}
      });

      return await completer.future.timeout(
        timeout,
        onTimeout: () => throw ComfyApiException('等待生成超时 ($promptId)'),
      );
    } on ComfyCancelledException {
      final id = promptId;
      if (id != null) await _tryCancelPrompt(id);
      rethrow;
    } finally {
      pollTimer?.cancel();
      await sub?.cancel();
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  /// 中断当前正在执行的任务。
  Future<void> interrupt() async {
    final req = await _http.postUrl(_uri('/interrupt'));
    await _auth(req);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode('{}'));
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ComfyApiException('中断失败 (${res.statusCode})');
    }
  }

  /// 从队列删除指定 prompt（排队中或刚提交的）。
  Future<void> deleteFromQueue(List<String> promptIds) async {
    if (promptIds.isEmpty) return;
    final req = await _http.postUrl(_uri('/queue'));
    await _auth(req);
    req.headers.contentType = ContentType.json;
    req.add(utf8.encode(jsonEncode({'delete': promptIds})));
    final res = await req.close();
    await res.drain<void>();
  }

  /// 读取队列快照。
  Future<ComfyQueueSnapshot> getQueue() async {
    final req = await _http.getUrl(_uri('/queue'));
    await _auth(req);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ComfyApiException('读取队列失败 (${res.statusCode}): $text');
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
    return ComfyQueueSnapshot.fromJson(map);
  }

  /// 轮询直到完成、取消或超时，返回 history 条目。
  Future<Map<String, dynamic>> waitForPrompt(
    String promptId, {
    Duration timeout = const Duration(minutes: 30),
    Duration interval = const Duration(milliseconds: 700),
    ComfyCancelToken? cancelToken,
    void Function(ComfyRunStatus status)? onStatus,
  }) async {
    final deadline = DateTime.now().add(timeout);
    final started = DateTime.now();
    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCancelled == true) {
        await _tryCancelPrompt(promptId);
        throw const ComfyCancelledException();
      }

      final hist = await getHistory(promptId);
      if (hist != null) {
        // 检查是否失败
        final status = hist['status'];
        if (status is Map && status['status_str'] == 'error') {
          final msgs = status['messages'];
          throw ComfyApiException('Comfy 执行失败: ${jsonEncode(msgs ?? status)}');
        }
        onStatus?.call(
          ComfyRunStatus(
            phase: ComfyRunPhase.completed,
            detail: '执行完成',
            elapsed: DateTime.now().difference(started),
            promptId: promptId,
          ),
        );
        return hist;
      }

      ComfyQueueSnapshot? queue;
      try {
        queue = await getQueue();
      } catch (_) {}

      final phase = queue?.phaseOf(promptId) ?? ComfyRunPhase.waiting;
      final pos = queue?.pendingIndexOf(promptId);
      final detail = switch (phase) {
        ComfyRunPhase.running => '正在执行…',
        ComfyRunPhase.queued => pos == null
            ? '排队中…'
            : '排队中（第 ${pos + 1} 位，前有 $pos 个）',
        ComfyRunPhase.waiting => '等待 Comfy 响应…',
        ComfyRunPhase.completed => '完成',
        ComfyRunPhase.cancelled => '已取消',
      };

      onStatus?.call(
        ComfyRunStatus(
          phase: phase,
          detail: detail,
          queuePosition: pos,
          runningCount: queue?.runningCount ?? 0,
          pendingCount: queue?.pendingCount ?? 0,
          elapsed: DateTime.now().difference(started),
          promptId: promptId,
        ),
      );

      await Future<void>.delayed(interval);
    }
    throw ComfyApiException('等待生成超时 ($promptId)');
  }

  Future<void> _tryCancelPrompt(String promptId) async {
    try {
      await interrupt();
    } catch (_) {}
    try {
      await deleteFromQueue([promptId]);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> getHistory(String promptId) async {
    final req = await _http.getUrl(_uri('/history/$promptId'));
    await _auth(req);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return null;
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ComfyApiException('history 失败 (${res.statusCode}): $text');
    }
    final map = jsonDecode(text) as Map<String, dynamic>;
    final entry = map[promptId];
    if (entry is Map<String, dynamic>) return entry;
    if (entry is Map) return Map<String, dynamic>.from(entry);
    return null;
  }

  /// 从 history 条目收集 outputs 里的图片/视频。
  static List<ComfyOutputFile> collectOutputs(Map<String, dynamic> historyEntry) {
    final outputs = historyEntry['outputs'];
    if (outputs is! Map) return const [];
    final files = <ComfyOutputFile>[];
    for (final nodeOut in outputs.values) {
      if (nodeOut is! Map) continue;
      for (final key in ['images', 'gifs', 'videos']) {
        final list = nodeOut[key];
        if (list is! List) continue;
        for (final item in list) {
          if (item is! Map) continue;
          final filename = item['filename']?.toString();
          if (filename == null || filename.isEmpty) continue;
          files.add(
            ComfyOutputFile(
              filename: filename,
              subfolder: item['subfolder']?.toString() ?? '',
              type: item['type']?.toString() ?? 'output',
            ),
          );
        }
      }
    }
    return files;
  }

  Future<Uint8List> downloadView(ComfyOutputFile file) async {
    final req = await _http.getUrl(
      _uri('/view', {
        'filename': file.filename,
        'subfolder': file.subfolder,
        'type': file.type,
      }),
    );
    await _auth(req);
    final res = await req.close();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final text = await res.transform(utf8.decoder).join();
      throw ComfyApiException('下载失败 (${res.statusCode}): $text');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 下载全部输出到 [destDir]，返回写入的绝对路径。
  Future<List<String>> saveOutputsToDir({
    required Map<String, dynamic> historyEntry,
    required String destDir,
  }) async {
    final outs = collectOutputs(historyEntry);
    if (outs.isEmpty) {
      throw ComfyApiException('生成完成但没有可下载的输出文件');
    }
    final dir = Directory(destDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final saved = <String>[];
    for (final o in outs) {
      final bytes = await downloadView(o);
      final target = _uniquePath(destDir, o.filename);
      await File(target).writeAsBytes(bytes, flush: true);
      saved.add(target);
    }
    return saved;
  }

  static String _uniquePath(String dir, String filename) {
    final base = p.basenameWithoutExtension(filename);
    final ext = p.extension(filename);
    var candidate = p.join(dir, filename);
    if (!File(candidate).existsSync()) return candidate;
    for (var i = 1; i < 1000; i++) {
      candidate = p.join(dir, '${base}_$i$ext');
      if (!File(candidate).existsSync()) return candidate;
    }
    return p.join(
      dir,
      '${base}_${DateTime.now().millisecondsSinceEpoch}$ext',
    );
  }
}

class ComfyOutputFile {
  final String filename;
  final String subfolder;
  final String type;

  const ComfyOutputFile({
    required this.filename,
    required this.subfolder,
    required this.type,
  });
}

enum ComfyRunPhase { waiting, queued, running, completed, cancelled }

class ComfyRunStatus {
  final ComfyRunPhase phase;
  final String detail;
  final int? queuePosition;
  final int runningCount;
  final int pendingCount;
  final Duration elapsed;
  final String? promptId;
  final int progressValue;
  final int progressMax;
  final String? currentNodeId;

  const ComfyRunStatus({
    required this.phase,
    required this.detail,
    this.queuePosition,
    this.runningCount = 0,
    this.pendingCount = 0,
    this.elapsed = Duration.zero,
    this.promptId,
    this.progressValue = 0,
    this.progressMax = 0,
    this.currentNodeId,
  });

  double? get progressFraction {
    if (progressMax <= 0) return null;
    return (progressValue / progressMax).clamp(0.0, 1.0);
  }

  String get progressLabel {
    if (progressMax <= 0) return '';
    final pct = (100 * progressValue / progressMax).round();
    return '$progressValue / $progressMax（$pct%）';
  }

  String get elapsedLabel {
    final s = elapsed.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    if (m <= 0) return '${r}s';
    return '${m}m ${r.toString().padLeft(2, '0')}s';
  }
}

class ComfyQueueSnapshot {
  final List<String> runningIds;
  final List<String> pendingIds;

  const ComfyQueueSnapshot({
    this.runningIds = const [],
    this.pendingIds = const [],
  });

  int get runningCount => runningIds.length;
  int get pendingCount => pendingIds.length;

  factory ComfyQueueSnapshot.fromJson(Map<String, dynamic> json) {
    String? idOf(dynamic item) {
      // Classic: [number, prompt_id, prompt, extra_data, outputs...]
      if (item is List && item.isNotEmpty) {
        if (item.length >= 2) {
          final second = item[1];
          if (second is String && second.isNotEmpty) return second;
          if (second is num) return second.toString();
          if (second is Map) {
            return second['prompt_id']?.toString() ??
                second['id']?.toString();
          }
        }
        final first = item[0];
        if (first is String && first.contains('-')) return first;
      }
      if (item is Map) {
        return item['prompt_id']?.toString() ??
            item['id']?.toString() ??
            item['promptId']?.toString();
      }
      return null;
    }

    final running = <String>[];
    final pending = <String>[];
    final rawRun = json['queue_running'];
    if (rawRun is List) {
      for (final e in rawRun) {
        final id = idOf(e);
        if (id != null && id.isNotEmpty) running.add(id);
      }
    }
    final rawPend = json['queue_pending'];
    if (rawPend is List) {
      for (final e in rawPend) {
        final id = idOf(e);
        if (id != null && id.isNotEmpty) pending.add(id);
      }
    }
    return ComfyQueueSnapshot(runningIds: running, pendingIds: pending);
  }

  ComfyRunPhase phaseOf(String promptId) {
    if (runningIds.contains(promptId)) return ComfyRunPhase.running;
    if (pendingIds.contains(promptId)) return ComfyRunPhase.queued;
    return ComfyRunPhase.waiting;
  }

  int? pendingIndexOf(String promptId) {
    final i = pendingIds.indexOf(promptId);
    return i >= 0 ? i : null;
  }
}

class ComfyCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ComfyCancelledException implements Exception {
  const ComfyCancelledException();
  @override
  String toString() => '已取消生成';
}

class ComfyApiException implements Exception {
  final String message;
  ComfyApiException(this.message);
  @override
  String toString() => message;
}
