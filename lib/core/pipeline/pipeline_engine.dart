import 'dart:async';

import 'package:path/path.dart' as p;

import '../text_file_io.dart';
import 'pipeline_assets.dart';
import 'pipeline_comfy.dart';
import 'pipeline_host.dart';
import 'pipeline_models.dart';
import 'pipeline_store.dart';

/// 无人值守推进 Job：Comfy 段自跑，review 段停在 waiting_agent。
class PipelineEngine {
  PipelineEngine._();
  static final PipelineEngine instance = PipelineEngine._();

  final _store = PipelineStore.instance;
  final _running = <String>{};
  final _cancelRequested = <String>{};
  final _listeners = <void Function()>[];
  String? lastError;
  Timer? _uiNotifyTimer;
  var _uiNotifyDirty = false;

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);

  void _notify() {
    for (final fn in List.of(_listeners)) {
      try {
        fn();
      } catch (_) {}
    }
  }

  /// 批量生成时节流 UI 刷新，避免狂刷导致整窗点不动。
  void _notifyUiThrottled({Duration every = const Duration(seconds: 2)}) {
    _uiNotifyDirty = true;
    if (_uiNotifyTimer?.isActive == true) return;
    _uiNotifyTimer = Timer(every, () {
      if (!_uiNotifyDirty) return;
      _uiNotifyDirty = false;
      _notify();
    });
  }

  void _notifyUiNow() {
    _uiNotifyTimer?.cancel();
    _uiNotifyDirty = false;
    _notify();
  }

  bool isRunning(String jobId) => _running.contains(jobId);
  bool isCancelRequested(String jobId) => _cancelRequested.contains(jobId);

  Future<PipelineJob> createJob({
    required PipelineIntent intent,
    required String chapterPath,
    String? sceneId,
    String userBrief = '',
  }) async {
    final job = await _store.createJob(
      intent: intent,
      chapterPath: chapterPath,
      sceneId: sceneId,
      userBrief: userBrief,
    );
    _notify();
    return job;
  }

  Future<PipelineJob> submitGraph({
    required String jobId,
    required PipelineGraph graph,
    String? storyboardDir,
    bool reuseExisting = true,
    bool force = false,
  }) async {
    final job = await _ensureControllable(jobId, force: force);
    var reused = 0;
    if (reuseExisting && graph.refs.isNotEmpty) {
      final matches = await PipelineAssets.instance.resolveRefs(graph.refs);
      await PipelineAssets.instance.applyMatchesToGraph(graph, matches);
      reused = matches.where((m) => m.reason != 'already_set').length;
    }
    await _store.saveGraph(jobId, graph);
    if (storyboardDir != null && storyboardDir.trim().isNotEmpty) {
      job.storyboardDir = storyboardDir.trim();
    }
    final step = job.stepById('authoring');
    if (step != null) {
      step.status = PipelineStepStatus.succeeded;
      step.finishedAt = DateTime.now().toUtc();
      step.detail =
          'refs=${graph.refs.length} shots=${graph.shots.length} reused=$reused';
    }
    // 若参考图已全部 ready，可跳过 gen_refs 直进 review（或再进 clips）。
    final needGen = graph.refs.any((r) =>
        r.status != 'ready' &&
        r.status != 'skipped' &&
        (r.outputPath == null || r.outputPath!.trim().isEmpty));
    _setCurrentStep(
      job,
      needGen ? 'gen_refs' : 'review_refs',
      skipReason: needGen ? '已跳过' : '全部复用，无需生成',
    );
    job.status = PipelineJobStatus.queued;
    job.error = null;
    await _store.saveJob(job);
    await _store.appendEvent(jobId, 'graph_submitted', {
      'refs': graph.refs.length,
      'shots': graph.shots.length,
      'reused': reused,
      'needGenRefs': needGen,
    });
    _notify();
    // 提交 graph 后自动开跑，避免 Agent 忘了再调 run_job 导致一直停在排队。
    unawaited(_drive(jobId));
    return job;
  }

  /// 拒绝驱动/改写其它机器创建的 Job（除非 [force]）。
  Future<PipelineJob> _ensureControllable(
    String jobId, {
    bool force = false,
    bool claimLegacy = true,
  }) async {
    final job = await _store.loadJob(jobId);
    final host = job.hostId?.trim() ?? '';
    if (host.isEmpty) {
      if (claimLegacy) {
        job.hostId = PipelineHost.id;
        await _store.saveJob(job);
      }
      return job;
    }
    if (PipelineHost.isMine(host) || force) return job;
    throw StateError(
      'Job $jobId 属于其它机器 ($host)，本机为 ${PipelineHost.id}。'
      '请只操作本机任务（GET /pipeline/jobs 默认 scope=mine）。'
      '确认接管时传 force:true。',
    );
  }

  /// Agent 确认当前 waiting_agent 步骤已完成并推进。
  /// - review_refs / review_clips：等价于全量 pass 的 submit_review_batch
  /// - authoring：必须先 submit_graph，不能空 ack
  Future<PipelineJob> ackAgentStep(String jobId, {bool force = false}) async {
    final job = await _ensureControllable(jobId, force: force);
    if (job.status == PipelineJobStatus.queued ||
        job.status == PipelineJobStatus.running ||
        job.status == PipelineJobStatus.waitingComfy) {
      unawaited(_drive(jobId));
      return _store.loadJob(jobId);
    }
    if (job.status != PipelineJobStatus.waitingAgent) {
      throw StateError(
        '当前状态无需 ack：${pipelineJobStatusName(job.status)}'
        '（仅 waiting_agent 需要 Agent 回写）',
      );
    }
    final stepId = job.currentStepId ?? '';
    if (stepId == 'authoring') {
      throw StateError(
        'authoring 阶段请 POST /pipeline/submit_graph 提交分镜 graph，'
        '不能只用 ack 空推',
      );
    }
    if (stepId == 'review_refs' || stepId == 'review_clips') {
      return submitReviewBatch(
        jobId: jobId,
        phase: stepId == 'review_refs' ? 'refs' : 'clips',
        items: const [],
        force: force,
      );
    }
    throw StateError('未知 waiting_agent 步骤: $stepId');
  }

  /// 开始/继续推进；Comfy 段异步跑，review 段进入 waiting_agent。
  Future<PipelineJob> runJob(String jobId, {bool force = false}) async {
    if (_running.contains(jobId)) {
      return _store.loadJob(jobId);
    }
    final job = await _ensureControllable(jobId, force: force);
    if (job.status == PipelineJobStatus.cancelled ||
        job.status == PipelineJobStatus.succeeded) {
      return job;
    }
    unawaited(_drive(jobId));
    return _store.loadJob(jobId);
  }

  Future<PipelineJob> cancelJob(String jobId, {bool force = false}) async {
    _cancelRequested.add(jobId);
    final job = await _ensureControllable(jobId, force: force);
    if (_isTerminal(job.status)) {
      _cancelRequested.remove(jobId);
      return job;
    }
    job.status = PipelineJobStatus.cancelled;
    job.error = '已取消';
    final cur = job.currentStep;
    if (cur != null &&
        (cur.status == PipelineStepStatus.running ||
            cur.status == PipelineStepStatus.waiting)) {
      cur.status = PipelineStepStatus.failed;
      cur.error = 'cancelled';
      cur.finishedAt = DateTime.now().toUtc();
    }
    await _store.saveJob(job);
    await _store.appendEvent(jobId, 'cancelled', {});
    _running.remove(jobId);
    _notifyUiNow();
    return job;
  }

  /// 删除 Job 记录；若仍在跑会先取消。不删除剧目录物料。
  Future<void> deleteJob(String jobId, {bool force = false}) async {
    await _ensureControllable(jobId, force: force, claimLegacy: false);
    if (_running.contains(jobId)) {
      try {
        await cancelJob(jobId, force: force);
      } catch (_) {}
      // 等驱动协程退出
      for (var i = 0; i < 20 && _running.contains(jobId); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    await _store.deleteJob(jobId);
    _running.remove(jobId);
    _notify();
  }

  bool _isTerminal(PipelineJobStatus s) =>
      s == PipelineJobStatus.succeeded ||
      s == PipelineJobStatus.failed ||
      s == PipelineJobStatus.cancelled;

  bool isCancellable(PipelineJobStatus s) => !_isTerminal(s);

  Future<PipelineJob> submitReviewBatch({
    required String jobId,
    required String phase, // refs | clips
    required List<PipelineReviewItem> items,
    bool force = false,
  }) async {
    final job = await _ensureControllable(jobId, force: force);
    final graph = await _store.loadGraph(jobId);
    final cfg = await _store.loadConfig();
    final isRefs = phase == 'refs' || phase == 'review_refs';

    // items 为空 = Agent 确认当前阶段全部通过（常见漏传清单导致状态不更新）
    var reviewItems = items;
    if (reviewItems.isEmpty) {
      if (isRefs) {
        reviewItems = [
          for (final r in graph.refs)
            if (r.status != 'skipped')
              PipelineReviewItem(
                id: r.id,
                pass: true,
                note: 'agent_pass_all',
              ),
        ];
      } else {
        reviewItems = [
          for (final s in graph.shots)
            if (s.status != 'skipped')
              PipelineReviewItem(
                id: s.id,
                pass: true,
                note: 'agent_pass_all',
              ),
        ];
      }
    }

    var failCount = 0;
    for (final item in reviewItems) {
      if (isRefs) {
        for (final r in graph.refs) {
          if (r.id != item.id) continue;
          if (item.pass) {
            r.status = 'ready';
            r.reviewNote = item.note;
          } else {
            failCount++;
            r.status = 'pending';
            r.reviewNote = item.note;
            r.round += 1;
            if (item.newPrompt != null && item.newPrompt!.trim().isNotEmpty) {
              r.prompt = item.newPrompt!.trim();
            }
            r.outputPath = null;
          }
        }
      } else {
        for (final s in graph.shots) {
          if (s.id != item.id) continue;
          if (item.pass) {
            s.status = 'ready';
            s.reviewNote = item.note;
          } else {
            failCount++;
            s.status = 'pending';
            s.reviewNote = item.note;
            s.round += 1;
            if (item.newPrompt != null && item.newPrompt!.trim().isNotEmpty) {
              s.prompt = item.newPrompt!.trim();
            }
            s.outputPath = null;
          }
        }
      }
    }
    await _store.saveGraph(jobId, graph);

    final stepId = isRefs ? 'review_refs' : 'review_clips';
    final step = job.stepById(stepId);
    if (step != null) {
      step.status = PipelineStepStatus.succeeded;
      step.finishedAt = DateTime.now().toUtc();
      step.detail =
          'pass=${reviewItems.length - failCount} fail=$failCount';
    }

    // 不设轮次上限：未通过就继续进 retry，交给智能体反复操作。
    if (failCount > 0) {
      if (isRefs) {
        _ensureStep(job, 'gen_refs_retry', PipelineStepType.genRefsRetry);
        _setCurrentStep(job, 'gen_refs_retry');
      } else {
        _ensureStep(job, 'gen_clips_retry', PipelineStepType.genClipsRetry);
        _setCurrentStep(job, 'gen_clips_retry');
      }
      job.status = PipelineJobStatus.queued;
      job.error = null;
    } else if (isRefs) {
      if (job.intent == PipelineIntent.refOnly) {
        _setCurrentStep(job, 'finalize', skipReason: '仅参考图，跳过视频');
        job.status = PipelineJobStatus.queued;
      } else if (cfg.beforeFirstVideoGate) {
        job.status = PipelineJobStatus.waitingHuman;
        _setCurrentStep(job, 'gen_clips');
        job.error = '参考图已通过；gates.beforeFirstVideo=true，等待人工放行';
      } else {
        _setCurrentStep(job, 'gen_clips');
        job.status = PipelineJobStatus.queued;
      }
    } else {
      _setCurrentStep(job, 'finalize');
      job.status = PipelineJobStatus.queued;
    }

    await _store.saveJob(job);
    await _store.appendEvent(jobId, 'review_submitted', {
      'phase': phase,
      'fail': failCount,
    });
    _notify();
    if (job.status == PipelineJobStatus.queued) {
      unawaited(_drive(jobId));
    }
    return job;
  }

  Future<PipelineJob> reviseScene({
    required String jobId,
    required String sceneId,
    required String feedback,
    String? newPrompt,
    bool force = false,
  }) async {
    final job = await _ensureControllable(jobId, force: force);
    final graph = await _store.loadGraph(jobId);
    PipelineShotNode? shot;
    for (final s in graph.shots) {
      if (s.id == sceneId || s.title.contains(sceneId)) {
        shot = s;
        break;
      }
    }
    if (shot == null) {
      throw StateError('未找到场景: $sceneId');
    }
    shot.status = 'pending';
    shot.reviewNote = feedback;
    shot.round = 0;
    if (newPrompt != null && newPrompt.trim().isNotEmpty) {
      shot.prompt = newPrompt.trim();
    } else if (feedback.trim().isNotEmpty) {
      shot.prompt = '${shot.prompt}\n\n【返修】$feedback'.trim();
    }
    shot.outputPath = null;
    await _store.saveGraph(jobId, graph);

    _ensureStep(job, 'revise', PipelineStepType.revise);
    final rev = job.stepById('revise')!;
    rev.status = PipelineStepStatus.pending;
    rev.detail = 'scene=$sceneId';
    rev.error = null;
    rev.startedAt = null;
    rev.finishedAt = null;

    job.intent = PipelineIntent.sceneRevise;
    job.sceneId = shot.id;
    _setCurrentStep(job, 'revise', skipReason: '返修跳过');
    job.status = PipelineJobStatus.queued;
    job.error = null;
    await _store.saveJob(job);
    await _store.appendEvent(jobId, 'revise_scene', {
      'sceneId': shot.id,
      'feedback': feedback,
    });
    _notify();
    unawaited(_drive(jobId));
    return job;
  }

  /// 纠正历史任务：已越过但仍停在「待开始」的步骤 → 已跳过。
  bool _healSkippedSteps(PipelineJob job) {
    final cur = job.currentStepId?.trim() ?? '';
    if (cur.isEmpty) return false;
    final before = [
      for (final s in job.steps) '${s.id}:${pipelineStepStatusName(s.status)}',
    ].join('|');
    _setCurrentStep(job, cur);
    // 已成功任务：收尾后再扫一遍未用的 pending
    if (job.status == PipelineJobStatus.succeeded) {
      for (final s in job.steps) {
        _skipIfPending(s, '未执行');
      }
    }
    final after = [
      for (final s in job.steps) '${s.id}:${pipelineStepStatusName(s.status)}',
    ].join('|');
    return before != after;
  }

  Future<Map<String, dynamic>> getJobSnapshot(String jobId) async {
    final job = await _store.loadJob(jobId);
    final graph = await _store.loadGraph(jobId);
    if (_healSkippedSteps(job)) {
      await _store.saveJob(job);
    }
    String? scriptRoot;
    String? refsDir;
    String? clipsTempDir;
    String? materialsDir;
    String? storyboardRoot;
    String? workdirError;
    try {
      scriptRoot = _store.resolveScriptRoot(job.chapterPath);
      refsDir = _store.refsDirForJob(job);
      clipsTempDir = _store.clipsTempDirForJob(job);
      storyboardRoot = _store.storyboardRootForJob(job);
      materialsDir = _store.materialsDirForJob(job);
    } catch (e) {
      // 他机任务 / NAS 路径失效时仍返回 job，便于取消或删除。
      workdirError = e.toString();
    }
    return {
      'job': job.toJson(),
      'graph': graph.toJson(),
      'running': _running.contains(jobId),
      'localRunning': _running.contains(jobId),
      'scriptRoot': scriptRoot,
      'refsDir': refsDir,
      // 兼容旧字段：clipsDir = 临时成片
      'clipsDir': clipsTempDir,
      'clipsTempDir': clipsTempDir,
      'storyboardRoot': storyboardRoot,
      'materialsDir': materialsDir,
      'workdirError': workdirError,
      'hostId': PipelineHost.id,
      'mine': PipelineHost.isMine(job.hostId),
    };
  }

  void _ensureStep(PipelineJob job, String id, PipelineStepType type) {
    if (job.stepById(id) != null) return;
    job.steps.add(PipelineStep(id: id, type: type));
  }

  static const _mainStepOrder = <String>[
    'authoring',
    'gen_refs',
    'review_refs',
    'gen_clips',
    'review_clips',
    'finalize',
  ];

  int _stepOrderIndex(String id) => switch (id) {
        'gen_refs_retry' => _mainStepOrder.indexOf('gen_refs'),
        'gen_clips_retry' => _mainStepOrder.indexOf('gen_clips'),
        // 返修插队：此前未跑过的主步骤标为跳过
        'revise' => _mainStepOrder.indexOf('finalize'),
        _ => _mainStepOrder.indexOf(id),
      };

  void _skipIfPending(PipelineStep? step, String reason) {
    if (step == null) return;
    if (step.status != PipelineStepStatus.pending) return;
    step.status = PipelineStepStatus.skipped;
    if (step.detail.trim().isEmpty) step.detail = reason;
    step.finishedAt ??= DateTime.now().toUtc();
  }

  /// 推进到 [nextId] 时，把仍停在「待开始」的前置步骤标成已跳过。
  void _setCurrentStep(
    PipelineJob job,
    String nextId, {
    String skipReason = '已跳过',
  }) {
    final nextIdx = _stepOrderIndex(nextId);
    if (nextIdx >= 0) {
      for (var i = 0; i < nextIdx; i++) {
        _skipIfPending(job.stepById(_mainStepOrder[i]), skipReason);
      }
    }
    final refsIdx = _mainStepOrder.indexOf('gen_refs');
    final clipsIdx = _mainStepOrder.indexOf('gen_clips');
    if (nextId != 'gen_refs_retry' &&
        (nextIdx < 0 || nextIdx > refsIdx || nextId == 'finalize')) {
      _skipIfPending(job.stepById('gen_refs_retry'), skipReason);
    }
    if (nextId != 'gen_clips_retry' &&
        (nextIdx < 0 || nextIdx > clipsIdx || nextId == 'finalize')) {
      _skipIfPending(job.stepById('gen_clips_retry'), skipReason);
    }
    if (nextId == 'finalize') {
      _skipIfPending(job.stepById('revise'), skipReason);
    }
    job.currentStepId = nextId;
  }

  Future<void> _drive(String jobId) async {
    if (!_running.add(jobId)) return;
    _cancelRequested.remove(jobId);
    _notifyUiNow();
    try {
      while (true) {
        if (_cancelRequested.contains(jobId)) break;
        var job = await _store.loadJob(jobId);
        if (job.status == PipelineJobStatus.cancelled ||
            job.status == PipelineJobStatus.succeeded ||
            job.status == PipelineJobStatus.failed ||
            job.status == PipelineJobStatus.failedNeedsHuman ||
            job.status == PipelineJobStatus.waitingHuman ||
            job.status == PipelineJobStatus.waitingAgent) {
          break;
        }

        final stepId = job.currentStepId ?? 'authoring';
        switch (stepId) {
          case 'authoring':
            await _markWaitingAgent(job, 'authoring', '等待 Agent 提交 graph');
            return;
          case 'gen_refs':
          case 'gen_refs_retry':
            await _runGenRefs(job);
            break;
          case 'review_refs':
            await _markWaitingAgent(job, 'review_refs', '等待 Agent 批量自检参考图');
            return;
          case 'gen_clips':
          case 'gen_clips_retry':
            await _runGenClips(job);
            break;
          case 'review_clips':
            await _markWaitingAgent(job, 'review_clips', '等待 Agent 粗检视频');
            return;
          case 'revise':
            await _runRevise(job);
            break;
          case 'finalize':
            await _runFinalize(job);
            return;
          default:
            job.status = PipelineJobStatus.failed;
            job.error = '未知步骤: $stepId';
            await _store.saveJob(job);
            return;
        }
      }
    } catch (e) {
      lastError = '$e';
      try {
        final job = await _store.loadJob(jobId);
        job.status = PipelineJobStatus.failed;
        job.error = '$e';
        final cur = job.currentStep;
        if (cur != null) {
          cur.status = PipelineStepStatus.failed;
          cur.error = '$e';
          cur.finishedAt = DateTime.now().toUtc();
        }
        await _store.saveJob(job);
        await _store.appendEvent(jobId, 'error', {'message': '$e'});
      } catch (_) {}
    } finally {
      _running.remove(jobId);
      _cancelRequested.remove(jobId);
      _notifyUiNow();
    }
  }

  Future<void> _markWaitingAgent(
    PipelineJob job,
    String stepId,
    String detail,
  ) async {
    final step = job.stepById(stepId);
    if (step != null) {
      step.status = PipelineStepStatus.waiting;
      step.detail = detail;
      step.startedAt ??= DateTime.now().toUtc();
    }
    _setCurrentStep(job, stepId);
    job.status = PipelineJobStatus.waitingAgent;
    await _store.saveJob(job);
    await _store.appendEvent(job.id, 'waiting_agent', {'step': stepId});
    _notify();
  }

  Future<void> _runGenRefs(PipelineJob job) async {
    final cfg = await _store.loadConfig();
    final runner = PipelineComfyRunner(cfg);
    try {
      await runner.prepare();
      final graph = await _store.loadGraph(job.id);
      final stepId = job.currentStepId ?? 'gen_refs';
      final step = job.stepById(stepId)!;
      step.status = PipelineStepStatus.running;
      step.startedAt = DateTime.now().toUtc();
      step.error = null;
      job.status = PipelineJobStatus.waitingComfy;
      await _store.saveJob(job);
      _notify();

      if (!runner.hasAnyRefTemplate) {
        for (final r in graph.refs) {
          if (r.status == 'ready' && r.outputPath != null) continue;
          r.status = 'skipped';
          r.reviewNote = '未配置参考图模板';
        }
        await _store.saveGraph(job.id, graph);
        step.status = PipelineStepStatus.skipped;
        step.detail = '未配置参考图模板';
        step.finishedAt = DateTime.now().toUtc();
        _setCurrentStep(job, 'review_refs', skipReason: '未配置参考图模板');
        job.status = PipelineJobStatus.queued;
        await _store.saveJob(job);
        return;
      }

      final dest = await _store.ensureRefsDirForJob(job);
      final toGen = graph.refs.where((r) {
        if (r.status == 'ready' || r.status == 'skipped') return false;
        if (r.status == 'failed') return true;
        final path = r.outputPath?.trim() ?? '';
        return path.isEmpty;
      }).toList();
      if (toGen.isEmpty) {
        step.status = PipelineStepStatus.skipped;
        step.detail = '全部复用已有参考图';
        step.finishedAt = DateTime.now().toUtc();
        _setCurrentStep(job, 'review_refs', skipReason: '全部复用已有参考图');
        job.status = PipelineJobStatus.queued;
        await _store.saveJob(job);
        await _store.appendEvent(job.id, 'gen_refs_skipped_reuse', {});
        return;
      }

      final concurrency = await runner.dispatchWorkerCount(toGen.length);
      step.detail =
          '桶调度×$concurrency · ${runner.onlineServerNames.join(", ")}';
      await _store.saveJob(job);
      _notify();

      final done = <String>{
        for (final r in graph.refs)
          if (r.outputPath != null &&
              r.outputPath!.trim().isNotEmpty &&
              r.status != 'failed')
            r.id,
      };
      var finished = 0;

      // 连续派发：空闲实例立刻接下一个依赖已满足的任务，不等整波。
      await pipelineDepsMapPool<PipelineRefNode>(
        items: toGen,
        idOf: (r) => r.id,
        depsOf: (r) => r.dependsOn,
        initiallyDone: done,
        concurrency: concurrency,
        work: (node) async {
          if (isCancelRequested(job.id)) return false;
          try {
            final path = await runner.generateRef(node: node, destDir: dest);
            if (path == null) {
              node.status = 'failed';
              node.reviewNote = '无可用模板或未产出文件';
              return false;
            }
            node.outputPath = path;
            node.status = 'pending';
            return true;
          } catch (e) {
            node.status = 'failed';
            node.reviewNote = '$e';
            return false;
          } finally {
            finished++;
            step.detail =
                '参考图 $finished/${toGen.length} · 桶×$concurrency';
            if (finished == toGen.length || finished % 2 == 0) {
              await _store.saveGraph(job.id, graph);
              await _store.saveJob(job);
            }
            _notifyUiThrottled();
          }
        },
      );
      await _store.saveGraph(job.id, graph);
      if (isCancelRequested(job.id)) return;

      final ok =
          toGen.where((r) => r.outputPath != null && r.status != 'failed').length;
      final fail = toGen.where((r) => r.status == 'failed').length;
      step.status = fail > 0 && ok == 0
          ? PipelineStepStatus.failed
          : PipelineStepStatus.succeeded;
      step.detail =
          'ok=$ok fail=$fail · servers=${runner.onlineServerCount}';
      step.finishedAt = DateTime.now().toUtc();
      if (fail > 0 && ok == 0) {
        job.status = PipelineJobStatus.failedNeedsHuman;
        job.error = '参考图全部失败';
        await _store.saveJob(job);
        return;
      }
      _setCurrentStep(job, 'review_refs');
      job.status = PipelineJobStatus.queued;
      await _store.saveJob(job);
    } finally {
      runner.close();
    }
  }

  Future<void> _runGenClips(PipelineJob job) async {
    final cfg = await _store.loadConfig();
    final runner = PipelineComfyRunner(cfg);
    try {
      await runner.prepare();
      final graph = await _store.loadGraph(job.id);
      final stepId = job.currentStepId ?? 'gen_clips';
      final step = job.stepById(stepId)!;
      step.status = PipelineStepStatus.running;
      step.startedAt = DateTime.now().toUtc();
      step.error = null;
      job.status = PipelineJobStatus.waitingComfy;
      await _store.saveJob(job);
      _notify();

      if (!runner.hasVideoTemplate) {
        step.status = PipelineStepStatus.failed;
        step.error = '未配置 shot_video 模板';
        step.finishedAt = DateTime.now().toUtc();
        job.status = PipelineJobStatus.failedNeedsHuman;
        job.error = '未配置视频模板（config.templates.shot_video）';
        await _store.saveJob(job);
        return;
      }

      final dest = await _store.ensureClipsDirForJob(job);
      final shots = graph.shots.where((s) {
        if (job.sceneId != null &&
            job.intent == PipelineIntent.sceneProduce &&
            s.id != job.sceneId) {
          return false;
        }
        return s.status == 'pending' || s.outputPath == null;
      }).toList();

      final concurrency = await runner.dispatchWorkerCount(shots.length);
      step.detail =
          '视频桶调度×$concurrency · ${runner.onlineServerNames.join(", ")}';
      await _store.saveJob(job);
      _notify();

      var completed = 0;
      await pipelineMapPool(shots, concurrency, (shot) async {
        if (isCancelRequested(job.id)) return;
        try {
          final path = await runner.generateClip(
            shot: shot,
            graph: graph,
            destDir: dest,
          );
          if (path == null) {
            shot.status = 'failed';
            shot.reviewNote = '未产出文件';
          } else {
            shot.outputPath = path;
            shot.status = 'pending';
          }
        } catch (e) {
          shot.status = 'failed';
          shot.reviewNote = '$e';
        }
        completed++;
        step.detail =
            '视频 $completed/${shots.length} · ×$concurrency';
        // 每完成约 2 条或波次末落一次盘，避免并行写同一 graph 把 UI 打满
        if (completed == shots.length || completed % 2 == 0) {
          await _store.saveGraph(job.id, graph);
          await _store.saveJob(job);
        }
        _notifyUiThrottled();
      });
      await _store.saveGraph(job.id, graph);

      final ok =
          shots.where((s) => s.outputPath != null && s.status != 'failed').length;
      final fail = shots.where((s) => s.status == 'failed').length;
      step.status = fail > 0 && ok == 0
          ? PipelineStepStatus.failed
          : PipelineStepStatus.succeeded;
      step.detail =
          'ok=$ok fail=$fail · servers=${runner.onlineServerCount}';
      step.finishedAt = DateTime.now().toUtc();
      if (fail > 0 && ok == 0) {
        job.status = PipelineJobStatus.failedNeedsHuman;
        job.error = '视频全部失败';
        await _store.saveJob(job);
        return;
      }

      if (cfg.autoReviewClips) {
        _setCurrentStep(job, 'review_clips');
      } else {
        for (final s in graph.shots) {
          if (s.outputPath != null) s.status = 'ready';
        }
        await _store.saveGraph(job.id, graph);
        _setCurrentStep(job, 'finalize', skipReason: '未开启视频自动粗检');
      }
      job.status = PipelineJobStatus.queued;
      await _store.saveJob(job);
    } finally {
      runner.close();
    }
  }

  Future<void> _runRevise(PipelineJob job) async {
    final sceneId = job.sceneId;
    if (sceneId == null || sceneId.isEmpty) {
      job.status = PipelineJobStatus.failed;
      job.error = 'revise 缺少 sceneId';
      await _store.saveJob(job);
      return;
    }
    final cfg = await _store.loadConfig();
    final runner = PipelineComfyRunner(cfg);
    try {
      await runner.prepare();
      final graph = await _store.loadGraph(job.id);
      final step = job.stepById('revise')!;
      step.status = PipelineStepStatus.running;
      step.startedAt = DateTime.now().toUtc();
      job.status = PipelineJobStatus.waitingComfy;
      await _store.saveJob(job);
      _notify();

      PipelineShotNode? shot;
      for (final s in graph.shots) {
        if (s.id == sceneId) {
          shot = s;
          break;
        }
      }
      if (shot == null) {
        step.status = PipelineStepStatus.failed;
        step.error = '场景不存在';
        job.status = PipelineJobStatus.failed;
        job.error = '场景不存在: $sceneId';
        await _store.saveJob(job);
        return;
      }

      final dest = await _store.ensureClipsDirForJob(job);
      try {
        final path = await runner.generateClip(
          shot: shot,
          graph: graph,
          destDir: dest,
        );
        if (path == null) {
          throw StateError('返修未产出文件（检查 shot_video 模板）');
        }
        shot.outputPath = path;
        shot.status = 'ready';
        await _store.saveGraph(job.id, graph);
        step.status = PipelineStepStatus.succeeded;
        step.detail = path;
        step.finishedAt = DateTime.now().toUtc();
        _setCurrentStep(job, 'finalize');
        job.status = PipelineJobStatus.queued;
        await _store.saveJob(job);
      } catch (e) {
        step.status = PipelineStepStatus.failed;
        step.error = '$e';
        step.finishedAt = DateTime.now().toUtc();
        job.status = PipelineJobStatus.failedNeedsHuman;
        job.error = '$e';
        await _store.saveJob(job);
      }
    } finally {
      runner.close();
    }
  }

  Future<void> _runFinalize(PipelineJob job) async {
    final graph = await _store.loadGraph(job.id);
    final step = job.stepById('finalize')!;
    _setCurrentStep(job, 'finalize');
    step.status = PipelineStepStatus.running;
    step.startedAt = DateTime.now().toUtc();
    job.status = PipelineJobStatus.running;
    await _store.saveJob(job);

    String materialsDir = '';
    var published = 0;
    try {
      materialsDir = _store.materialsDirForJob(job);
      published = await _store.publishClipsToMaterials(job, graph);
      await _store.saveGraph(job.id, graph);
      await _store.cleanupJobTempMedia(job.id);
    } catch (e) {
      step.status = PipelineStepStatus.failed;
      step.error = '落盘分镜素材失败: $e';
      step.finishedAt = DateTime.now().toUtc();
      job.status = PipelineJobStatus.failedNeedsHuman;
      job.error = step.error;
      await _store.saveJob(job);
      _notify();
      return;
    }

    final buf = StringBuffer();
    buf.writeln('# Pipeline Report · ${job.id}');
    buf.writeln();
    buf.writeln('- intent: `${pipelineIntentName(job.intent)}`');
    buf.writeln('- chapter: `${job.chapterPath}`');
    buf.writeln('- storyboard: `${job.storyboardDir ?? job.chapterPath}`');
    buf.writeln('- materials: `$materialsDir`');
    buf.writeln('- publishedClips: $published');
    buf.writeln('- status: succeeded');
    buf.writeln();
    buf.writeln('## Refs');
    for (final r in graph.refs) {
      buf.writeln(
        '- `${r.id}` (${r.kind}) · ${r.status} · ${r.outputPath ?? '-'}',
      );
    }
    buf.writeln();
    buf.writeln('## Shots（已落盘分镜素材）');
    for (final s in graph.shots) {
      buf.writeln('- `${s.id}` · ${s.status} · ${s.outputPath ?? '-'}');
    }

    final reportPath = p.join(_store.jobDir(job.id), 'report.md');
    await writeTextFileReliable(reportPath, buf.toString());

    step.status = PipelineStepStatus.succeeded;
    step.detail = '落盘 $published 条 → $materialsDir';
    step.finishedAt = DateTime.now().toUtc();
    job.status = PipelineJobStatus.succeeded;
    job.error = null;
    await _store.saveJob(job);
    await _store.appendEvent(job.id, 'succeeded', {
      'report': reportPath,
      'materialsDir': materialsDir,
      'publishedClips': published,
    });
    _notify();
  }
}
