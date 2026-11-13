import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/comfy/comfy_models.dart';
import '../../core/comfy/comfy_template_store.dart';
import '../../core/pipeline/pipeline_bridge.dart';
import '../../core/pipeline/pipeline_engine.dart';
import '../../core/pipeline/pipeline_host.dart';
import '../../core/pipeline/pipeline_models.dart';
import '../../core/pipeline/pipeline_service.dart';
import '../../core/pipeline/pipeline_store.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';

String _intentLabel(PipelineIntent i) => switch (i) {
      PipelineIntent.episodeProduce => '整集制作',
      PipelineIntent.sceneProduce => '单场制作',
      PipelineIntent.sceneRevise => '场景返修',
      PipelineIntent.refOnly => '仅参考图',
      PipelineIntent.status => '查进度',
      PipelineIntent.other => '其它',
    };

String _jobStatusLabel(PipelineJobStatus s) => switch (s) {
      PipelineJobStatus.queued => '排队中',
      PipelineJobStatus.running => '执行中',
      PipelineJobStatus.waitingComfy => 'Comfy 生成中',
      PipelineJobStatus.waitingAgent => '待 Agent 自检',
      PipelineJobStatus.waitingHuman => '待人工',
      PipelineJobStatus.succeeded => '已完成',
      PipelineJobStatus.failedNeedsHuman => '需人工处理',
      PipelineJobStatus.failed => '失败',
      PipelineJobStatus.cancelled => '已取消',
    };

bool _isForeignHost(PipelineJob job) {
  final h = job.hostId?.trim() ?? '';
  if (h.isEmpty) return false;
  return !PipelineHost.isMine(h);
}

/// 本机未驱动、却仍标成排队/生成中（进程重启或中断后）。
bool _isOrphanActive(PipelineJob job) {
  if (_isForeignHost(job)) return false;
  if (PipelineEngine.instance.isRunning(job.id)) return false;
  return job.status == PipelineJobStatus.queued ||
      job.status == PipelineJobStatus.running ||
      job.status == PipelineJobStatus.waitingComfy;
}

String _displayJobStatus(PipelineJob job) {
  if (_isForeignHost(job)) return '他机任务';
  if (_isOrphanActive(job)) return '本机未在跑';
  return _jobStatusLabel(job.status);
}

/// 只有本机真正在跑才转圈，避免他机残留状态假死观感。
bool _jobBusyLocal(PipelineJob job) =>
    PipelineEngine.instance.isRunning(job.id);

String _stepTypeLabel(PipelineStepType t) => switch (t) {
      PipelineStepType.authoring => '编剧分镜',
      PipelineStepType.genRefs => '生成参考图',
      PipelineStepType.reviewRefs => '自检参考图',
      PipelineStepType.genRefsRetry => '重出参考图',
      PipelineStepType.genClips => '生成视频',
      PipelineStepType.reviewClips => '自检视频',
      PipelineStepType.genClipsRetry => '重出视频',
      PipelineStepType.revise => '返修',
      PipelineStepType.finalize => '收尾报告',
    };

String _stepStatusLabel(PipelineStepStatus s) => switch (s) {
      PipelineStepStatus.pending => '待开始',
      PipelineStepStatus.running => '进行中',
      PipelineStepStatus.waiting => '等待中',
      PipelineStepStatus.succeeded => '完成',
      PipelineStepStatus.failed => '失败',
      PipelineStepStatus.skipped => '跳过',
    };

String _assetStatusLabel(String s) => switch (s) {
      'ready' => '已就绪',
      'pending' => '待生成',
      'failed' => '失败',
      'skipped' => '跳过',
      _ => s,
    };

String _jobDisplayTitle(PipelineJob job) {
  final path = job.chapterPath.trim();
  if (path.isEmpty) return job.id;
  final base = p.basename(path);
  const generic = {'chapters', '剧本', 'scripts', 'script'};
  if (generic.contains(base) || generic.contains(base.toLowerCase())) {
    final parent = p.basename(p.dirname(path));
    if (parent.isNotEmpty && parent != '.' && parent != '/') return parent;
  }
  return base.isEmpty ? job.id : base;
}

bool _looksLikeImage(String? path) {
  if (path == null || path.isEmpty) return false;
  final lower = path.toLowerCase();
  return lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp') ||
      lower.endsWith('.gif');
}

bool _looksLikeVideo(String? path) {
  if (path == null || path.isEmpty) return false;
  final lower = path.toLowerCase();
  return lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.webm') ||
      lower.endsWith('.mkv');
}

Color _jobAccent(ColorScheme cs, PipelineJobStatus s) => switch (s) {
      PipelineJobStatus.succeeded => const Color(0xFF6F9A78),
      PipelineJobStatus.failed ||
      PipelineJobStatus.failedNeedsHuman =>
        cs.error,
      PipelineJobStatus.cancelled => cs.onSurfaceVariant,
      PipelineJobStatus.waitingHuman ||
      PipelineJobStatus.waitingAgent =>
        const Color(0xFFC48A3A),
      PipelineJobStatus.waitingComfy ||
      PipelineJobStatus.running =>
        cs.primary,
      PipelineJobStatus.queued => cs.onSurfaceVariant,
    };

class PipelinePanel extends ConsumerStatefulWidget {
  const PipelinePanel({super.key});

  @override
  ConsumerState<PipelinePanel> createState() => _PipelinePanelState();
}

class _PipelinePanelState extends ConsumerState<PipelinePanel> {
  String? _selectedJobId;
  List<ComfyTemplate> _templates = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await PipelineService.instance.ensureStarted();
    } catch (_) {}
    final tpls = await ComfyTemplateStore.loadTemplates();
    if (!mounted) return;
    setState(() => _templates = tpls);
    bumpPipelineJobsTick(ref);
    bumpPipelineConfigTick(ref);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _PipelineHeader(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 300,
                  child: ColoredBox(
                    color: scheme.surfaceContainerLow,
                    child: _PipelineJobList(
                      selectedJobId: _selectedJobId,
                      onSelect: (id) => setState(() => _selectedJobId = id),
                    ),
                  ),
                ),
                VerticalDivider(width: 1, color: scheme.outlineVariant),
                Expanded(
                  child: ColoredBox(
                    color: scheme.surface,
                    child: _selectedJobId == null
                        ? _PipelineConfigPane(templates: _templates)
                        : _PipelineJobDetail(
                            jobId: _selectedJobId!,
                            onDeleted: () {
                              setState(() => _selectedJobId = null);
                              bumpPipelineJobsTick(ref);
                            },
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PipelineHeader extends ConsumerWidget {
  const _PipelineHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final bridge = ref.watch(pipelineBridgeInfoProvider);
    final online = bridge != '未启动';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.account_tree_outlined,
              size: 18,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '制片流水线',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              Text(
                'OpenCode 下任务 · Studio 批量出片',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          _BridgePill(online: online, label: online ? bridge : '桥未启动'),
          const Spacer(),
          _HeaderIconBtn(
            icon: Icons.sync,
            tooltip: '刷新任务列表',
            onPressed: () => bumpPipelineJobsTick(ref),
          ),
          const SizedBox(width: 4),
          _HeaderIconBtn(
            icon: Icons.cable,
            tooltip: '重启 HTTP 桥',
            onPressed: () async {
              try {
                await PipelineBridge.instance.restart();
                bumpPipelineConfigTick(ref);
                if (context.mounted) {
                  showGlobalToast(
                    context,
                    '桥已重启 ${PipelineBridge.instance.baseUrl}',
                  );
                }
              } catch (e) {
                if (context.mounted) showGlobalToast(context, '桥启动失败: $e');
              }
            },
          ),
        ],
      ),
    );
  }
}

class _BridgePill extends StatelessWidget {
  const _BridgePill({required this.online, required this.label});

  final bool online;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = online ? const Color(0xFF6F9A78) : scheme.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accent,
                fontFamily: 'Consolas',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderIconBtn extends StatelessWidget {
  const _HeaderIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 18),
    );
  }
}

class _PipelineJobList extends ConsumerWidget {
  const _PipelineJobList({
    required this.selectedJobId,
    required this.onSelect,
  });

  final String? selectedJobId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final jobsAsync = ref.watch(pipelineJobsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: _SideNavTile(
            selected: selectedJobId == null,
            icon: Icons.tune_outlined,
            title: '流水线配置',
            subtitle: '模板 · 闸门 · 并行',
            onTap: () => onSelect(null),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '任务',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: jobsAsync.when(
            skipLoadingOnReload: true,
            skipLoadingOnRefresh: true,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('加载失败: $e')),
            data: (jobs) {
              if (jobs.isEmpty) {
                return _EmptyJobsHint(scheme: scheme);
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                itemCount: jobs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final j = jobs[i];
                  return _JobListCard(
                    job: j,
                    selected: j.id == selectedJobId,
                    onTap: () => onSelect(j.id),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EmptyJobsHint extends StatelessWidget {
  const _EmptyJobsHint({required this.scheme});
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 36,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
            ),
            const SizedBox(height: 12),
            Text(
              '还没有制片任务',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在右侧 OpenCode 说：\n「帮我把第 N 集制作一下」',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SideNavTile extends StatelessWidget {
  const _SideNavTile({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : scheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.45)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobListCard extends StatelessWidget {
  const _JobListCard({
    required this.job,
    required this.selected,
    required this.onTap,
  });

  final PipelineJob job;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _jobAccent(scheme, job.status);
    final chapter = p.basename(job.chapterPath);

    return Material(
      color: selected
          ? scheme.surfaceContainerLowest
          : scheme.surface.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.65)
                  : scheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: ColoredBox(
                  color: accent,
                  child: const SizedBox(width: 3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusChip(
                          label: _displayJobStatus(job),
                          color: accent,
                          busy: _jobBusyLocal(job),
                        ),
                        const Spacer(),
                        Text(
                          _intentLabel(job.intent),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      chapter.isEmpty ? job.id : chapter,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        job.id,
                        if ((job.hostId ?? '').isNotEmpty) job.hostId!,
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        fontFamily: 'Consolas',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (job.currentStepId != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '步骤 ${job.currentStepId}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    this.busy = false,
  });

  final String label;
  final Color color;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            Icon(Icons.autorenew, size: 12, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

String _templateDisplayName(List<ComfyTemplate> templates, String id) {
  if (id.isEmpty) return '未绑定';
  for (final t in templates) {
    if (t.id == id) return t.name;
  }
  return '已失效 · $id';
}

class _PipelineConfigPane extends ConsumerStatefulWidget {
  const _PipelineConfigPane({required this.templates});

  final List<ComfyTemplate> templates;

  @override
  ConsumerState<_PipelineConfigPane> createState() =>
      _PipelineConfigPaneState();
}

class _PipelineConfigPaneState extends ConsumerState<_PipelineConfigPane> {
  PipelineConfig? _local;
  bool _saving = false;

  Future<void> _save(PipelineConfig next) async {
    setState(() {
      _local = next;
      _saving = true;
    });
    try {
      await PipelineStore.instance.saveConfig(next);
      bumpPipelineConfigTick(ref);
      if (mounted) showGlobalToast(context, '已保存');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickTemplate({
    required String title,
    required String currentId,
    required ValueChanged<String> onPicked,
  }) async {
    final scheme = Theme.of(context).colorScheme;
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: scheme.surfaceContainerHigh,
          child: SizedBox(
            width: 420,
            height: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    children: [
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.link_off,
                          color: scheme.onSurfaceVariant,
                        ),
                        title: const Text('不绑定'),
                        selected: currentId.isEmpty,
                        onTap: () => Navigator.pop(ctx, ''),
                      ),
                      for (final t in widget.templates)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.auto_awesome_outlined,
                            color: currentId == t.id
                                ? scheme.primary
                                : scheme.onSurfaceVariant,
                          ),
                          title: Text(t.name),
                          subtitle: Text(
                            t.id,
                            style: const TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 11,
                            ),
                          ),
                          selected: currentId == t.id,
                          onTap: () => Navigator.pop(ctx, t.id),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(pipelineConfigProvider);
    ref.listen(pipelineConfigProvider, (prev, next) {
      next.whenData((cfg) {
        if (_saving) return;
        if (!mounted) return;
        setState(() => _local = cfg);
      });
    });

    final cfg =
        _local ?? async.maybeWhen(data: (c) => c, orElse: () => null);
    if (cfg == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final scheme = Theme.of(context).colorScheme;
    final bridge = ref.watch(pipelineBridgeInfoProvider);
    final online = bridge != '未启动';
    final slots = <({
      String key,
      String label,
      String hint,
      IconData icon,
      Color tint,
      String id,
      void Function(String) setId,
    })>[
      (
        key: 'char',
        label: '角色参考图',
        hint: '人物一致性',
        icon: Icons.person_outline,
        tint: const Color(0xFF7E9BB8),
        id: cfg.refCharacterTemplateId,
        setId: (v) => unawaited(
              _save(cfg.copyWith(refCharacterTemplateId: v)),
            ),
      ),
      (
        key: 'scene',
        label: '场景参考图',
        hint: '环境氛围',
        icon: Icons.landscape_outlined,
        tint: const Color(0xFF7FA08C),
        id: cfg.refSceneTemplateId,
        setId: (v) =>
            unawaited(_save(cfg.copyWith(refSceneTemplateId: v))),
      ),
      (
        key: 'prop',
        label: '道具参考图',
        hint: '关键物件',
        icon: Icons.inventory_2_outlined,
        tint: const Color(0xFFC4A36A),
        id: cfg.refPropTemplateId,
        setId: (v) => unawaited(_save(cfg.copyWith(refPropTemplateId: v))),
      ),
      (
        key: 'video',
        label: '镜头视频',
        hint: '成片生成',
        icon: Icons.movie_outlined,
        tint: const Color(0xFF9A86A8),
        id: cfg.shotVideoTemplateId,
        setId: (v) =>
            unawaited(_save(cfg.copyWith(shotVideoTemplateId: v))),
      ),
    ];
    final bound = slots.where((s) => s.id.isNotEmpty).length;
    final ready = bound == slots.length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 920;
        final content = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: _configBindingsBlock(
                      scheme: scheme,
                      slots: slots,
                      bound: bound,
                      ready: ready,
                    ),
                  ),
                  const SizedBox(width: 18),
                  Expanded(
                    flex: 4,
                    child: Column(
                      children: [
                        _configStrategyBlock(scheme: scheme, cfg: cfg),
                        const SizedBox(height: 14),
                        _configBridgeBlock(
                          scheme: scheme,
                          online: online,
                          bridge: bridge,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Column(
                children: [
                  _configBindingsBlock(
                    scheme: scheme,
                    slots: slots,
                    bound: bound,
                    ready: ready,
                  ),
                  const SizedBox(height: 14),
                  _configStrategyBlock(scheme: scheme, cfg: cfg),
                  const SizedBox(height: 14),
                  _configBridgeBlock(
                    scheme: scheme,
                    online: online,
                    bridge: bridge,
                  ),
                ],
              );

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '流水线配置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '绑好四类模板，OpenCode 就能无人值守出片。',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    ref.read(contentModeProvider.notifier).state = 'comfy';
                  },
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('生成面板'),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _ConfigReadyStrip(
              bound: bound,
              total: slots.length,
              ready: ready,
              online: online,
            ),
            const SizedBox(height: 18),
            content,
          ],
        );
      },
    );
  }

  Widget _configBindingsBlock({
    required ColorScheme scheme,
    required List<
            ({
              String key,
              String label,
              String hint,
              IconData icon,
              Color tint,
              String id,
              void Function(String) setId,
            })>
        slots,
    required int bound,
    required bool ready,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '模板绑定',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                  color: scheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                '$bound / ${slots.length}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ready
                      ? const Color(0xFF6F9A78)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '工作流先在生成面板导入，并暴露 prompt / image。',
            style: TextStyle(
              fontSize: 11,
              height: 1.35,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= 520 ? 2 : 1;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: slots.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisExtent: 88,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemBuilder: (context, i) {
                  final s = slots[i];
                  final boundSlot = s.id.isNotEmpty;
                  final name =
                      _templateDisplayName(widget.templates, s.id);
                  return Material(
                    color: boundSlot
                        ? s.tint.withValues(alpha: 0.10)
                        : scheme.surface.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => unawaited(
                        _pickTemplate(
                          title: '选择「${s.label}」模板',
                          currentId: s.id,
                          onPicked: s.setId,
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: boundSlot
                                ? s.tint.withValues(alpha: 0.45)
                                : scheme.outlineVariant,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: s.tint.withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(s.icon, size: 18, color: s.tint),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    s.label,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: scheme.onSurface,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    boundSlot ? name : s.hint,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: boundSlot
                                          ? scheme.onSurface
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              boundSlot
                                  ? Icons.check_circle
                                  : Icons.chevron_right,
                              size: 18,
                              color: boundSlot
                                  ? s.tint
                                  : scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _configStrategyBlock({
    required ColorScheme scheme,
    required PipelineConfig cfg,
  }) {
    final conc = cfg.comfyConcurrency <= 0 ? 0 : cfg.comfyConcurrency;
    final preset = <int>{0, 1, 2, 3, 4, 6, 8};
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '执行策略',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          _StrategyToggleRow(
            title: '视频前人工确认',
            subtitle: '关：参考图过检后直接进视频',
            value: cfg.beforeFirstVideoGate,
            onChanged: (v) =>
                unawaited(_save(cfg.copyWith(beforeFirstVideoGate: v))),
          ),
          const SizedBox(height: 8),
          _StrategyToggleRow(
            title: '视频自动粗检',
            subtitle: 'Agent 抽帧拦黑屏 / 错主体',
            value: cfg.autoReviewClips,
            onChanged: (v) =>
                unawaited(_save(cfg.copyWith(autoReviewClips: v))),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            decoration: BoxDecoration(
              color: scheme.surface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Comfy 并行度',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '自动 = 打满在线实例；多任务共用桶位，空闲立刻派活',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: conc,
                    borderRadius: BorderRadius.circular(10),
                    items: [
                      const DropdownMenuItem(value: 0, child: Text('自动')),
                      const DropdownMenuItem(value: 1, child: Text('1')),
                      const DropdownMenuItem(value: 2, child: Text('2')),
                      const DropdownMenuItem(value: 3, child: Text('3')),
                      const DropdownMenuItem(value: 4, child: Text('4')),
                      const DropdownMenuItem(value: 6, child: Text('6')),
                      const DropdownMenuItem(value: 8, child: Text('8')),
                      if (!preset.contains(conc))
                        DropdownMenuItem(value: conc, child: Text('$conc')),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      unawaited(_save(cfg.copyWith(comfyConcurrency: v)));
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _configBridgeBlock({
    required ColorScheme scheme,
    required bool online,
    required String bridge,
  }) {
    final accent = online ? const Color(0xFF6F9A78) : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.cable, size: 18, color: accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'HTTP 工具桥',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  online ? bridge : '未启动 · 点顶栏电缆图标重启',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'Consolas',
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '复制地址',
            onPressed: !online
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(text: bridge));
                    if (mounted) showGlobalToast(context, '已复制桥地址');
                  },
            icon: const Icon(Icons.copy, size: 18),
          ),
        ],
      ),
    );
  }
}

class _ConfigReadyStrip extends StatelessWidget {
  const _ConfigReadyStrip({
    required this.bound,
    required this.total,
    required this.ready,
    required this.online,
  });

  final int bound;
  final int total;
  final bool ready;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ok = ready && online;
    final accent = ok
        ? const Color(0xFF6F9A78)
        : ready
            ? const Color(0xFFC48A3A)
            : scheme.primary;
    final label = ok
        ? '已就绪 · 可开始任务'
        : ready
            ? '模板已齐 · 工具桥未启动'
            : '还差 ${total - bound} 个模板';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.16),
            accent.withValues(alpha: 0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.verified_outlined : Icons.flag_outlined,
            size: 18,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          SizedBox(
            width: 88,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : bound / total,
                minHeight: 6,
                backgroundColor: scheme.surface.withValues(alpha: 0.45),
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StrategyToggleRow extends StatelessWidget {
  const _StrategyToggleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: value
                  ? scheme.primary.withValues(alpha: 0.35)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: value,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PipelineJobDetail extends ConsumerStatefulWidget {
  const _PipelineJobDetail({
    required this.jobId,
    required this.onDeleted,
  });

  final String jobId;
  final VoidCallback onDeleted;

  @override
  ConsumerState<_PipelineJobDetail> createState() => _PipelineJobDetailState();
}

class _PipelineJobDetailState extends ConsumerState<_PipelineJobDetail> {
  Map<String, dynamic>? _snap;
  Object? _error;
  bool _loading = false;
  int _assetTab = 0; // 0 refs, 1 shots

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final data = await PipelineEngine.instance.getJobSnapshot(widget.jobId);
      if (!mounted) return;
      setState(() {
        _snap = data;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _loading = false;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _PipelineJobDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jobId != widget.jobId) {
      _snap = null;
      _assetTab = 0;
      unawaited(_load());
    }
  }

  Future<void> _confirmDelete(BuildContext context, PipelineJob job) async {
    final foreign = _isForeignHost(job);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(foreign ? '删除他机任务' : '删除任务'),
        content: Text(
          foreign
              ? '这是其它机器创建的任务（host: ${job.hostId}）。\n'
                  '确认后将强制删除共享账本记录 ${job.id}。\n'
                  '不会删除剧目录下的「参考图」「分镜素材」文件。'
              : '删除账本记录 ${job.id}？\n'
                  '不会删除剧目录下的「参考图」「分镜素材」文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // 面板删除是人工确认后的账本清理；他机任务必须 force。
      await PipelineEngine.instance.deleteJob(job.id, force: true);
      if (!context.mounted) return;
      widget.onDeleted();
      showGlobalToast(context, '已删除任务');
    } catch (e) {
      if (context.mounted) {
        showGlobalToast(context, '删除失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(pipelineJobsTickProvider, (prev, next) {
      if (prev != next) unawaited(_load());
    });

    if (_error != null && _snap == null) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 36, color: scheme.error),
                const SizedBox(height: 12),
                Text(
                  '加载失败',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () async {
                        try {
                          await PipelineEngine.instance.cancelJob(
                            widget.jobId,
                            force: true,
                          );
                          bumpPipelineJobsTick(ref);
                          unawaited(_load());
                        } catch (e) {
                          if (context.mounted) {
                            showGlobalToast(context, '取消失败: $e');
                          }
                        }
                      },
                      child: const Text('取消任务'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: scheme.error,
                      ),
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('删除任务？'),
                            content: Text(
                              '将删除 ${widget.jobId} 记录（不删剧目录物料）。'
                              '若属于其它机器，确认后会强制清理账本。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('否'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('删除'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        try {
                          await PipelineEngine.instance.deleteJob(
                            widget.jobId,
                            force: true,
                          );
                          bumpPipelineJobsTick(ref);
                          widget.onDeleted();
                          if (context.mounted) {
                            showGlobalToast(context, '已删除任务');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showGlobalToast(context, '删除失败: $e');
                          }
                        }
                      },
                      child: const Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_snap == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final data = _snap!;
    final job = PipelineJob.fromJson(
      (data['job'] as Map).cast<String, dynamic>(),
    );
    final graph = PipelineGraph.fromJson(
      (data['graph'] as Map?)?.cast<String, dynamic>(),
    );
    final workdirError = data['workdirError']?.toString();
    final scheme = Theme.of(context).colorScheme;
    final accent = _jobAccent(scheme, job.status);
    final orphan = _isOrphanActive(job);
    final foreign = _isForeignHost(job);
    final doneSteps = job.steps
        .where((s) =>
            s.status == PipelineStepStatus.succeeded ||
            s.status == PipelineStepStatus.skipped)
        .length;
    final title = _jobDisplayTitle(job);
    final current = job.currentStep;
    final refsReady =
        graph.refs.where((r) => r.status == 'ready').length;
    final shotsReady =
        graph.shots.where((s) => s.status == 'ready').length;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;
        final body = wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 300,
                    child: _JobStepRail(
                      steps: job.steps,
                      currentStepId: job.currentStepId,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _JobAssetPane(
                      tab: _assetTab,
                      onTab: (i) => setState(() => _assetTab = i),
                      refs: graph.refs,
                      shots: graph.shots,
                      refsReady: refsReady,
                      shotsReady: shotsReady,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _JobStepRail(
                    steps: job.steps,
                    currentStepId: job.currentStepId,
                  ),
                  const SizedBox(height: 14),
                  _JobAssetPane(
                    tab: _assetTab,
                    onTab: (i) => setState(() => _assetTab = i),
                    refs: graph.refs,
                    shots: graph.shots,
                    refsReady: refsReady,
                    shotsReady: shotsReady,
                  ),
                ],
              );

        return ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _StatusChip(
                            label: _displayJobStatus(job),
                            color: accent,
                            busy: _jobBusyLocal(job),
                          ),
                          Text(
                            _intentLabel(job.intent),
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          Text(
                            job.id,
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'Consolas',
                              color: scheme.onSurfaceVariant
                                  .withValues(alpha: 0.85),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (job.status == PipelineJobStatus.waitingAgent &&
                    !foreign) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          await PipelineEngine.instance.ackAgentStep(job.id);
                          bumpPipelineJobsTick(ref);
                          unawaited(_load());
                          if (context.mounted) {
                            showGlobalToast(context, '已推进 Agent 步骤');
                          }
                        } catch (e) {
                          if (context.mounted) {
                            showGlobalToast(context, '推进失败: $e');
                          }
                        }
                      },
                      child: const Text('确认自检并继续'),
                    ),
                  ),
                ],
                if (job.status == PipelineJobStatus.waitingHuman ||
                    job.status == PipelineJobStatus.failedNeedsHuman)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilledButton(
                      onPressed: () async {
                        try {
                          await PipelineEngine.instance.runJob(job.id);
                          bumpPipelineJobsTick(ref);
                          unawaited(_load());
                        } catch (e) {
                          if (context.mounted) {
                            showGlobalToast(context, '继续失败: $e');
                          }
                        }
                      },
                      child: const Text('继续'),
                    ),
                  ),
                if (PipelineEngine.instance.isCancellable(job.status))
                  _HeaderIconBtn(
                    icon: Icons.stop_circle_outlined,
                    tooltip: foreign ? '强制取消他机任务' : '取消任务',
                    onPressed: () async {
                      try {
                        await PipelineEngine.instance.cancelJob(
                          job.id,
                          force: true,
                        );
                        bumpPipelineJobsTick(ref);
                        unawaited(_load());
                      } catch (e) {
                        if (context.mounted) {
                          showGlobalToast(context, '取消失败: $e');
                        }
                      }
                    },
                  ),
                _HeaderIconBtn(
                  icon: Icons.delete_outline,
                  tooltip: foreign ? '强制删除他机任务' : '删除任务',
                  onPressed: () => _confirmDelete(context, job),
                ),
              ],
            ),
            if (foreign ||
                orphan ||
                (workdirError != null && workdirError.isNotEmpty)) ...[
              const SizedBox(height: 12),
              _DetailNotice(
                tone: const Color(0xFFC48A3A),
                icon: Icons.info_outline,
                text: foreign
                    ? '其它机器创建的任务（host: ${job.hostId}）。'
                        '本机 Agent 默认不会动它；面板可强制取消/删除账本。'
                    : orphan
                        ? '状态仍像在跑，但本机进程并未驱动。可取消或删除。'
                        : '工作目录不可用：$workdirError',
              ),
            ],
            if (job.error != null && job.error!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _DetailNotice(
                tone: scheme.error,
                icon: Icons.error_outline,
                text: job.error!,
              ),
            ],
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    accent.withValues(alpha: 0.14),
                    accent.withValues(alpha: 0.04),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: 0.28)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      current == null
                          ? '步骤 $doneSteps / ${job.steps.length}'
                          : '当前 · ${_stepTypeLabel(current.type)}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  Text(
                    '$doneSteps / ${job.steps.length}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 96,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(99),
                      child: LinearProgressIndicator(
                        value: job.steps.isEmpty
                            ? 0
                            : doneSteps / job.steps.length,
                        minHeight: 6,
                        backgroundColor:
                            scheme.surface.withValues(alpha: 0.4),
                        color: accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            body,
            const SizedBox(height: 16),
            _JobPathFooter(
              refsDir: '${data['refsDir'] ?? ''}',
              clipsTempDir: '${data['clipsTempDir'] ?? data['clipsDir'] ?? ''}',
              materialsDir: '${data['materialsDir'] ?? ''}',
            ),
          ],
        );
      },
    );
  }
}

class _DetailNotice extends StatelessWidget {
  const _DetailNotice({
    required this.tone,
    required this.icon,
    required this.text,
  });

  final Color tone;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: tone.withValues(alpha: 0.30)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: scheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _JobStepRail extends StatelessWidget {
  const _JobStepRail({
    required this.steps,
    required this.currentStepId,
  });

  final List<PipelineStep> steps;
  final String? currentStepId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '步骤',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 12),
          for (var i = 0; i < steps.length; i++)
            _StepRailRow(
              step: steps[i],
              isLast: i == steps.length - 1,
              isCurrent: currentStepId == steps[i].id,
            ),
        ],
      ),
    );
  }
}

class _StepRailRow extends StatelessWidget {
  const _StepRailRow({
    required this.step,
    required this.isLast,
    required this.isCurrent,
  });

  final PipelineStep step;
  final bool isLast;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (step.status) {
      PipelineStepStatus.succeeded => const Color(0xFF6F9A78),
      PipelineStepStatus.failed => scheme.error,
      PipelineStepStatus.running || PipelineStepStatus.waiting => scheme.primary,
      _ => scheme.onSurfaceVariant,
    };
    final icon = switch (step.status) {
      PipelineStepStatus.succeeded => Icons.check_circle,
      PipelineStepStatus.failed => Icons.cancel,
      PipelineStepStatus.running => Icons.play_circle_filled,
      PipelineStepStatus.waiting => Icons.pause_circle_filled,
      PipelineStepStatus.skipped => Icons.remove_circle_outline,
      PipelineStepStatus.pending => Icons.radio_button_unchecked,
    };
    final showDetail = isCurrent ||
        step.status == PipelineStepStatus.failed ||
        (step.detail.isNotEmpty &&
            (step.status == PipelineStepStatus.running ||
                step.status == PipelineStepStatus.waiting));

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 2),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 22,
              child: Column(
                children: [
                  Icon(icon, size: 16, color: color),
                  if (!isLast)
                    Expanded(
                      child: Container(
                        width: 1.5,
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        color: scheme.outlineVariant.withValues(alpha: 0.8),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    10,
                    8,
                    10,
                    showDetail ? 10 : 8,
                  ),
                  decoration: BoxDecoration(
                    color: isCurrent
                        ? scheme.primary.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: isCurrent
                        ? Border.all(
                            color: scheme.primary.withValues(alpha: 0.28),
                          )
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _stepTypeLabel(step.type),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight:
                                    isCurrent ? FontWeight.w700 : FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          Text(
                            _stepStatusLabel(step.status),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                      if (showDetail && step.detail.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          step.detail,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.35,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (step.error != null && step.error!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          step.error!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: scheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JobAssetPane extends StatelessWidget {
  const _JobAssetPane({
    required this.tab,
    required this.onTab,
    required this.refs,
    required this.shots,
    required this.refsReady,
    required this.shotsReady,
  });

  final int tab;
  final ValueChanged<int> onTab;
  final List<PipelineRefNode> refs;
  final List<PipelineShotNode> shots;
  final int refsReady;
  final int shotsReady;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = tab == 0
        ? [
            for (final r in refs)
              (
                id: r.id,
                title: r.title.isEmpty ? r.id : r.title,
                kind: r.kind,
                status: r.status,
                path: r.outputPath,
              ),
          ]
        : [
            for (final s in shots)
              (
                id: s.id,
                title: s.title.isEmpty ? s.id : s.title,
                kind: 'shot',
                status: s.status,
                path: s.outputPath,
              ),
          ];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _AssetTabChip(
                label: '参考图',
                count: '$refsReady/${refs.length}',
                selected: tab == 0,
                onTap: () => onTab(0),
              ),
              const SizedBox(width: 8),
              _AssetTabChip(
                label: '镜头成片',
                count: '$shotsReady/${shots.length}',
                selected: tab == 1,
                onTap: () => onTab(1),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  tab == 0 ? '暂无参考图节点' : '暂无镜头节点',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth >= 720
                    ? 4
                    : c.maxWidth >= 480
                        ? 3
                        : 2;
                return GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: items.length,
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisExtent: 148,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
                  itemBuilder: (context, i) {
                    final it = items[i];
                    return _AssetCard(
                      title: it.title,
                      kind: it.kind,
                      status: it.status,
                      path: it.path,
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }
}

class _AssetTabChip extends StatelessWidget {
  const _AssetTabChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : scheme.surface.withValues(alpha: 0.35),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.4)
                  : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                count,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'Consolas',
                  color: selected
                      ? scheme.primary
                      : scheme.onSurfaceVariant.withValues(alpha: 0.85),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssetCard extends StatelessWidget {
  const _AssetCard({
    required this.title,
    required this.kind,
    required this.status,
    required this.path,
  });

  final String title;
  final String kind;
  final String status;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ready = status == 'ready';
    final failed = status == 'failed';
    final color = failed
        ? scheme.error
        : ready
            ? const Color(0xFF6F9A78)
            : scheme.onSurfaceVariant;
    final fallbackIcon = kind == 'shot'
        ? Icons.movie_outlined
        : kind == 'scene'
            ? Icons.landscape_outlined
            : kind == 'prop'
                ? Icons.inventory_2_outlined
                : Icons.person_outline;

    Widget preview;
    final filePath = path;
    if (filePath != null &&
        filePath.isNotEmpty &&
        _looksLikeImage(filePath) &&
        File(filePath).existsSync()) {
      preview = Image.file(
        File(filePath),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(fallbackIcon, color: color),
      );
    } else if (_looksLikeVideo(filePath)) {
      preview = Icon(Icons.play_circle_outline, size: 28, color: color);
    } else {
      preview = Icon(fallbackIcon, size: 22, color: color);
    }

    return Container(
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ready
              ? color.withValues(alpha: 0.35)
              : scheme.outlineVariant.withValues(alpha: 0.85),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ColoredBox(
              color: color.withValues(alpha: 0.08),
              child: Center(child: preview),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(9, 8, 9, 9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _assetStatusLabel(status),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _JobPathFooter extends StatelessWidget {
  const _JobPathFooter({
    required this.refsDir,
    required this.clipsTempDir,
    required this.materialsDir,
  });

  final String refsDir;
  final String clipsTempDir;
  final String materialsDir;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasRefs = refsDir.isNotEmpty && refsDir != 'null';
    final hasTemp = clipsTempDir.isNotEmpty && clipsTempDir != 'null';
    final hasMaterials = materialsDir.isNotEmpty && materialsDir != 'null';
    if (!hasRefs && !hasTemp && !hasMaterials) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        children: [
          if (hasRefs)
            _PathLine(
              label: '参考图',
              path: refsDir,
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: refsDir));
                if (context.mounted) showGlobalToast(context, '已复制参考图目录');
              },
            ),
          if (hasRefs && (hasMaterials || hasTemp)) const SizedBox(height: 8),
          if (hasMaterials)
            _PathLine(
              label: '分镜素材',
              path: materialsDir,
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: materialsDir));
                if (context.mounted) showGlobalToast(context, '已复制分镜素材目录');
              },
            ),
          if (hasMaterials && hasTemp) const SizedBox(height: 8),
          if (hasTemp)
            _PathLine(
              label: '临时成片',
              path: clipsTempDir,
              onCopy: () async {
                await Clipboard.setData(ClipboardData(text: clipsTempDir));
                if (context.mounted) showGlobalToast(context, '已复制临时成片目录');
              },
            ),
        ],
      ),
    );
  }
}

class _PathLine extends StatelessWidget {
  const _PathLine({
    required this.label,
    required this.path,
    required this.onCopy,
  });

  final String label;
  final String path;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            path,
            maxLines: 1,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'Consolas',
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        IconButton(
          tooltip: '复制',
          visualDensity: VisualDensity.compact,
          onPressed: onCopy,
          icon: const Icon(Icons.copy, size: 16),
        ),
      ],
    );
  }
}
