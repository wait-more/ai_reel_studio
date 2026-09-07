import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../../core/comfy/comfy_client.dart';
import '../../core/comfy/comfy_discover.dart';
import '../../core/comfy/comfy_gen_session.dart';
import '../../core/comfy/comfy_models.dart';
import '../../core/comfy/comfy_template_store.dart';
import '../../core/config.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import 'comfy_template_library.dart';

class _ComfyBundle {
  final List<ComfyTemplate> templates;
  final ComfyBindings bindings;
  const _ComfyBundle(this.templates, this.bindings);
}

final comfyBundleProvider =
    FutureProvider.autoDispose<_ComfyBundle>((ref) async {
  ref.watch(comfyActionsTickProvider);
  final templates = await ComfyTemplateStore.loadTemplates();
  final bindings = await ComfyTemplateStore.loadBindings();
  return _ComfyBundle(templates, bindings);
});

enum _ComfyJobPhase {
  preparing,
  uploading,
  submitting,
  queued,
  running,
  downloading,
  completed,
  cancelled,
  failed,
}

class _ComfyJob {
  _ComfyJob({
    required this.id,
    required this.templateId,
    required this.templateName,
    required this.serverId,
    required this.baseUrl,
    required this.outputDir,
    required this.outputFileName,
    required this.cancelToken,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String templateId;
  final String templateName;
  final String serverId;
  final String baseUrl;
  final String outputDir;
  /// 入队时快照；空则保存时用 Comfy 原名。
  final String outputFileName;
  final DateTime createdAt;
  final ComfyCancelToken cancelToken;

  String? promptId;
  bool cancelling = false;
  _ComfyJobPhase phase = _ComfyJobPhase.preparing;
  String detail = '准备中…';
  ComfyRunStatus? runStatus;
  String? error;
  List<String> outputs = const [];

  bool get isActive =>
      phase != _ComfyJobPhase.completed &&
      phase != _ComfyJobPhase.cancelled &&
      phase != _ComfyJobPhase.failed;

  bool get isTerminal => !isActive;
}

class ComfyPanel extends ConsumerStatefulWidget {
  const ComfyPanel({super.key});

  @override
  ConsumerState<ComfyPanel> createState() => _ComfyPanelState();
}

class _ComfyPanelState extends ConsumerState<ComfyPanel> {
  ComfyTemplate? _selected;
  Map<String, dynamic>? _workflow;
  final Map<String, dynamic> _values = {};
  final Map<String, bool> _enabled = {};
  final Map<String, bool> _expanded = {};
  final Map<String, TextEditingController> _textCtrls = {};
  /// 用户自定义节点顺序（nodeId 列表）；空则按名称归类排序。
  List<String> _nodeOrder = [];

  String? _outputDir;
  final TextEditingController _outputNameCtrl = TextEditingController();
  bool _online = false;
  bool _checking = false;
  String? _formError;
  final List<_ComfyJob> _jobs = [];
  static const _kMaxJobs = 30;

  Timer? _hotReloadTimer;
  Timer? _sessionPersistTimer;
  String _lastSig = '';
  double _leftSplit = 0.38;

  @override
  void initState() {
    super.initState();
    _hotReloadTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _pollHotReload();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkConnection());
  }

  @override
  void dispose() {
    _hotReloadTimer?.cancel();
    _sessionPersistTimer?.cancel();
    _outputNameCtrl.dispose();
    for (final j in _jobs) {
      if (j.isActive) j.cancelToken.cancel();
    }
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pollHotReload() async {
    try {
      final sig = await ComfyTemplateStore.directorySignature();
      if (sig != _lastSig) {
        final first = _lastSig.isEmpty;
        _lastSig = sig;
        if (!first && mounted) {
          ref.read(comfyActionsTickProvider.notifier).state++;
        }
      }
    } catch (_) {}
  }

  String get _serverId => ref.read(comfySelectedServerIdProvider);

  /// 任务按 Comfy URL（serverId）隔离；其它 URL 上的任务仍在后台跑，切回去还能看到。
  List<_ComfyJob> _jobsForServer(String serverId) =>
      _jobs.where((j) => j.serverId == serverId).toList(growable: false);

  ComfyClient _client() => ComfyClient(
        baseUrl: ref.read(comfyBaseUrlProvider),
        apiKey: ref.read(comfyApiKeyProvider),
      );

  Future<void> _checkConnection() async {
    setState(() => _checking = true);
    final client = _client();
    try {
      final ok = await client.ping();
      if (mounted) setState(() => _online = ok);
    } finally {
      client.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _selectServer(String id) async {
    await AppConfig.instance.setComfySelectedServerId(id);
    ref.read(comfySelectedServerIdProvider.notifier).state = id;
    await _checkConnection();
    final bundle = ref.read(comfyBundleProvider).valueOrNull;
    if (bundle == null) return;
    final sel = bundle.bindings.forServer(id).selectedTemplateId;
    ComfyTemplate? t;
    if (sel != null) {
      for (final x in bundle.templates) {
        if (x.id == sel) {
          t = x;
          break;
        }
      }
    }
    if (t != null) {
      await _selectTemplate(t);
    } else {
      _clearForm();
      setState(() => _selected = null);
    }
  }

  void _clearForm() {
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    _textCtrls.clear();
    _values.clear();
    _enabled.clear();
    _expanded.clear();
    _nodeOrder = [];
    _formError = null;
    _workflow = null;
    _outputNameCtrl.clear();
  }

  Future<void> _selectTemplate(ComfyTemplate template) async {
    _clearForm();
    try {
      await ComfyTemplateStore.selectTemplate(
        serverId: _serverId,
        templateId: template.id,
      );
      ref.read(comfyActionsTickProvider.notifier).state++;

      final wf = await ComfyTemplateStore.loadWorkflowMap(template);
      final session = await ComfyGenSession.load(
        serverId: _serverId,
        templateId: template.id,
      );
      for (final node in template.nodes) {
        _enabled[node.nodeId] =
            session.enabled[node.nodeId] ?? node.defaultEnabled;
        _expanded[node.nodeId] = session.expanded[node.nodeId] ?? true;
        for (final field in node.fields) {
          final rawNode = wf[field.nodeId];
          dynamic def;
          if (rawNode is Map && rawNode['inputs'] is Map) {
            def = (rawNode['inputs'] as Map)[field.inputKey];
          }
          def ??= _defaultFor(field.widget);
          final remembered = session.values[field.id];
          final value = remembered ?? def;
          _values[field.id] = value;
          if (field.widget != ComfyWidgetKind.bool && !field.widget.isMedia) {
            _textCtrls[field.id] = TextEditingController(
              text: '${_values[field.id] ?? ''}',
            );
          }
        }
      }
      final selectedFile = ref.read(selectedFileProvider);
      for (final node in template.nodes) {
        for (final field in node.fields) {
          if (!field.widget.isMedia || selectedFile == null) continue;
          // 仅当会话未记住媒体路径时，才用当前选中文件填入。
          final remembered = session.values[field.id]?.toString() ?? '';
          if (remembered.isEmpty) {
            _values[field.id] = selectedFile;
          }
        }
      }
      setState(() {
        _selected = template;
        _workflow = wf;
        _nodeOrder = session.order;
        _outputNameCtrl.text = session.outputFileName;
        _formError = null;
      });
    } catch (e) {
      setState(() {
        _selected = template;
        _workflow = null;
        _formError = '加载 workflow 失败：$e';
      });
    }
  }

  void _syncTextValuesFromControllers() {
    for (final e in _textCtrls.entries) {
      _values[e.key] = e.value.text;
    }
  }

  void _schedulePersistSession() {
    _sessionPersistTimer?.cancel();
    _sessionPersistTimer = Timer(const Duration(milliseconds: 350), () {
      _persistSession();
    });
  }

  Future<void> _persistSession() async {
    final t = _selected;
    if (t == null) return;
    _syncTextValuesFromControllers();
    final session = ComfyGenSession(
      order: _nodeOrder,
      enabled: Map<String, bool>.from(_enabled),
      expanded: Map<String, bool>.from(_expanded),
      values: {
        for (final e in _values.entries)
          if (e.value != null) e.key: e.value,
      },
      outputFileName: _outputNameCtrl.text.trim(),
    );
    await ComfyGenSession.save(
      serverId: _serverId,
      templateId: t.id,
      session: session,
    );
  }

  List<ComfyExposedNode> _orderedNodes() {
    final t = _selected;
    if (t == null) return const [];
    return ComfyNodeGroup.orderExposedNodes(
      t.nodes,
      rememberedOrder: _nodeOrder.isEmpty ? null : _nodeOrder,
      displayLabelOf: (n) {
        final consumers = _workflow == null
            ? const <ComfyConsumerLink>[]
            : ComfyDiscover.consumersOf(_workflow!, n.nodeId);
        return ComfyNodeGroup.labelWithPins(n.label, consumers);
      },
    );
  }

  void _onReorderNodes(int oldIndex, int newIndex) {
    final ordered = _orderedNodes();
    if (oldIndex < 0 || oldIndex >= ordered.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex > ordered.length) return;
    final item = ordered.removeAt(oldIndex);
    ordered.insert(newIndex.clamp(0, ordered.length), item);
    setState(() {
      _nodeOrder = ordered.map((e) => e.nodeId).toList();
    });
    _schedulePersistSession();
  }

  void _setNodeEnabled(String nodeId, bool value) {
    setState(() => _enabled[nodeId] = value);
    _schedulePersistSession();
  }

  void _setFieldValue(String fieldId, dynamic value) {
    setState(() => _values[fieldId] = value);
    _schedulePersistSession();
  }

  void _setAllExpanded(bool value) {
    final t = _selected;
    if (t == null) return;
    setState(() {
      for (final n in _orderedNodes()) {
        _expanded[n.nodeId] = value;
      }
    });
    _schedulePersistSession();
  }

  dynamic _defaultFor(ComfyWidgetKind w) {
    switch (w) {
      case ComfyWidgetKind.int:
        return 0;
      case ComfyWidgetKind.float:
        return 0.0;
      case ComfyWidgetKind.bool:
        return false;
      default:
        return '';
    }
  }

  bool _mediaMatches(ComfyWidgetKind kind, String path) {
    final e = p.extension(path).toLowerCase();
    switch (kind) {
      case ComfyWidgetKind.image:
        return const {'.png', '.jpg', '.jpeg', '.webp', '.gif', '.bmp'}
            .contains(e);
      case ComfyWidgetKind.audio:
        return const {'.wav', '.mp3', '.flac', '.ogg', '.m4a', '.aac'}
            .contains(e);
      case ComfyWidgetKind.video:
        return const {'.mp4', '.webm', '.mov', '.mkv', '.avi'}.contains(e);
      default:
        return false;
    }
  }

  Future<void> _bindMore(List<ComfyTemplate> all, ComfyServerBinding binding) async {
    final picked = await showBindTemplatesPicker(
      context,
      all: all,
      alreadyBound: binding.templateIds.toSet(),
    );
    if (picked == null || picked.isEmpty) return;
    await ComfyTemplateStore.bindTemplates(
      serverId: _serverId,
      addTemplateIds: picked,
    );
    ref.read(comfyActionsTickProvider.notifier).state++;
    if (mounted) showGlobalToast(context, '已绑定 ${picked.length} 个模板');
  }

  Future<void> _unbind(ComfyTemplate t) async {
    await ComfyTemplateStore.unbindTemplate(
      serverId: _serverId,
      templateId: t.id,
    );
    if (_selected?.id == t.id) {
      _clearForm();
      setState(() => _selected = null);
    }
    ref.read(comfyActionsTickProvider.notifier).state++;
  }

  String _defaultOutputDir() {
    final selectedDir = ref.read(selectedDirProvider);
    final root = AppConfig.instance.projectRoot;
    return selectedDir ?? root;
  }

  Future<void> _pickOutputDir() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择生成输出目录',
      initialDirectory: _outputDir ?? _defaultOutputDir(),
    );
    if (path == null) return;
    setState(() => _outputDir = path);
  }

  void _useSelectedAsOutputDir() {
    final base = _defaultOutputDir();
    if (base.isEmpty) {
      showGlobalToast(context, '请先在左侧选中目录');
      return;
    }
    setState(() => _outputDir = base);
  }

  String _resolveOutputDir() {
    final explicit = _outputDir?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final fallback = _defaultOutputDir();
    if (fallback.isEmpty) throw StateError('请先选择输出目录');
    return fallback;
  }

  Map<String, dynamic> _deepCopyMap(Map<String, dynamic> src) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(src)) as Map);

  void _mutateJob(String jobId, void Function(_ComfyJob job) fn) {
    if (!mounted) return;
    final i = _jobs.indexWhere((j) => j.id == jobId);
    if (i < 0) return;
    setState(() => fn(_jobs[i]));
  }

  Future<void> _cancelJob(_ComfyJob job) async {
    if (!job.isActive || job.cancelling) return;
    _mutateJob(job.id, (j) {
      j.cancelling = true;
      j.detail = '正在取消…';
    });
    job.cancelToken.cancel();
    final id = job.promptId;
    if (id == null) return;
    final client = ComfyClient(baseUrl: job.baseUrl, apiKey: ref.read(comfyApiKeyProvider));
    try {
      // 仅当本任务正在执行时 interrupt，避免误杀其它任务。
      final running = job.phase == _ComfyJobPhase.running ||
          job.runStatus?.phase == ComfyRunPhase.running;
      if (running) {
        try {
          await client.interrupt();
        } catch (_) {}
      }
      try {
        await client.deleteFromQueue([id]);
      } catch (_) {}
    } finally {
      client.close();
    }
  }

  void _dismissJob(String jobId) {
    setState(() => _jobs.removeWhere((j) => j.id == jobId));
  }

  void _clearFinishedJobs() {
    final id = _serverId;
    setState(
      () => _jobs.removeWhere((j) => j.serverId == id && j.isTerminal),
    );
  }

  /// 入队一次生成：快照当前表单，不锁定界面；可继续编辑并再次生成。
  Future<void> _run() async {
    final template = _selected;
    final wf = _workflow;
    if (template == null || wf == null) return;
    final nodes = template.nodes;
    if (nodes.isEmpty) {
      setState(() => _formError = '模板没有暴露节点，请在模板库重新配置');
      return;
    }

    _syncTextValuesFromControllers();

    final String outputDir;
    try {
      outputDir = _resolveOutputDir();
    } catch (e) {
      setState(() => _formError = '$e');
      showGlobalToast(context, '$e');
      return;
    }

    final runtimeValues = Map<String, dynamic>.from(_values);
    final enabledByNode = <String, bool>{
      for (final node in nodes)
        node.nodeId: node.bypassWhenDisabled
            ? (_enabled[node.nodeId] ?? node.defaultEnabled)
            : true,
    };

    // 入队前本地校验媒体路径，避免空任务进列表。
    for (final node in nodes) {
      final on = enabledByNode[node.nodeId] ?? true;
      if (!on) continue;
      for (final field in node.fields) {
        if (!field.widget.isMedia) continue;
        final path = runtimeValues[field.id]?.toString() ?? '';
        if (path.isEmpty) {
          final msg = '请为「${node.label} / ${field.label}」选择文件，或禁用该节点';
          setState(() => _formError = msg);
          showGlobalToast(context, msg);
          return;
        }
        if (!File(path).existsSync()) {
          final msg = '文件不存在：$path';
          setState(() => _formError = msg);
          showGlobalToast(context, msg);
          return;
        }
      }
    }

    final job = _ComfyJob(
      id: 'job_${DateTime.now().millisecondsSinceEpoch}_${_jobs.length}',
      templateId: template.id,
      templateName: template.name,
      serverId: _serverId,
      baseUrl: ref.read(comfyBaseUrlProvider),
      outputDir: outputDir,
      outputFileName: _outputNameCtrl.text.trim(),
      cancelToken: ComfyCancelToken(),
    );

    final workflowSnap = _deepCopyMap(wf);
    final valuesSnap = Map<String, dynamic>.from(runtimeValues);
    final enabledSnap = Map<String, bool>.from(enabledByNode);
    final nodesSnap = List<ComfyExposedNode>.from(nodes);

    setState(() {
      _formError = null;
      _jobs.insert(0, job);
      // 每个 URL 各自保留上限，避免 A 的历史挤掉 B 的进行中任务。
      while (_jobs.where((j) => j.serverId == job.serverId).length > _kMaxJobs) {
        final idx = _jobs.lastIndexWhere(
          (j) => j.serverId == job.serverId && j.isTerminal,
        );
        if (idx < 0) break;
        _jobs.removeAt(idx);
      }
    });

    showGlobalToast(context, '已加入生成队列');
    unawaited(
      _executeJob(
        job: job,
        workflow: workflowSnap,
        nodes: nodesSnap,
        values: valuesSnap,
        enabledByNode: enabledSnap,
      ),
    );
  }

  Future<void> _executeJob({
    required _ComfyJob job,
    required Map<String, dynamic> workflow,
    required List<ComfyExposedNode> nodes,
    required Map<String, dynamic> values,
    required Map<String, bool> enabledByNode,
  }) async {
    final client = ComfyClient(
      baseUrl: job.baseUrl,
      apiKey: ref.read(comfyApiKeyProvider),
    );
    final cancel = job.cancelToken;
    try {
      final online = await client.ping();
      if (!online) {
        throw ComfyApiException('无法连接 ComfyUI（${job.baseUrl}）');
      }
      if (cancel.isCancelled) throw const ComfyCancelledException();

      final runtimeValues = Map<String, dynamic>.from(values);
      for (final node in nodes) {
        if (cancel.isCancelled) throw const ComfyCancelledException();
        final on = enabledByNode[node.nodeId] ?? true;
        if (!on) continue;
        for (final field in node.fields) {
          if (!field.widget.isMedia) continue;
          final path = runtimeValues[field.id]?.toString() ?? '';
          final file = File(path);
          _mutateJob(job.id, (j) {
            j.phase = _ComfyJobPhase.uploading;
            j.detail = '上传 ${node.label} · ${field.label}…';
          });
          runtimeValues[field.id] = await client.uploadInputFile(file);
        }
      }

      if (cancel.isCancelled) throw const ComfyCancelledException();
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.submitting;
        j.detail = '提交工作流…';
      });

      final prompt = ComfyDiscover.applyExposedValues(
        workflow,
        nodes,
        runtimeValues,
        enabledByNode: enabledByNode,
      );
      final history = await client.runPrompt(
        prompt,
        cancelToken: cancel,
        onPromptId: (id) {
          _mutateJob(job.id, (j) => j.promptId = id);
        },
        onStatus: (s) {
          _mutateJob(job.id, (j) {
            j.runStatus = s;
            j.detail = '${s.detail} · 已用时 ${s.elapsedLabel}';
            j.phase = switch (s.phase) {
              ComfyRunPhase.queued => _ComfyJobPhase.queued,
              ComfyRunPhase.running => _ComfyJobPhase.running,
              ComfyRunPhase.completed => _ComfyJobPhase.running,
              ComfyRunPhase.waiting => _ComfyJobPhase.queued,
              ComfyRunPhase.cancelled => _ComfyJobPhase.cancelled,
            };
          });
        },
      );

      if (cancel.isCancelled) throw const ComfyCancelledException();
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.downloading;
        j.detail = '下载结果 → ${job.outputDir}';
      });
      final saved = await client.saveOutputsToDir(
        historyEntry: history,
        destDir: job.outputDir,
        preferredFileName: job.outputFileName,
      );
      ref.read(treeRefreshTickProvider.notifier).state++;
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.completed;
        j.detail = '完成，已保存 ${saved.length} 个文件';
        j.outputs = saved;
        j.runStatus = null;
        j.cancelling = false;
      });
      if (mounted) showGlobalToast(context, '生成完成：${job.templateName}');
    } on ComfyCancelledException {
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.cancelled;
        j.detail = '已取消';
        j.error = null;
        j.runStatus = null;
        j.cancelling = false;
      });
    } catch (e) {
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.failed;
        j.detail = '失败';
        j.error = '$e';
        j.runStatus = null;
        j.cancelling = false;
      });
    } finally {
      client.close();
    }
  }

  Future<void> _pickMedia(ComfyExposedField field) async {
    final result = await FilePicker.pickFiles(
      type: field.widget == ComfyWidgetKind.image
          ? FileType.image
          : FileType.any,
      dialogTitle: '选择 ${field.label}',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    _setFieldValue(field.id, path);
  }

  void _useSelectedFile(ComfyExposedField field) {
    final f = ref.read(selectedFileProvider);
    if (f == null || !_mediaMatches(field.widget, f)) {
      showGlobalToast(context, '请先选中匹配类型的文件');
      return;
    }
    _setFieldValue(field.id, f);
  }

  @override
  Widget build(BuildContext context) {
    final bundleAsync = ref.watch(comfyBundleProvider);
    final servers = ref.watch(comfyServersProvider);
    final selectedServerId = ref.watch(comfySelectedServerIdProvider);
    final baseUrl = ref.watch(comfyBaseUrlProvider);
    final cs = Theme.of(context).colorScheme;

    ref.listen(comfySelectedServerIdProvider, (prev, next) {
      if (prev == next) return;
      _checkConnection();
    });

    ref.listen(comfyBundleProvider, (prev, next) {
      next.whenData((bundle) {
        final cur = _selected;
        if (cur == null) return;
        final match = bundle.templates.where((t) => t.id == cur.id).toList();
        if (match.isEmpty) {
          _clearForm();
          setState(() => _selected = null);
        } else if (match.first.nodes.length != cur.nodes.length ||
            match.first.templatePath != cur.templatePath) {
          _selectTemplate(match.first);
        }
      });
    });

    return bundleAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (bundle) {
        final binding = bundle.bindings.forServer(selectedServerId);
        final boundTemplates = <ComfyTemplate>[];
        for (final id in binding.templateIds) {
          for (final t in bundle.templates) {
            if (t.id == id) {
              boundTemplates.add(t);
              break;
            }
          }
        }
        return Row(
          children: [
            SizedBox(
              width: 230,
              child: Material(
                color: cs.surfaceContainerLow,
                child: Column(
                  children: [
                    Expanded(
                      flex: (_leftSplit * 100).round().clamp(25, 60),
                      child: _buildServerList(
                        servers,
                        selectedServerId,
                        baseUrl,
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: (d) {
                        setState(() {
                          _leftSplit =
                              (_leftSplit + d.delta.dy / 400).clamp(0.22, 0.7);
                        });
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: Container(
                          height: 6,
                          color: cs.outlineVariant.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: ((1 - _leftSplit) * 100).round().clamp(40, 75),
                      child: _buildTemplateList(
                        boundTemplates,
                        binding,
                        bundle.templates,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: _selected == null
                  ? Center(
                      child: Text(
                        boundTemplates.isEmpty
                            ? '请绑定模板，或打开模板库导入'
                            : '选择左下模板开始生成',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : _buildDetail(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildServerList(
    List<ComfyServer> servers,
    String selectedId,
    String baseUrl,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Comfy URL',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Icon(
                _checking
                    ? Icons.hourglass_top
                    : (_online ? Icons.cloud_done : Icons.cloud_off),
                size: 14,
                color: _checking
                    ? cs.onSurfaceVariant
                    : (_online ? Colors.green : cs.error),
              ),
              const SizedBox(width: 2),
              TextButton(
                onPressed: _checking ? null : _checkConnection,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(_checking ? '检测中' : '重试'),
              ),
            ],
          ),
        ),
        if (servers.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Text(
              _online ? '已连接' : '未连接 · $baseUrl',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _online ? Colors.green.shade700 : cs.error,
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: servers.isEmpty
              ? Center(
                  child: Text(
                    '请先在设置中添加实例',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: servers.length,
                  itemBuilder: (context, i) {
                    final s = servers[i];
                    final active = s.id == selectedId;
                    return ListTile(
                      dense: true,
                      selected: active,
                      title: Text(s.name, maxLines: 1),
                      subtitle: Text(
                        s.baseUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: active
                          ? Icon(
                              _online ? Icons.circle : Icons.circle_outlined,
                              size: 10,
                              color: _online ? Colors.green : cs.error,
                            )
                          : null,
                      onTap: () => _selectServer(s.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildTemplateList(
    List<ComfyTemplate> bound,
    ComfyServerBinding binding,
    List<ComfyTemplate> all,
  ) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
          child: Row(
            children: [
              Text('已绑模板', style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              IconButton(
                tooltip: '绑定模板',
                icon: const Icon(Icons.link, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => _bindMore(all, binding),
              ),
              IconButton(
                tooltip: '模板库',
                icon: const Icon(Icons.library_books_outlined, size: 18),
                visualDensity: VisualDensity.compact,
                onPressed: () => showComfyTemplateLibrary(context, ref),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: bound.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '尚未绑定模板。\n点链接图标绑定，或打开模板库导入。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: bound.length,
                  itemBuilder: (context, i) {
                    final t = bound[i];
                    final active = _selected?.id == t.id;
                    return ListTile(
                      dense: true,
                      selected: active,
                      title: Text(t.name, maxLines: 1),
                      subtitle: Text(
                        '${t.nodes.length} 个节点',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        tooltip: '从此 URL 移除',
                        icon: const Icon(Icons.link_off, size: 16),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _unbind(t),
                      ),
                      onTap: () => _selectTemplate(t),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDetail() {
    final t = _selected!;
    final cs = Theme.of(context).colorScheme;
    final serverJobs = _jobsForServer(_serverId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              TextButton(
                onPressed: () => _setAllExpanded(true),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('展开'),
              ),
              TextButton(
                onPressed: () => _setAllExpanded(false),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('折叠'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _workflow == null || t.nodes.isEmpty ? null : _run,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 34),
                ),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(
                  serverJobs.any((j) => j.isActive) ? '继续生成' : '生成',
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(t.name, style: Theme.of(context).textTheme.titleMedium),
                    Text(
                      'workflow: ${t.workflowFile}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 12),
                    Text('输出目录', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            (_outputDir != null && _outputDir!.trim().isNotEmpty)
                                ? _outputDir!
                                : (_defaultOutputDir().isNotEmpty
                                    ? _defaultOutputDir()
                                    : '未选择'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: _useSelectedAsOutputDir,
                          child: const Text('用当前选中'),
                        ),
                        FilledButton.tonal(
                          onPressed: _pickOutputDir,
                          child: const Text('浏览'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text('保存文件名', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _outputNameCtrl,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '留空则用 Comfy 原名；多文件自动加 _2、_3…',
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: cs.onSurfaceVariant,
                        ),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 10,
                        ),
                      ),
                      style: const TextStyle(fontSize: 13),
                      onChanged: (_) => _schedulePersistSession(),
                    ),
                    if (_formError != null) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        _formError!,
                        style: TextStyle(color: cs.error, fontSize: 12),
                      ),
                    ],
                    if (serverJobs.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _buildJobList(cs, serverJobs),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '可继续改参数后再次点生成；任务按当前 URL 分列，其它 URL 任务切回去仍可见',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  buildDefaultDragHandles: false,
                  itemCount: _orderedNodes().length,
                  onReorder: _onReorderNodes,
                  itemBuilder: (context, index) {
                    final nodes = _orderedNodes();
                    final node = nodes[index];
                    return _buildNodeBlock(
                      node,
                      index: index,
                      key: ValueKey(node.nodeId),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildJobList(ColorScheme cs, List<_ComfyJob> jobs) {
    final activeCount = jobs.where((j) => j.isActive).length;
    final finishedCount = jobs.length - activeCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('生成任务', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 8),
            Text(
              activeCount > 0 ? '进行中 $activeCount' : '无进行中任务',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const Spacer(),
            if (finishedCount > 0)
              TextButton(
                onPressed: _clearFinishedJobs,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('清除已结束'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _buildJobCard(jobs[i], cs),
          ),
        ),
      ],
    );
  }

  Widget _buildJobCard(_ComfyJob job, ColorScheme cs) {
    final phaseLabel = switch (job.phase) {
      _ComfyJobPhase.preparing => '准备中',
      _ComfyJobPhase.uploading => '上传中',
      _ComfyJobPhase.submitting => '提交中',
      _ComfyJobPhase.queued => '排队中',
      _ComfyJobPhase.running => '执行中',
      _ComfyJobPhase.downloading => '下载中',
      _ComfyJobPhase.completed => '已完成',
      _ComfyJobPhase.cancelled => '已取消',
      _ComfyJobPhase.failed => '失败',
    };
    final color = switch (job.phase) {
      _ComfyJobPhase.failed => cs.error,
      _ComfyJobPhase.cancelled => cs.onSurfaceVariant,
      _ComfyJobPhase.completed => Colors.green.shade700,
      _ => cs.primary,
    };
    final progress = job.runStatus?.progressFraction;
    final time = TimeOfDay.fromDateTime(job.createdAt);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (job.isActive ? cs.primary : cs.outlineVariant)
              .withValues(alpha: 0.7),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (job.isActive) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                    value: progress,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  '${job.templateName} · $phaseLabel',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: color,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              if (job.isActive)
                TextButton(
                  onPressed: job.cancelling ? null : () => _cancelJob(job),
                  style: TextButton.styleFrom(
                    foregroundColor: cs.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(job.cancelling ? '取消中…' : '取消'),
                )
              else
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _dismissJob(job.id),
                ),
            ],
          ),
          if (job.isActive) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                minHeight: 5,
                value: progress,
                color: cs.primary,
                backgroundColor: cs.surfaceContainerLow,
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            job.detail,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 4),
          Text(
            '输出：${job.outputDir}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
          if (job.outputFileName.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              '文件名：${job.outputFileName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
          if (job.runStatus != null) ...[
            const SizedBox(height: 4),
            Text(
              [
                if (job.runStatus!.progressLabel.isNotEmpty)
                  job.runStatus!.progressLabel,
                if (job.runStatus!.currentNodeId != null)
                  '节点 ${job.runStatus!.currentNodeId}',
                '用时 ${job.runStatus!.elapsedLabel}',
                if (job.promptId != null)
                  '任务 ${job.promptId!.length > 10 ? '${job.promptId!.substring(0, 10)}…' : job.promptId}',
              ].join('  ·  '),
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
          if (job.error != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              job.error!,
              style: TextStyle(color: cs.error, fontSize: 11),
            ),
          ],
          if (job.outputs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '输出文件：${job.outputs.map(p.basename).join('、')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNodeBlock(
    ComfyExposedNode node, {
    required int index,
    required Key key,
  }) {
    final cs = Theme.of(context).colorScheme;
    final canBypass = node.bypassWhenDisabled;
    final on = canBypass
        ? (_enabled[node.nodeId] ?? node.defaultEnabled)
        : true;
    final expanded = _expanded[node.nodeId] ?? true;
    final consumers = _workflow == null
        ? const <ComfyConsumerLink>[]
        : ComfyDiscover.consumersOf(_workflow!, node.nodeId);
    final displayLabel = ComfyNodeGroup.labelWithPins(node.label, consumers);

    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: EdgeInsets.fromLTRB(4, 4, 12, expanded ? 12 : 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      Icons.drag_handle,
                      size: 22,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 22,
                  ),
                  onPressed: () {
                    setState(() => _expanded[node.nodeId] = !expanded);
                    _schedulePersistSession();
                  },
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayLabel,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${node.nodeId} · ${node.classType}'
                        '${node.bypassWhenDisabled ? ' · 禁用即 Bypass' : ''}',
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      if (consumers.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            consumers.map((c) => c.shortLabel).join('\n'),
                            style: TextStyle(
                              fontSize: 11,
                              color: cs.primary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (canBypass)
                  Switch(
                    value: on,
                    onChanged: (v) => _setNodeEnabled(node.nodeId, v),
                  ),
              ],
            ),
            if (expanded) ...[
              if (canBypass && !on)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 6),
                  child: Text(
                    '已禁用：本次生成将 Bypass 整个节点',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
              if (consumers.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '下游输入点',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ...consumers.map(
                        (c) => Container(
                          width: double.infinity,
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: cs.outlineVariant),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.inputKey,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  fontFamily: 'Consolas',
                                  color: cs.primary,
                                ),
                              ),
                              Text(
                                c.detailLine,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Opacity(
                opacity: on ? 1 : 0.45,
                child: IgnorePointer(
                  ignoring: !on,
                  child: Column(
                    children: [
                      for (final field in node.fields) _buildFieldBody(field),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFieldBody(ComfyExposedField field) {
    switch (field.widget) {
      case ComfyWidgetKind.bool:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.label),
          value: _values[field.id] == true,
          onChanged: (v) => _setFieldValue(field.id, v),
        );
      case ComfyWidgetKind.image:
      case ComfyWidgetKind.audio:
      case ComfyWidgetKind.video:
        final path = _values[field.id]?.toString() ?? '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: const TextStyle(fontSize: 13)),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      path.isEmpty ? '未选择' : path,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _useSelectedFile(field),
                    child: const Text('用当前选中'),
                  ),
                  FilledButton.tonal(
                    onPressed: () => _pickMedia(field),
                    child: const Text('浏览'),
                  ),
                ],
              ),
            ],
          ),
        );
      case ComfyWidgetKind.multiline:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _textCtrls[field.id],
            maxLines: 5,
            onChanged: (_) => _schedulePersistSession(),
            decoration: InputDecoration(
              labelText: field.label,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        );
      case ComfyWidgetKind.int:
      case ComfyWidgetKind.float:
      case ComfyWidgetKind.text:
      case ComfyWidgetKind.choice:
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            controller: _textCtrls[field.id],
            onChanged: (_) => _schedulePersistSession(),
            keyboardType: field.widget == ComfyWidgetKind.int ||
                    field.widget == ComfyWidgetKind.float
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            decoration: InputDecoration(
              labelText: field.label,
              border: const OutlineInputBorder(),
            ),
          ),
        );
    }
  }
}
