import 'dart:convert';

/// 自然语言任务意图。
enum PipelineIntent {
  episodeProduce,
  sceneProduce,
  sceneRevise,
  refOnly,
  status,
  other,
}

PipelineIntent pipelineIntentFromName(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'episode_produce':
    case 'episodeProduce':
      return PipelineIntent.episodeProduce;
    case 'scene_produce':
    case 'sceneProduce':
      return PipelineIntent.sceneProduce;
    case 'scene_revise':
    case 'sceneRevise':
      return PipelineIntent.sceneRevise;
    case 'ref_only':
    case 'refOnly':
      return PipelineIntent.refOnly;
    case 'status':
      return PipelineIntent.status;
    default:
      return PipelineIntent.other;
  }
}

String pipelineIntentName(PipelineIntent i) => switch (i) {
      PipelineIntent.episodeProduce => 'episode_produce',
      PipelineIntent.sceneProduce => 'scene_produce',
      PipelineIntent.sceneRevise => 'scene_revise',
      PipelineIntent.refOnly => 'ref_only',
      PipelineIntent.status => 'status',
      PipelineIntent.other => 'other',
    };

enum PipelineJobStatus {
  queued,
  running,
  waitingComfy,
  waitingAgent,
  waitingHuman,
  succeeded,
  failedNeedsHuman,
  failed,
  cancelled,
}

PipelineJobStatus pipelineJobStatusFromName(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'queued':
      return PipelineJobStatus.queued;
    case 'running':
      return PipelineJobStatus.running;
    case 'waiting_comfy':
    case 'waitingComfy':
      return PipelineJobStatus.waitingComfy;
    case 'waiting_agent':
    case 'waitingAgent':
      return PipelineJobStatus.waitingAgent;
    case 'waiting_human':
    case 'waitingHuman':
      return PipelineJobStatus.waitingHuman;
    case 'succeeded':
      return PipelineJobStatus.succeeded;
    case 'failed_needs_human':
    case 'failedNeedsHuman':
      return PipelineJobStatus.failedNeedsHuman;
    case 'cancelled':
      return PipelineJobStatus.cancelled;
    default:
      return PipelineJobStatus.failed;
  }
}

String pipelineJobStatusName(PipelineJobStatus s) => switch (s) {
      PipelineJobStatus.queued => 'queued',
      PipelineJobStatus.running => 'running',
      PipelineJobStatus.waitingComfy => 'waiting_comfy',
      PipelineJobStatus.waitingAgent => 'waiting_agent',
      PipelineJobStatus.waitingHuman => 'waiting_human',
      PipelineJobStatus.succeeded => 'succeeded',
      PipelineJobStatus.failedNeedsHuman => 'failed_needs_human',
      PipelineJobStatus.failed => 'failed',
      PipelineJobStatus.cancelled => 'cancelled',
    };

enum PipelineStepType {
  authoring,
  genRefs,
  reviewRefs,
  genRefsRetry,
  genClips,
  reviewClips,
  genClipsRetry,
  revise,
  finalize,
}

String pipelineStepTypeName(PipelineStepType t) => switch (t) {
      PipelineStepType.authoring => 'authoring',
      PipelineStepType.genRefs => 'gen_refs',
      PipelineStepType.reviewRefs => 'review_refs',
      PipelineStepType.genRefsRetry => 'gen_refs_retry',
      PipelineStepType.genClips => 'gen_clips',
      PipelineStepType.reviewClips => 'review_clips',
      PipelineStepType.genClipsRetry => 'gen_clips_retry',
      PipelineStepType.revise => 'revise',
      PipelineStepType.finalize => 'finalize',
    };

PipelineStepType pipelineStepTypeFromName(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'gen_refs':
      return PipelineStepType.genRefs;
    case 'review_refs':
      return PipelineStepType.reviewRefs;
    case 'gen_refs_retry':
      return PipelineStepType.genRefsRetry;
    case 'gen_clips':
      return PipelineStepType.genClips;
    case 'review_clips':
      return PipelineStepType.reviewClips;
    case 'gen_clips_retry':
      return PipelineStepType.genClipsRetry;
    case 'revise':
      return PipelineStepType.revise;
    case 'finalize':
      return PipelineStepType.finalize;
    default:
      return PipelineStepType.authoring;
  }
}

enum PipelineStepStatus {
  pending,
  running,
  waiting,
  succeeded,
  failed,
  skipped,
}

String pipelineStepStatusName(PipelineStepStatus s) => switch (s) {
      PipelineStepStatus.pending => 'pending',
      PipelineStepStatus.running => 'running',
      PipelineStepStatus.waiting => 'waiting',
      PipelineStepStatus.succeeded => 'succeeded',
      PipelineStepStatus.failed => 'failed',
      PipelineStepStatus.skipped => 'skipped',
    };

PipelineStepStatus pipelineStepStatusFromName(String? raw) {
  switch ((raw ?? '').trim()) {
    case 'running':
      return PipelineStepStatus.running;
    case 'waiting':
      return PipelineStepStatus.waiting;
    case 'succeeded':
      return PipelineStepStatus.succeeded;
    case 'failed':
      return PipelineStepStatus.failed;
    case 'skipped':
      return PipelineStepStatus.skipped;
    default:
      return PipelineStepStatus.pending;
  }
}

class PipelineConfig {
  const PipelineConfig({
    this.refCharacterTemplateId = '',
    this.refSceneTemplateId = '',
    this.refPropTemplateId = '',
    this.shotVideoTemplateId = '',
    this.comfyServerId = '',
    this.maxRefReviewRounds = 3,
    this.maxClipReviewRounds = 1,
    this.autoReviewClips = true,
    this.beforeFirstVideoGate = false,
    this.comfyConcurrency = 0,
    this.bridgePort = 7829,
  });

  final String refCharacterTemplateId;
  final String refSceneTemplateId;
  final String refPropTemplateId;
  final String shotVideoTemplateId;
  final String comfyServerId;
  final int maxRefReviewRounds;
  final int maxClipReviewRounds;
  final bool autoReviewClips;
  final bool beforeFirstVideoGate;
  final int comfyConcurrency;
  final int bridgePort;

  factory PipelineConfig.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    final templates = (j['templates'] as Map?)?.cast<String, dynamic>() ?? {};
    final rounds = (j['maxReviewRounds'] as Map?)?.cast<String, dynamic>() ?? {};
    final gates = (j['gates'] as Map?)?.cast<String, dynamic>() ?? {};
    return PipelineConfig(
      refCharacterTemplateId: '${templates['ref_character'] ?? ''}',
      refSceneTemplateId: '${templates['ref_scene'] ?? ''}',
      refPropTemplateId: '${templates['ref_prop'] ?? ''}',
      shotVideoTemplateId: '${templates['shot_video'] ?? ''}',
      comfyServerId: '${j['comfyServerId'] ?? ''}',
      maxRefReviewRounds: (rounds['ref'] as num?)?.toInt() ?? 3,
      maxClipReviewRounds: (rounds['clip'] as num?)?.toInt() ?? 1,
      autoReviewClips: j['autoReviewClips'] as bool? ?? true,
      beforeFirstVideoGate: gates['beforeFirstVideo'] as bool? ?? false,
      // 0 = 自动（按在线 Comfy 实例数并行）
      comfyConcurrency: (j['comfyConcurrency'] as num?)?.toInt() ?? 0,
      bridgePort: (j['bridgePort'] as num?)?.toInt() ?? 7829,
    );
  }

  Map<String, dynamic> toJson() => {
        'templates': {
          'ref_character': refCharacterTemplateId,
          'ref_scene': refSceneTemplateId,
          'ref_prop': refPropTemplateId,
          'shot_video': shotVideoTemplateId,
        },
        'comfyServerId': comfyServerId,
        'maxReviewRounds': {
          'ref': maxRefReviewRounds,
          'clip': maxClipReviewRounds,
        },
        'autoReviewClips': autoReviewClips,
        'gates': {
          'beforeFirstVideo': beforeFirstVideoGate,
          'onReviewExhausted': true,
        },
        'comfyConcurrency': comfyConcurrency,
        'bridgePort': bridgePort,
      };

  PipelineConfig copyWith({
    String? refCharacterTemplateId,
    String? refSceneTemplateId,
    String? refPropTemplateId,
    String? shotVideoTemplateId,
    String? comfyServerId,
    int? maxRefReviewRounds,
    int? maxClipReviewRounds,
    bool? autoReviewClips,
    bool? beforeFirstVideoGate,
    Object? comfyConcurrency = _keepInt,
    int? bridgePort,
  }) {
    return PipelineConfig(
      refCharacterTemplateId:
          refCharacterTemplateId ?? this.refCharacterTemplateId,
      refSceneTemplateId: refSceneTemplateId ?? this.refSceneTemplateId,
      refPropTemplateId: refPropTemplateId ?? this.refPropTemplateId,
      shotVideoTemplateId: shotVideoTemplateId ?? this.shotVideoTemplateId,
      comfyServerId: comfyServerId ?? this.comfyServerId,
      maxRefReviewRounds: maxRefReviewRounds ?? this.maxRefReviewRounds,
      maxClipReviewRounds: maxClipReviewRounds ?? this.maxClipReviewRounds,
      autoReviewClips: autoReviewClips ?? this.autoReviewClips,
      beforeFirstVideoGate: beforeFirstVideoGate ?? this.beforeFirstVideoGate,
      // 哨兵：允许显式写入 0（自动），避免 `0 ?? old` 语义踩坑
      comfyConcurrency: identical(comfyConcurrency, _keepInt)
          ? this.comfyConcurrency
          : (comfyConcurrency as int?) ?? 0,
      bridgePort: bridgePort ?? this.bridgePort,
    );
  }
}

const Object _keepInt = Object();

class PipelineRefNode {
  PipelineRefNode({
    required this.id,
    required this.kind,
    required this.title,
    this.prompt = '',
    this.dependsOn = const [],
    this.outputPath,
    this.status = 'pending',
    this.reviewNote = '',
    this.round = 0,
  });

  final String id;
  final String kind; // character | scene | prop
  String title;
  String prompt;
  List<String> dependsOn;
  String? outputPath;
  String status; // pending | ready | failed | skipped
  String reviewNote;
  int round;

  factory PipelineRefNode.fromJson(Map<String, dynamic> json) {
    return PipelineRefNode(
      id: '${json['id'] ?? ''}',
      kind: '${json['kind'] ?? 'character'}',
      title: '${json['title'] ?? json['id'] ?? ''}',
      prompt: '${json['prompt'] ?? ''}',
      dependsOn: [
        for (final e in (json['dependsOn'] as List? ?? const []))
          '$e',
      ],
      outputPath: json['outputPath'] as String?,
      status: '${json['status'] ?? 'pending'}',
      reviewNote: '${json['reviewNote'] ?? ''}',
      round: (json['round'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'prompt': prompt,
        'dependsOn': dependsOn,
        'outputPath': outputPath,
        'status': status,
        'reviewNote': reviewNote,
        'round': round,
      };
}

class PipelineShotNode {
  PipelineShotNode({
    required this.id,
    required this.title,
    this.prompt = '',
    this.refIds = const [],
    this.duration,
    this.outputPath,
    this.status = 'pending',
    this.reviewNote = '',
    this.round = 0,
  });

  final String id;
  String title;
  String prompt;
  List<String> refIds;
  double? duration;
  String? outputPath;
  String status;
  String reviewNote;
  int round;

  factory PipelineShotNode.fromJson(Map<String, dynamic> json) {
    return PipelineShotNode(
      id: '${json['id'] ?? ''}',
      title: '${json['title'] ?? json['id'] ?? ''}',
      prompt: '${json['prompt'] ?? ''}',
      refIds: [
        for (final e in (json['refIds'] as List? ?? const [])) '$e',
      ],
      duration: (json['duration'] as num?)?.toDouble(),
      outputPath: json['outputPath'] as String?,
      status: '${json['status'] ?? 'pending'}',
      reviewNote: '${json['reviewNote'] ?? ''}',
      round: (json['round'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'prompt': prompt,
        'refIds': refIds,
        'duration': duration,
        'outputPath': outputPath,
        'status': status,
        'reviewNote': reviewNote,
        'round': round,
      };
}

class PipelineGraph {
  PipelineGraph({
    this.refs = const [],
    this.shots = const [],
  });

  List<PipelineRefNode> refs;
  List<PipelineShotNode> shots;

  factory PipelineGraph.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    return PipelineGraph(
      refs: [
        for (final e in (j['refs'] as List? ?? const []))
          if (e is Map)
            PipelineRefNode.fromJson(e.map((k, v) => MapEntry('$k', v))),
      ],
      shots: [
        for (final e in (j['shots'] as List? ?? const []))
          if (e is Map)
            PipelineShotNode.fromJson(e.map((k, v) => MapEntry('$k', v))),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'refs': [for (final r in refs) r.toJson()],
        'shots': [for (final s in shots) s.toJson()],
      };

  String encodePretty() =>
      const JsonEncoder.withIndent('  ').convert(toJson());
}

class PipelineStep {
  PipelineStep({
    required this.id,
    required this.type,
    this.status = PipelineStepStatus.pending,
    this.detail = '',
    this.startedAt,
    this.finishedAt,
    this.error,
  });

  final String id;
  final PipelineStepType type;
  PipelineStepStatus status;
  String detail;
  DateTime? startedAt;
  DateTime? finishedAt;
  String? error;

  factory PipelineStep.fromJson(Map<String, dynamic> json) {
    return PipelineStep(
      id: '${json['id'] ?? ''}',
      type: pipelineStepTypeFromName(json['type'] as String?),
      status: pipelineStepStatusFromName(json['status'] as String?),
      detail: '${json['detail'] ?? ''}',
      startedAt: _parseTime(json['startedAt']),
      finishedAt: _parseTime(json['finishedAt']),
      error: json['error'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': pipelineStepTypeName(type),
        'status': pipelineStepStatusName(status),
        'detail': detail,
        'startedAt': startedAt?.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
        'error': error,
      };
}

class PipelineJob {
  PipelineJob({
    required this.id,
    required this.intent,
    required this.chapterPath,
    this.sceneId,
    this.status = PipelineJobStatus.queued,
    this.currentStepId,
    this.storyboardDir,
    this.sessionId,
    this.hostId,
    this.error,
    this.userBrief = '',
    this.createdAt,
    this.updatedAt,
    List<PipelineStep>? steps,
  }) : steps = steps ?? [];

  final String id;
  PipelineIntent intent;
  String chapterPath;
  String? sceneId;
  PipelineJobStatus status;
  String? currentStepId;
  String? storyboardDir;
  String? sessionId;
  /// 创建该 Job 的机器身份（hostname_user）；多机 NAS 共用时用来隔离。
  String? hostId;
  String? error;
  String userBrief;
  DateTime? createdAt;
  DateTime? updatedAt;
  List<PipelineStep> steps;

  factory PipelineJob.fromJson(Map<String, dynamic> json) {
    return PipelineJob(
      id: '${json['id'] ?? ''}',
      intent: pipelineIntentFromName(json['intent'] as String?),
      chapterPath: '${json['chapterPath'] ?? ''}',
      sceneId: json['sceneId'] as String?,
      status: pipelineJobStatusFromName(json['status'] as String?),
      currentStepId: json['currentStepId'] as String?,
      storyboardDir: json['storyboardDir'] as String?,
      sessionId: json['sessionId'] as String?,
      hostId: (json['hostId'] as String?)?.trim(),
      error: json['error'] as String?,
      userBrief: '${json['userBrief'] ?? ''}',
      createdAt: _parseTime(json['createdAt']),
      updatedAt: _parseTime(json['updatedAt']),
      steps: [
        for (final e in (json['steps'] as List? ?? const []))
          if (e is Map)
            PipelineStep.fromJson(e.map((k, v) => MapEntry('$k', v))),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'intent': pipelineIntentName(intent),
        'chapterPath': chapterPath,
        'sceneId': sceneId,
        'status': pipelineJobStatusName(status),
        'currentStepId': currentStepId,
        'storyboardDir': storyboardDir,
        'sessionId': sessionId,
        'hostId': hostId,
        'error': error,
        'userBrief': userBrief,
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'steps': [for (final s in steps) s.toJson()],
      };

  PipelineStep? stepById(String id) {
    for (final s in steps) {
      if (s.id == id) return s;
    }
    return null;
  }

  PipelineStep? get currentStep =>
      currentStepId == null ? null : stepById(currentStepId!);
}

DateTime? _parseTime(Object? raw) {
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw);
  return null;
}

class PipelineReviewItem {
  const PipelineReviewItem({
    required this.id,
    required this.pass,
    this.note = '',
    this.newPrompt,
  });

  final String id;
  final bool pass;
  final String note;
  final String? newPrompt;

  factory PipelineReviewItem.fromJson(Map<String, dynamic> json) {
    return PipelineReviewItem(
      id: '${json['id'] ?? ''}',
      pass: json['pass'] as bool? ?? false,
      note: '${json['note'] ?? ''}',
      newPrompt: json['newPrompt'] as String?,
    );
  }
}
