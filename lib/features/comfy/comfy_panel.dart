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
import '../../core/path_ellipsis_text.dart';
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
  /// 分区展开：key = [ComfyNodeGroup.sortCategory] 整型字符串。
  final Map<String, bool> _categoryExpanded = {};
  final Map<String, TextEditingController> _textCtrls = {};
  final Map<String, FocusNode> _textFocus = {};
  /// 用户自定义节点顺序（nodeId 列表）；空则按名称归类排序。
  List<String> _nodeOrder = [];
  /// 分类分区顺序（sortCategory 整型）；空则 0→4。
  List<int> _categoryOrder = [];

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
  /// 忽略过期的连接检测 / 模板加载，避免切换 URL 时连环闪烁。
  int _connGen = 0;
  int _loadGen = 0;
  bool _autoSelectScheduled = false;

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
    for (final f in _textFocus.values) {
      f.dispose();
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
    final gen = ++_connGen;
    if (mounted) setState(() => _checking = true);
    final client = _client();
    try {
      final ok = await client.ping();
      if (!mounted || gen != _connGen) return;
      setState(() {
        _online = ok;
        _checking = false;
      });
    } catch (_) {
      if (!mounted || gen != _connGen) return;
      setState(() {
        _online = false;
        _checking = false;
      });
    } finally {
      client.close();
    }
  }

  Future<void> _selectServer(String id) async {
    final already = id == ref.read(comfySelectedServerIdProvider);
    if (already) {
      // 启动后默认就是第一个 URL 时，再点不会触发切换；若详情为空则补加载。
      if (_selected == null) {
        final bundle = ref.read(comfyBundleProvider).valueOrNull;
        if (bundle != null) await _ensureSelectedFromBundle(bundle);
      }
      return;
    }
    _sessionPersistTimer?.cancel();
    await _persistSession();
    await AppConfig.instance.setComfySelectedServerId(id);
    ref.read(comfySelectedServerIdProvider.notifier).state = id;
    // 连接检测由 listen 触发；这里不 await，避免挡住模板切换。
    final bundle = ref.read(comfyBundleProvider).valueOrNull;
    if (bundle == null) return;
    await _ensureSelectedFromBundle(bundle, force: true);
  }

  /// 按当前 URL 的绑定，选中「上次选中」或第一个已绑模板。
  Future<void> _ensureSelectedFromBundle(
    _ComfyBundle bundle, {
    bool force = false,
  }) async {
    if (!force && _selected != null) return;
    final serverId = ref.read(comfySelectedServerIdProvider);
    final binding = bundle.bindings.forServer(serverId);
    final boundIds = binding.templateIds.toSet();

    ComfyTemplate? pick;
    final sel = binding.selectedTemplateId;
    if (sel != null && boundIds.contains(sel)) {
      for (final x in bundle.templates) {
        if (x.id == sel) {
          pick = x;
          break;
        }
      }
    }
    if (pick == null) {
      for (final id in binding.templateIds) {
        for (final x in bundle.templates) {
          if (x.id == id) {
            pick = x;
            break;
          }
        }
        if (pick != null) break;
      }
    }

    if (pick != null) {
      await _selectTemplate(pick, persistCurrent: false);
    } else if (force || _selected != null) {
      _loadGen++;
      _clearForm();
      if (mounted) setState(() => _selected = null);
    }
  }

  void _clearForm() {
    for (final c in _textCtrls.values) {
      c.dispose();
    }
    _textCtrls.clear();
    for (final f in _textFocus.values) {
      f.dispose();
    }
    _textFocus.clear();
    _values.clear();
    _enabled.clear();
    _expanded.clear();
    _categoryExpanded.clear();
    _nodeOrder = [];
    _categoryOrder = [];
    _formError = null;
    _workflow = null;
    _outputNameCtrl.clear();
  }

  Future<void> _selectTemplate(
    ComfyTemplate template, {
    bool persistCurrent = true,
  }) async {
    final gen = ++_loadGen;
    final serverId = ref.read(comfySelectedServerIdProvider);
    if (persistCurrent) {
      _sessionPersistTimer?.cancel();
      await _persistSession();
    }
    try {
      await ComfyTemplateStore.selectTemplate(
        serverId: serverId,
        templateId: template.id,
      );
      // 不 bump tick：高亮用 [_selected]，整表刷新会让 FutureProvider 进 loading 闪屏。

      final wf = await ComfyTemplateStore.loadWorkflowMap(template);
      final session = await ComfyGenSession.load(
        serverId: serverId,
        templateId: template.id,
      );
      if (!mounted || gen != _loadGen) return;

      final enabled = <String, bool>{};
      final expanded = <String, bool>{};
      final values = <String, dynamic>{};
      final textCtrls = <String, TextEditingController>{};
      final textFocus = <String, FocusNode>{};
      for (final node in template.nodes) {
        enabled[node.nodeId] =
            session.enabled[node.nodeId] ?? node.defaultEnabled;
        expanded[node.nodeId] = session.expanded[node.nodeId] ?? false;
        for (final field in node.fields) {
          final rawNode = wf[field.nodeId];
          dynamic def;
          if (rawNode is Map && rawNode['inputs'] is Map) {
            def = (rawNode['inputs'] as Map)[field.inputKey];
          }
          def ??= _defaultFor(field.widget);
          final remembered = session.values[field.id];
          values[field.id] = remembered ?? def;
          if (field.widget != ComfyWidgetKind.bool && !field.widget.isMedia) {
            textCtrls[field.id] = TextEditingController(
              text: '${values[field.id] ?? ''}',
            );
            textFocus[field.id] = FocusNode();
          }
        }
      }
      final selectedFile = ref.read(selectedFileProvider);
      for (final node in template.nodes) {
        for (final field in node.fields) {
          if (!field.widget.isMedia || selectedFile == null) continue;
          final remembered = session.values[field.id]?.toString() ?? '';
          if (remembered.isEmpty) {
            values[field.id] = selectedFile;
          }
        }
      }
      if (!mounted || gen != _loadGen) {
        for (final c in textCtrls.values) {
          c.dispose();
        }
        for (final f in textFocus.values) {
          f.dispose();
        }
        return;
      }

      for (final c in _textCtrls.values) {
        c.dispose();
      }
      for (final f in _textFocus.values) {
        f.dispose();
      }
      setState(() {
        _textCtrls
          ..clear()
          ..addAll(textCtrls);
        _textFocus
          ..clear()
          ..addAll(textFocus);
        _values
          ..clear()
          ..addAll(values);
        _enabled
          ..clear()
          ..addAll(enabled);
        _expanded
          ..clear()
          ..addAll(expanded);
        _categoryExpanded
          ..clear()
          ..addAll(session.categoryExpanded);
        _selected = template;
        _workflow = wf;
        _nodeOrder = session.order;
        _categoryOrder = [
          for (final raw in session.categoryOrder)
            if (int.tryParse(raw) != null) int.parse(raw),
        ];
        _outputNameCtrl.text = session.outputFileName;
        _formError = null;
      });
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
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
      categoryOrder: _categoryOrder.map((e) => '$e').toList(),
      enabled: Map<String, bool>.from(_enabled),
      expanded: Map<String, bool>.from(_expanded),
      categoryExpanded: Map<String, bool>.from(_categoryExpanded),
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

  /// 按分类分组；组内顺序跟随 [_orderedNodes]；分区顺序跟随 [_categoryOrder]。
  List<({int category, String label, List<ComfyExposedNode> nodes})>
      _nodeSections() {
    final buckets = <int, List<ComfyExposedNode>>{
      0: [],
      1: [],
      2: [],
      3: [],
      4: [],
    };
    for (final n in _orderedNodes()) {
      buckets.putIfAbsent(ComfyNodeGroup.sortCategory(n.classType), () => [])
          .add(n);
    }
    final present = [
      for (final cat in const [0, 1, 2, 3, 4])
        if (buckets[cat]!.isNotEmpty) cat,
    ];
    final orderedCats = <int>[];
    for (final cat in _categoryOrder) {
      if (present.contains(cat) && !orderedCats.contains(cat)) {
        orderedCats.add(cat);
      }
    }
    for (final cat in present) {
      if (!orderedCats.contains(cat)) orderedCats.add(cat);
    }
    return [
      for (final cat in orderedCats)
        (
          category: cat,
          label: ComfyNodeGroup.categoryLabel(cat),
          nodes: buckets[cat]!,
        ),
    ];
  }

  bool _isCategoryExpanded(int category) =>
      _categoryExpanded['$category'] ??
      ComfyNodeGroup.categoryExpandedByDefault(category);

  void _toggleCategory(int category) {
    setState(() {
      _categoryExpanded['$category'] = !_isCategoryExpanded(category);
    });
    _schedulePersistSession();
  }

  void _onReorderCategories(int oldIndex, int newIndex) {
    final sections = _nodeSections();
    if (oldIndex < 0 ||
        oldIndex >= sections.length ||
        newIndex < 0 ||
        newIndex > sections.length) {
      return;
    }
    final cats = sections.map((s) => s.category).toList();
    final item = cats.removeAt(oldIndex);
    cats.insert(newIndex.clamp(0, cats.length), item);
    setState(() => _categoryOrder = cats);
    _schedulePersistSession();
  }

  void _moveNodeInCategory(int category, int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    final sections = _nodeSections();
    final idx = sections.indexWhere((s) => s.category == category);
    if (idx < 0) return;
    final nodes = List<ComfyExposedNode>.of(sections[idx].nodes);
    if (fromIndex < 0 ||
        fromIndex >= nodes.length ||
        toIndex < 0 ||
        toIndex >= nodes.length) {
      return;
    }
    final item = nodes.removeAt(fromIndex);
    nodes.insert(toIndex, item);
    final rebuilt = <String>[];
    for (final s in sections) {
      if (s.category == category) {
        rebuilt.addAll(nodes.map((e) => e.nodeId));
      } else {
        rebuilt.addAll(s.nodes.map((e) => e.nodeId));
      }
    }
    setState(() => _nodeOrder = rebuilt);
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
            j.detail = '同步素材 ${node.label} · ${field.label}…';
          });
          final uploaded = await client.ensureInputFile(file);
          runtimeValues[field.id] = uploaded.name;
          _mutateJob(job.id, (j) {
            j.detail = uploaded.reusedRemote
                ? '复用远端已有文件 · ${uploaded.name}'
                : '已上传 ${uploaded.name}';
          });
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

      var detail = '完成，已保存 ${saved.length} 个文件';
      final promptId = job.promptId;
      if (ref.read(comfyDeleteRemoteAfterDownloadProvider) &&
          promptId != null &&
          promptId.isNotEmpty) {
        try {
          await client.deleteHistory([promptId]);
          detail = '$detail；已清理远端输出';
        } catch (_) {
          detail = '$detail；远端清理失败（可手动在 Comfy 删除）';
        }
      }

      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.completed;
        j.detail = detail;
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
      // 打开该字段上次所选文件所在目录，避免多参考路径相距很远时反复翻目录。
      initialDirectory: _mediaBrowseInitialDir(field),
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    _setFieldValue(field.id, path);
  }

  /// 当前字段已有媒体路径时，返回其父目录（须存在）；否则让系统沿用默认目录。
  String? _mediaBrowseInitialDir(ComfyExposedField field) {
    final current = _values[field.id]?.toString().trim() ?? '';
    if (current.isEmpty) return null;
    final dir = p.dirname(current);
    if (dir.isEmpty || dir == '.') return null;
    if (!Directory(dir).existsSync()) return null;
    return dir;
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
        if (cur == null) {
          _ensureSelectedFromBundle(bundle);
          return;
        }
        final match = bundle.templates.where((t) => t.id == cur.id).toList();
        if (match.isEmpty) {
          _clearForm();
          setState(() => _selected = null);
          _ensureSelectedFromBundle(bundle, force: true);
        } else if (match.first.nodes.length != cur.nodes.length ||
            match.first.templatePath != cur.templatePath) {
          _selectTemplate(match.first, persistCurrent: false);
        }
      });
    });

    return bundleAsync.when(
      // 目录轮询 / 绑定刷新时保留旧数据，避免整页转圈闪一下。
      skipLoadingOnReload: true,
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
        // 首次进入 / Provider 已有缓存时 listen 可能不补发，这里兜底自动选中。
        if (_selected == null &&
            boundTemplates.isNotEmpty &&
            !_autoSelectScheduled) {
          _autoSelectScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _autoSelectScheduled = false;
            if (!mounted || _selected != null) return;
            _ensureSelectedFromBundle(bundle);
          });
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
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      t.workflowFile,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _workflow == null || t.nodes.isEmpty ? null : _run,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 36),
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
              _buildRunOutputZone(cs, serverJobs),
              _buildZoneDivider(
                cs,
                icon: Icons.tune,
                title: '节点参数',
                subtitle: '点选编辑 · 长按拖拽排序 · 拖分区标题调整顺序',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _setAllExpanded(true),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('全展开'),
                    ),
                    TextButton(
                      onPressed: () => _setAllExpanded(false),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('全折叠'),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildNodeSectionsList()),
            ],
          ),
        ),
      ],
    );
  }

  /// 运行输出功能区：目录 / 文件名 / 远端清理 / 任务队列。
  Widget _buildRunOutputZone(ColorScheme cs, List<_ComfyJob> serverJobs) {
    final dirText = (_outputDir != null && _outputDir!.trim().isNotEmpty)
        ? _outputDir!
        : (_defaultOutputDir().isNotEmpty ? _defaultOutputDir() : '未选择');
    final deleteRemote = ref.watch(comfyDeleteRemoteAfterDownloadProvider);

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.folder_special_outlined, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                '运行输出',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '生成结果保存位置与文件名',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 560;
              final dirField = _buildOutputDirField(cs, dirText);
              final nameField = TextField(
                controller: _outputNameCtrl,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: '保存文件名',
                  hintText: '留空用 Comfy 原名；多文件自动 _2、_3…',
                  prefixIcon: const Icon(Icons.insert_drive_file_outlined, size: 18),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => _schedulePersistSession(),
              );
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: dirField),
                    const SizedBox(width: 10),
                    Expanded(flex: 2, child: nameField),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  dirField,
                  const SizedBox(height: 8),
                  nameField,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Material(
            color: cs.surface.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    deleteRemote
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_done_outlined,
                    size: 18,
                    color: deleteRemote ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '下载后删除远端输出',
                          style: TextStyle(fontSize: 13),
                        ),
                        Text(
                          '本地保存成功后清除 Comfy history/output，适合云 GPU',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: deleteRemote,
                    onChanged: (v) async {
                      ref
                          .read(
                              comfyDeleteRemoteAfterDownloadProvider.notifier)
                          .state = v;
                      await AppConfig.instance
                          .setComfyDeleteRemoteAfterDownload(v);
                    },
                  ),
                ],
              ),
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              _formError!,
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ],
          if (serverJobs.isNotEmpty) ...[
            const SizedBox(height: 10),
            _buildJobList(cs, serverJobs),
          ],
        ],
      ),
    );
  }

  Widget _buildOutputDirField(ColorScheme cs, String dirText) {
    return InputDecorator(
      decoration: const InputDecoration(
        isDense: true,
        labelText: '输出目录',
        prefixIcon: Icon(Icons.folder_outlined, size: 18),
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.fromLTRB(10, 8, 4, 8),
      ),
      child: Row(
        children: [
          Expanded(
            child: PathEllipsisText(
              dirText,
              style: TextStyle(fontSize: 12.5, color: cs.onSurface),
            ),
          ),
          TextButton(
            onPressed: _useSelectedAsOutputDir,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('当前选中'),
          ),
          FilledButton.tonal(
            onPressed: _pickOutputDir,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('浏览'),
          ),
        ],
      ),
    );
  }

  Widget _buildZoneDivider(
    ColorScheme cs, {
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
          ] else
            const Spacer(),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildNodeSectionsList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      buildDefaultDragHandles: false,
      itemCount: _nodeSections().length,
      onReorderItem: _onReorderCategories,
      itemBuilder: (context, sectionIndex) {
        final section = _nodeSections()[sectionIndex];
        final open = _isCategoryExpanded(section.category);
        final expandedNodes = [
          for (final n in section.nodes)
            if (_expanded[n.nodeId] == true) n,
        ];
        return Card(
          key: ValueKey('cat-${section.category}'),
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildCategoryHeader(
                  section.category,
                  section.label,
                  section.nodes.length,
                  sectionIndex: sectionIndex,
                ),
                if (open) ...[
                  const SizedBox(height: 6),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      const gap = 6.0;
                      const minTile = 156.0;
                      final cols =
                          (constraints.maxWidth / minTile).floor().clamp(1, 6);
                      final tileW =
                          (constraints.maxWidth - gap * (cols - 1)) / cols;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        children: [
                          for (var i = 0; i < section.nodes.length; i++)
                            SizedBox(
                              width: tileW,
                              child: _buildNodeTile(
                                section.nodes[i],
                                category: section.category,
                                index: i,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  for (final node in expandedNodes) ...[
                    const SizedBox(height: 8),
                    _buildNodeEditor(node),
                  ],
                ],
              ],
            ),
          ),
        );
      },
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输出：',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
              Expanded(
                child: PathEllipsisText(
                  job.outputDir,
                  maxLines: 2,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          if (job.outputFileName.isNotEmpty) ...[
            const SizedBox(height: 2),
            PathEllipsisText(
              '文件名：${job.outputFileName}',
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
            PathEllipsisText(
              '输出文件：${job.outputs.map(p.basename).join('、')}',
              maxLines: 2,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryHeader(
    int category,
    String label,
    int count, {
    required int sectionIndex,
  }) {
    final cs = Theme.of(context).colorScheme;
    final open = _isCategoryExpanded(category);
    return Row(
      children: [
        ReorderableDragStartListener(
          index: sectionIndex,
          child: Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Icon(
              Icons.drag_indicator,
              size: 20,
              color: cs.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _toggleCategory(category),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    open ? Icons.expand_more : Icons.chevron_right,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String _fieldPreview(ComfyExposedField field) {
    final v = _values[field.id];
    if (v == null) return '';
    if (field.widget.isMedia) {
      final s = v.toString().trim();
      if (s.isEmpty) return '';
      return p.basename(s);
    }
    if (field.widget == ComfyWidgetKind.bool) {
      return v == true ? '${field.label}:开' : '${field.label}:关';
    }
    final s = v.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
    if (s.isEmpty) return '';
    return s.length > 28 ? '${s.substring(0, 28)}…' : s;
  }

  String _nodeValuePreview(ComfyExposedNode node) {
    final parts = <String>[];
    for (final field in node.fields) {
      final text = _fieldPreview(field);
      if (text.isEmpty) continue;
      parts.add(text);
      if (parts.length >= 2) break;
    }
    return parts.join(' · ');
  }

  String _nodeDisplayLabel(ComfyExposedNode node) {
    final consumers = _workflow == null
        ? const <ComfyConsumerLink>[]
        : ComfyDiscover.consumersOf(_workflow!, node.nodeId);
    return ComfyNodeGroup.labelWithPins(node.label, consumers);
  }

  Widget _buildNodeTile(
    ComfyExposedNode node, {
    required int category,
    required int index,
  }) {
    final cs = Theme.of(context).colorScheme;
    final canBypass = node.bypassWhenDisabled;
    final on = canBypass
        ? (_enabled[node.nodeId] ?? node.defaultEnabled)
        : true;
    final expanded = _expanded[node.nodeId] ?? false;
    final displayLabel = _nodeDisplayLabel(node);
    final preview = _nodeValuePreview(node);

    final tile = Material(
      color: expanded
          ? cs.primaryContainer.withValues(alpha: 0.45)
          : cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          final willExpand = !expanded;
          setState(() {
            // 同分区只展开一个，减少编辑区堆叠。
            for (final n in _nodeSections()
                .firstWhere((s) => s.category == category)
                .nodes) {
              _expanded[n.nodeId] = n.nodeId == node.nodeId ? !expanded : false;
            }
          });
          _schedulePersistSession();
          if (willExpand) {
            final canBypass = node.bypassWhenDisabled;
            final on = canBypass
                ? (_enabled[node.nodeId] ?? node.defaultEnabled)
                : true;
            if (on) _focusFirstTextFieldOf(node);
          }
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      preview.isEmpty ? '未填写' : preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (canBypass)
                SizedBox(
                  height: 28,
                  child: Switch(
                    value: on,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => _setNodeEnabled(node.nodeId, v),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return LongPressDraggable<({int category, int index})>(
      data: (category: category, index: index),
      feedback: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 160,
          child: Opacity(opacity: 0.92, child: tile),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: tile),
      child: DragTarget<({int category, int index})>(
        onWillAcceptWithDetails: (details) =>
            details.data.category == category && details.data.index != index,
        onAcceptWithDetails: (details) {
          _moveNodeInCategory(category, details.data.index, index);
        },
        builder: (context, candidate, rejected) {
          final hovering = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: hovering
                  ? Border.all(color: cs.primary, width: 1.5)
                  : Border.all(color: Colors.transparent),
            ),
            child: tile,
          );
        },
      ),
    );
  }

  Widget _buildNodeEditor(ComfyExposedNode node) {
    final cs = Theme.of(context).colorScheme;
    final canBypass = node.bypassWhenDisabled;
    final on = canBypass
        ? (_enabled[node.nodeId] ?? node.defaultEnabled)
        : true;
    final displayLabel = _nodeDisplayLabel(node);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  displayLabel,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              IconButton(
                tooltip: '收起',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  setState(() => _expanded[node.nodeId] = false);
                  _schedulePersistSession();
                },
              ),
            ],
          ),
          if (canBypass && !on)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '已禁用：本次生成将 Bypass 整个节点',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            ),
          Opacity(
            opacity: on ? 1 : 0.45,
            child: IgnorePointer(
              ignoring: !on,
              child: _buildFieldsLayout(node),
            ),
          ),
        ],
      ),
    );
  }

  bool _isTextInputField(ComfyExposedField field) =>
      field.widget == ComfyWidgetKind.multiline ||
      field.widget == ComfyWidgetKind.text ||
      field.widget == ComfyWidgetKind.int ||
      field.widget == ComfyWidgetKind.float ||
      field.widget == ComfyWidgetKind.choice;

  void _focusFirstTextFieldOf(ComfyExposedNode node) {
    String? fieldId;
    FocusNode? target;
    for (final field in node.fields) {
      if (!_isTextInputField(field)) continue;
      final fn = _textFocus[field.id];
      if (fn != null) {
        fieldId = field.id;
        target = fn;
        break;
      }
    }
    if (target == null || fieldId == null) return;
    final focus = target;
    final id = fieldId;

    void placeCaretAtEnd() {
      final ctrl = _textCtrls[id];
      if (ctrl == null) return;
      final len = ctrl.text.length;
      ctrl.selection = TextSelection.collapsed(offset: len);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      focus.requestFocus();
      placeCaretAtEnd();
      // 桌面端获焦后常会再触发一次全选，补一帧把光标放回末尾。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !focus.hasFocus) return;
        placeCaretAtEnd();
      });
    });
  }

  bool _isWideField(ComfyExposedField field) =>
      field.widget.isMedia || field.widget == ComfyWidgetKind.multiline;

  Widget _buildFieldsLayout(ComfyExposedNode node) {
    final wide = <ComfyExposedField>[];
    final narrow = <ComfyExposedField>[];
    for (final field in node.fields) {
      if (_isWideField(field)) {
        wide.add(field);
      } else {
        narrow.add(field);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in wide) _buildFieldBody(field),
        for (var i = 0; i < narrow.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildFieldBody(narrow[i])),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < narrow.length
                      ? _buildFieldBody(narrow[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFieldBody(ComfyExposedField field) {
    switch (field.widget) {
      case ComfyWidgetKind.bool:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(field.label, style: const TextStyle(fontSize: 13)),
          value: _values[field.id] == true,
          onChanged: (v) => _setFieldValue(field.id, v),
        );
      case ComfyWidgetKind.image:
      case ComfyWidgetKind.audio:
      case ComfyWidgetKind.video:
        final path = _values[field.id]?.toString() ?? '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(field.label, style: const TextStyle(fontSize: 12)),
              Row(
                children: [
                  Expanded(
                    child: path.isEmpty
                        ? Text(
                            '未选择',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          )
                        : PathEllipsisText(
                            path,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _useSelectedFile(field),
                    child: const Text('用当前选中'),
                  ),
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
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
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _textCtrls[field.id],
            focusNode: _textFocus[field.id],
            maxLines: 4,
            onChanged: (_) => _schedulePersistSession(),
            decoration: InputDecoration(
              isDense: true,
              labelText: field.label,
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        );
      case ComfyWidgetKind.int:
      case ComfyWidgetKind.float:
      case ComfyWidgetKind.text:
      case ComfyWidgetKind.choice:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _textCtrls[field.id],
            focusNode: _textFocus[field.id],
            onChanged: (_) => _schedulePersistSession(),
            keyboardType: field.widget == ComfyWidgetKind.int ||
                    field.widget == ComfyWidgetKind.float
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.text,
            decoration: InputDecoration(
              isDense: true,
              labelText: field.label,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
            ),
          ),
        );
    }
  }
}
