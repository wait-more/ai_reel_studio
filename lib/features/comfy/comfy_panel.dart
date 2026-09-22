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
import '../../core/comfy_prompt_bridge.dart';
import '../../core/config.dart';
import '../../core/file_actions.dart';
import '../../core/fs_drag.dart';
import '../../core/path_ellipsis_text.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import '../../core/ui_palette.dart';
import '../media/media_hover_preview.dart';
import 'comfy_template_library.dart';

String _formatJobElapsed(Duration elapsed) {
  final s = elapsed.inSeconds;
  final m = s ~/ 60;
  final r = s % 60;
  if (m <= 0) return '${r}s';
  return '${m}m ${r.toString().padLeft(2, '0')}s';
}

/// Comfy 面板左右顶栏统一高度（标题行 + 副文案/操作）。
const double _kComfyHeaderBarHeight = 48;

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
  /// 结束后固化的用时；进行中由 [displayElapsed] 按 [createdAt] 实时计算。
  Duration elapsed = Duration.zero;
  String? error;
  List<String> outputs = const [];

  bool get isActive =>
      phase != _ComfyJobPhase.completed &&
      phase != _ComfyJobPhase.cancelled &&
      phase != _ComfyJobPhase.failed;

  bool get isTerminal => !isActive;

  Duration get displayElapsed =>
      isActive ? DateTime.now().difference(createdAt) : elapsed;

  String get elapsedLabel => _formatJobElapsed(displayElapsed);

  void freezeElapsed() {
    elapsed = DateTime.now().difference(createdAt);
  }
}

enum _ServerLinkState { unknown, checking, online, offline }

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
  /// 分类分区顺序（sortCategory 整型）。空则含提示词的分区在前，其余仍按 0→4。
  List<int> _categoryOrder = [];
  /// 节点瓦片长按拖拽排序：当前拖起的分区与源下标。
  int? _nodeDragCategory;
  int? _nodeDragFromIndex;
  /// 插入点：放到该下标之前（0=最前，nodes.length=最后）。
  int? _nodeInsertBefore;

  String? _outputDir;
  final TextEditingController _outputNameCtrl = TextEditingController();
  /// 各实例连接状态（未探测过为 unknown）。
  final Map<String, _ServerLinkState> _serverLink = {};
  bool _pingingAll = false;
  String? _formError;
  final List<_ComfyJob> _jobs = [];
  static const _kMaxJobs = 30;
  final ScrollController _jobListScroll = ScrollController();
  /// 点开后才展开输出文件的任务。
  final Set<String> _openJobIds = {};
  /// 任务区高度（拖分割线直接改高度；内容少时仍可自动收缩到内容高）。
  double _jobPaneHeight = 180;
  bool _jobPanePinned = false;
  final GlobalKey _jobPaneKey = GlobalKey();

  Timer? _hotReloadTimer;
  Timer? _serverPingTimer;
  Timer? _jobTickTimer;
  Timer? _sessionPersistTimer;
  Timer? _leftSplitPersistTimer;
  Timer? _leftRailPersistTimer;
  String _lastSig = '';
  double _leftSplit = AppConfig.instance.comfyLeftSplit;
  double _leftRailWidth = AppConfig.instance.comfyLeftRailWidth;
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
    _serverPingTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(_pingAllServers());
    });
    // 进行中任务的「用时」本地每秒刷新，不依赖远端节点状态回调。
    _jobTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_jobs.any((j) => j.isActive)) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_pingAllServers(showChecking: true));
    });
  }

  @override
  void dispose() {
    _hotReloadTimer?.cancel();
    _serverPingTimer?.cancel();
    _jobTickTimer?.cancel();
    _sessionPersistTimer?.cancel();
    _leftSplitPersistTimer?.cancel();
    _leftRailPersistTimer?.cancel();
    if (_leftSplit != AppConfig.instance.comfyLeftSplit) {
      unawaited(AppConfig.instance.setComfyLeftSplit(_leftSplit));
    }
    if (_leftRailWidth != AppConfig.instance.comfyLeftRailWidth) {
      unawaited(AppConfig.instance.setComfyLeftRailWidth(_leftRailWidth));
    }
    _jobListScroll.dispose();
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

  String _serverDisplayName(String serverId) {
    for (final s in ref.read(comfyServersProvider)) {
      if (s.id == serverId) {
        final name = s.name.trim();
        return name.isNotEmpty ? name : s.baseUrl;
      }
    }
    return serverId;
  }

  /// 任务按 Comfy URL（serverId）隔离；其它 URL 上的任务仍在后台跑，切回去还能看到。
  List<_ComfyJob> _jobsForServer(String serverId) =>
      _jobs.where((j) => j.serverId == serverId).toList(growable: false);

  /// 该 URL 上最老的进行中任务（按 [createdAt] 升序）。
  _ComfyJob? _oldestActiveJob(String serverId) {
    final active = _jobsForServer(serverId).where((j) => j.isActive).toList();
    if (active.isEmpty) return null;
    active.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return active.first;
  }

  _ServerLinkState _linkOf(String serverId) =>
      _serverLink[serverId] ?? _ServerLinkState.unknown;

  Future<void> _checkConnection() => _pingAllServers(showChecking: true);

  Future<void> _pingAllServers({bool showChecking = false}) async {
    final gen = ++_connGen;
    final servers = List<ComfyServer>.of(ref.read(comfyEnabledServersProvider));
    if (servers.isEmpty) {
      if (mounted) {
        setState(() {
          _serverLink.clear();
          _pingingAll = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _pingingAll = showChecking;
        if (showChecking) {
          for (final s in servers) {
            _serverLink[s.id] = _ServerLinkState.checking;
          }
        } else {
          for (final s in servers) {
            if (!_serverLink.containsKey(s.id)) {
              _serverLink[s.id] = _ServerLinkState.checking;
            }
          }
        }
      });
    }
    await Future.wait(servers.map(_pingOneServer));
    if (!mounted || gen != _connGen) return;
    setState(() => _pingingAll = false);
  }

  Future<void> _pingOneServer(ComfyServer server) async {
    final client = ComfyClient(baseUrl: server.baseUrl, apiKey: server.apiKey);
    try {
      final ok = await client.ping();
      if (!mounted) return;
      setState(() {
        _serverLink[server.id] =
            ok ? _ServerLinkState.online : _ServerLinkState.offline;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _serverLink[server.id] = _ServerLinkState.offline);
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
    _outputDir = null;
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
      final rememberedOutputDir = session.outputDir.trim();
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
        _outputDir =
            rememberedOutputDir.isEmpty ? null : rememberedOutputDir;
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

  void _schedulePersistLeftSplit() {
    _leftSplitPersistTimer?.cancel();
    _leftSplitPersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(AppConfig.instance.setComfyLeftSplit(_leftSplit));
    });
  }

  void _schedulePersistLeftRail() {
    _leftRailPersistTimer?.cancel();
    _leftRailPersistTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(AppConfig.instance.setComfyLeftRailWidth(_leftRailWidth));
    });
  }

  Future<void> _openExpandedTextEditor(
    ComfyExposedField field, {
    required String nodeTitle,
  }) async {
    final ctrl = _textCtrls[field.id];
    if (ctrl == null) return;
    _textFocus[field.id]?.unfocus();

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final size = MediaQuery.sizeOf(ctx);
        final width = (size.width * 0.72).clamp(420.0, 820.0);
        final height = (size.height * 0.58).clamp(280.0, 560.0);
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: SizedBox(
            width: width,
            height: height,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          nodeTitle,
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: ctrl,
                      autofocus: true,
                      maxLines: null,
                      expands: true,
                      textAlignVertical: TextAlignVertical.top,
                      onChanged: (_) => _schedulePersistSession(),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    _syncTextValuesFromControllers();
    _schedulePersistSession();
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
      outputDir: _outputDir?.trim() ?? '',
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
    final defaultOrder = _defaultCategoryOrder(buckets, present);
    final orderedCats = <int>[];
    for (final cat in _categoryOrder) {
      if (present.contains(cat) && !orderedCats.contains(cat)) {
        orderedCats.add(cat);
      }
    }
    for (final cat in defaultOrder) {
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

  /// 还没拖过分区时：带多行提示词的分组在前，组内仍保持图片→其它的相对顺序。
  List<int> _defaultCategoryOrder(
    Map<int, List<ComfyExposedNode>> buckets,
    List<int> present,
  ) {
    final withPrompt = <int>[];
    final rest = <int>[];
    for (final cat in present) {
      final nodes = buckets[cat] ?? const <ComfyExposedNode>[];
      var hasPrompt = false;
      for (final node in nodes) {
        if (node.fields.any((f) => f.widget == ComfyWidgetKind.multiline)) {
          hasPrompt = true;
          break;
        }
      }
      if (hasPrompt) {
        withPrompt.add(cat);
      } else {
        rest.add(cat);
      }
    }
    return [...withPrompt, ...rest];
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

  void _clearNodeReorderDrag() {
    if (_nodeDragCategory == null &&
        _nodeDragFromIndex == null &&
        _nodeInsertBefore == null) {
      return;
    }
    setState(() {
      _nodeDragCategory = null;
      _nodeDragFromIndex = null;
      _nodeInsertBefore = null;
    });
  }

  void _clearNodeInsertHint() {
    if (_nodeInsertBefore == null) return;
    setState(() => _nodeInsertBefore = null);
  }

  /// 仅更新同组插入点；[_nodeDragCategory] 在起拖时锁定为源分区，不被其它组 onMove 改写。
  void _setNodeInsertBefore(int category, int fromIndex, int insertBefore) {
    if (_nodeDragCategory != category || _nodeDragFromIndex != fromIndex) {
      return;
    }
    if (_nodeInsertBefore == insertBefore) return;
    setState(() => _nodeInsertBefore = insertBefore);
  }

  /// [insertBefore]：插入到该下标之前（含 0 与 length）。
  void _moveNodeInCategory(int category, int fromIndex, int insertBefore) {
    if (fromIndex == insertBefore || fromIndex + 1 == insertBefore) return;
    final sections = _nodeSections();
    final idx = sections.indexWhere((s) => s.category == category);
    if (idx < 0) return;
    final nodes = List<ComfyExposedNode>.of(sections[idx].nodes);
    if (fromIndex < 0 ||
        fromIndex >= nodes.length ||
        insertBefore < 0 ||
        insertBefore > nodes.length) {
      return;
    }
    final item = nodes.removeAt(fromIndex);
    var to = insertBefore;
    if (fromIndex < insertBefore) to -= 1;
    to = to.clamp(0, nodes.length);
    nodes.insert(to, item);
    final rebuilt = <String>[];
    for (final s in sections) {
      if (s.category == category) {
        rebuilt.addAll(nodes.map((e) => e.nodeId));
      } else {
        rebuilt.addAll(s.nodes.map((e) => e.nodeId));
      }
    }
    setState(() {
      _nodeOrder = rebuilt;
      _nodeDragCategory = null;
      _nodeDragFromIndex = null;
      _nodeInsertBefore = null;
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

  Future<void> _applyPromptInject(ComfyPromptInjectRequest req) async {
    // 消费掉，避免重复触发。
    ref.read(comfyPromptInjectRequestProvider.notifier).state = null;

    await _selectServer(req.serverId);
    if (!mounted) return;

    ComfyTemplate? template;
    final bundle = ref.read(comfyBundleProvider).valueOrNull;
    if (bundle != null) {
      for (final t in bundle.templates) {
        if (t.id == req.templateId) {
          template = t;
          break;
        }
      }
    }
    if (template == null) {
      for (final t in await ComfyTemplateStore.loadTemplates()) {
        if (t.id == req.templateId) {
          template = t;
          break;
        }
      }
    }
    if (template == null || !mounted) {
      if (mounted) showGlobalToast(context, '找不到目标模板');
      return;
    }

    await _selectTemplate(template, persistCurrent: false);
    if (!mounted) return;

    setState(() {
      _values[req.fieldId] = req.text;
      _enabled[req.nodeId] = true;
      _expanded[req.nodeId] = true;
      final ctrl = _textCtrls[req.fieldId];
      if (ctrl != null && ctrl.text != req.text) {
        ctrl.text = req.text;
        ctrl.selection = TextSelection.collapsed(offset: req.text.length);
      }
    });
    _schedulePersistSession();

    final focus = _textFocus[req.fieldId];
    if (focus != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        focus.requestFocus();
        final ctrl = _textCtrls[req.fieldId];
        if (ctrl != null) {
          ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !focus.hasFocus) return;
          final c = _textCtrls[req.fieldId];
          if (c == null) return;
          c.selection = TextSelection.collapsed(offset: c.text.length);
        });
      });
    }
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

  /// 当前文件所在目录中、符合该字段类型的文件（按文件名排序）。
  List<String> _siblingMediaPaths(ComfyExposedField field, String currentPath) {
    final trimmed = currentPath.trim();
    if (trimmed.isEmpty) return const [];
    final dirPath = p.dirname(trimmed);
    if (dirPath.isEmpty || dirPath == '.') return const [];
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final out = <String>[];
    try {
      for (final ent in dir.listSync(followLinks: false)) {
        if (ent is! File) continue;
        if (!_mediaMatches(field.widget, ent.path)) continue;
        out.add(ent.path);
      }
    } catch (_) {
      return const [];
    }
    out.sort(
      (a, b) => p
          .basename(a)
          .toLowerCase()
          .compareTo(p.basename(b).toLowerCase()),
    );
    return out;
  }

  bool _nodeCanAcceptMediaDrop(ComfyExposedNode node, FsDragItem item) {
    for (final e in item.items) {
      if (e.isDir) continue;
      for (final field in node.fields) {
        if (field.widget.isMedia && _mediaMatches(field.widget, e.path)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _fieldCanAcceptMediaDrop(ComfyExposedField field, FsDragItem item) {
    if (!field.widget.isMedia) return false;
    for (final e in item.items) {
      if (!e.isDir && _mediaMatches(field.widget, e.path)) return true;
    }
    return false;
  }

  void _applyMediaDropToNode(ComfyExposedNode node, FsDragItem item) {
    final paths = [for (final e in item.items) if (!e.isDir) e.path];
    if (paths.isEmpty) {
      showGlobalToast(context, '请拖入文件（不能是文件夹）');
      return;
    }
    final mediaFields = [
      for (final f in node.fields)
        if (f.widget.isMedia) f,
    ];
    if (mediaFields.isEmpty) {
      showGlobalToast(context, '该节点没有媒体输入');
      return;
    }

    final assignments = <String, String>{};
    final used = <int>{};
    for (final field in mediaFields) {
      for (var i = 0; i < paths.length; i++) {
        if (used.contains(i)) continue;
        if (!_mediaMatches(field.widget, paths[i])) continue;
        assignments[field.id] = paths[i];
        used.add(i);
        break;
      }
    }
    if (assignments.isEmpty) {
      showGlobalToast(context, '文件类型与节点不匹配');
      return;
    }
    setState(() {
      _values.addAll(assignments);
      if (node.bypassWhenDisabled) {
        _enabled[node.nodeId] = true;
      }
    });
    _schedulePersistSession();
    showGlobalToast(
      context,
      assignments.length == 1
          ? '已填入 ${p.basename(assignments.values.first)}'
          : '已填入 ${assignments.length} 个路径',
    );
  }

  void _applyMediaDropToField(
    ComfyExposedNode node,
    ComfyExposedField field,
    FsDragItem item,
  ) {
    for (final e in item.items) {
      if (e.isDir) continue;
      if (!_mediaMatches(field.widget, e.path)) continue;
      setState(() {
        _values[field.id] = e.path;
        if (node.bypassWhenDisabled) {
          _enabled[node.nodeId] = true;
        }
      });
      _schedulePersistSession();
      showGlobalToast(context, '已填入 ${p.basename(e.path)}');
      return;
    }
    showGlobalToast(context, '文件类型与字段不匹配');
  }

  void _applyOutputDirDrop(FsDragItem item) {
    final primary = item.items.first;
    final dir = primary.isDir ? primary.path : p.dirname(primary.path);
    if (dir.isEmpty || dir == '.') {
      showGlobalToast(context, '无法解析输出目录');
      return;
    }
    setState(() => _outputDir = dir);
    _schedulePersistSession();
    showGlobalToast(
      context,
      primary.isDir ? '已设为输出目录' : '已用文件所在目录作为输出目录',
    );
  }

  String _mediaDropRejectHint(FsDragItem item) {
    if (item.items.every((e) => e.isDir)) {
      return '请拖入文件，文件夹无法填入';
    }
    return '文件类型不匹配，无法填入';
  }

  Widget _wrapFsDropTarget({
    required bool Function(FsDragItem item) canAccept,
    required void Function(FsDragItem item) onAccept,
    required Widget Function(BuildContext context, bool hot, bool blocked)
        builder,
    BorderRadius? radius,
    String dropHint = '释放以填入路径',
    String Function(FsDragItem item)? rejectHintFor,
  }) {
    return _ComfyFsDropTarget(
      canAccept: canAccept,
      onAccept: onAccept,
      dropHint: dropHint,
      rejectHintFor: rejectHintFor ?? _mediaDropRejectHint,
      radius: radius,
      builder: builder,
    );
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

  /// 将当前模板的节点参数与 bypass 使能复制到其它 Comfy 实例，便于并行同跑。
  /// 注意：种子会在各自点击「生成」提交时重新随机，不会沿用同一 seed 出同片。
  Future<void> _twinTaskToOtherServer(BuildContext anchorContext) async {
    final template = _selected;
    if (template == null) return;

    final currentId = _serverId;
    final others = ref
        .read(comfyEnabledServersProvider)
        .where((s) => s.id != currentId)
        .toList(growable: false);
    if (others.isEmpty) {
      if (mounted) {
        showGlobalToast(context, '没有其它已开启的 Comfy 实例');
      }
      return;
    }

    final bindings = await ComfyTemplateStore.loadBindings();
    if (!mounted || !anchorContext.mounted) return;
    final boundIdsByServer = <String, bool>{
      for (final s in others)
        s.id: bindings.forServer(s.id).templateIds.contains(template.id),
    };

    final target = await _showTwinTargetPicker(
      anchorContext: anchorContext,
      servers: others,
      boundIdsByServer: boundIdsByServer,
    );
    if (target == null || !mounted) return;

    final bound = boundIdsByServer[target.id] == true;
    if (!bound) {
      if (!anchorContext.mounted) return;
      final ok = await _showTwinBindConfirm(
        anchorContext: anchorContext,
        target: target,
        templateName: template.name,
      );
      if (ok != true || !mounted) return;
      await ComfyTemplateStore.bindTemplates(
        serverId: target.id,
        addTemplateIds: [template.id],
      );
      ref.read(comfyActionsTickProvider.notifier).state++;
    }

    await _persistSession();
    if (!mounted) return;

    _syncTextValuesFromControllers();
    final sourceName = _outputNameCtrl.text.trim();
    final targetSession = await ComfyGenSession.load(
      serverId: target.id,
      templateId: template.id,
    );

    final enabled = Map<String, bool>.from(targetSession.enabled);
    for (final node in template.nodes) {
      if (!node.bypassWhenDisabled) continue;
      enabled[node.nodeId] =
          _enabled[node.nodeId] ?? node.defaultEnabled;
    }

    final next = targetSession.copyWith(
      values: Map<String, dynamic>.from(_values),
      enabled: enabled,
      outputDir: (_outputDir?.trim().isNotEmpty == true)
          ? _outputDir!.trim()
          : targetSession.outputDir,
      outputFileName: sourceName.isEmpty
          ? targetSession.outputFileName
          : _withMinusOneSuffix(sourceName),
    );
    await ComfyGenSession.save(
      serverId: target.id,
      templateId: template.id,
      session: next,
    );
    await ComfyTemplateStore.selectTemplate(
      serverId: target.id,
      templateId: template.id,
    );
    ref.read(comfyActionsTickProvider.notifier).state++;

    if (!mounted) return;
    showGlobalToast(context, '已孪生到「${target.name}」');
    await _selectServer(target.id);
    if (!mounted) return;
    // 切到目标 URL 后明确打开刚孪生的模板（载入目标会话中的值/使能）。
    await _selectTemplate(template, persistCurrent: false);
  }

  Future<ComfyServer?> _showTwinTargetPicker({
    required BuildContext anchorContext,
    required List<ComfyServer> servers,
    required Map<String, bool> boundIdsByServer,
  }) {
    return _showAnchoredPopup<ComfyServer>(
      anchorContext: anchorContext,
      width: 268,
      builder: (ctx, cs) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(
                  Icons.control_point_duplicate_outlined,
                  size: 16,
                  color: cs.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '孪生到实例',
                    style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              '复制当前参数与使能，便于并行同跑',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              itemCount: servers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 4),
              itemBuilder: (ctx, i) {
                final s = servers[i];
                final bound = boundIdsByServer[s.id] == true;
                return Material(
                  color: cs.surfaceContainerLow.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => Navigator.of(ctx).pop(s),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 15,
                            color: cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  s.baseUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            bound ? '已绑定' : '将绑定',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              color: bound
                                  ? cs.primary
                                  : cs.tertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<bool?> _showTwinBindConfirm({
    required BuildContext anchorContext,
    required ComfyServer target,
    required String templateName,
  }) {
    return _showAnchoredPopup<bool>(
      anchorContext: anchorContext,
      width: 268,
      builder: (ctx, cs) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '尚未绑定模板',
              style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              '「${target.name}」未绑定「$templateName」。绑定后将复制当前参数。',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('取消'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('绑定并孪生'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _showAnchoredPopup<T>({
    required BuildContext anchorContext,
    required double width,
    required Widget Function(BuildContext context, ColorScheme cs) builder,
    double estimatedHeight = 220,
  }) {
    final box = anchorContext.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(anchorContext).context.findRenderObject()
        as RenderBox?;
    if (box == null || overlay == null || !box.hasSize) {
      return Future<T?>.value(null);
    }

    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    final size = box.size;
    final overlaySize = overlay.size;
    const gap = 6.0;
    const margin = 8.0;
    final estH = estimatedHeight.clamp(120.0, overlaySize.height - margin * 2);

    var left = topLeft.dx + size.width - width;
    if (left < margin) left = margin;
    if (left + width > overlaySize.width - margin) {
      left = overlaySize.width - width - margin;
    }

    var top = topLeft.dy + size.height + gap;
    if (top + estH > overlaySize.height - margin) {
      top = topLeft.dy - estH - gap;
      if (top < margin) top = margin;
    }

    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return SizedBox.expand(
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                width: width,
                child: Material(
                  color: cs.surfaceContainerHigh,
                  elevation: 10,
                  shadowColor: Colors.black.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(12),
                  clipBehavior: Clip.antiAlias,
                  child: builder(ctx, cs),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// `foo` → `foo-1`；`foo.png` → `foo-1.png`；
  /// 基名已是 `*-N`（N 为正整数）则改为 `*-(N+1)`。
  /// 注意：`scene.1.2-3` 整段是基名，不会把 `.2-3` 当成扩展名。
  static String _withMinusOneSuffix(String fileName) {
    final trimmed = fileName.trim();
    if (trimmed.isEmpty) return trimmed;
    final base = ComfyClient.splitUserOutputBase(trimmed);
    final ext = base.length < trimmed.length
        ? trimmed.substring(base.length)
        : '';

    final m = RegExp(r'^(.*)-(\d+)$').firstMatch(base);
    if (m != null) {
      final stem = m.group(1)!;
      final n = int.tryParse(m.group(2)!) ?? 0;
      return '$stem-${n + 1}$ext';
    }
    return '$base-1$ext';
  }

  /// 从目录树当前选中解析目录：选中文件夹则用其本身，选中文件则用其所在目录。
  String? _dirFromTreeSelection() {
    final multi = ref.read(treeSelectionProvider);
    if (multi.length == 1) {
      final it = multi.first;
      if (it.isDir) {
        return it.path.isEmpty ? null : it.path;
      }
      final parent = p.dirname(it.path);
      if (parent.isEmpty || parent == '.') return null;
      return parent;
    }
    final file = ref.read(selectedFileProvider);
    if (file != null && file.isNotEmpty) {
      final parent = p.dirname(file);
      if (parent.isNotEmpty && parent != '.') return parent;
    }
    final dir = ref.read(selectedDirProvider);
    if (dir != null && dir.isNotEmpty) return dir;
    return null;
  }

  /// 从目录树解析单个文件路径；若当前明确选中的是文件夹则返回 [null] 且 [folderSelected] 为 true。
  ({String? path, bool folderSelected}) _fileFromTreeSelection() {
    final multi = ref.read(treeSelectionProvider);
    if (multi.length == 1) {
      final it = multi.first;
      if (it.isDir) return (path: null, folderSelected: true);
      return (path: it.path, folderSelected: false);
    }
    final file = ref.read(selectedFileProvider);
    if (file != null && file.isNotEmpty) {
      return (path: file, folderSelected: false);
    }
    final dir = ref.read(selectedDirProvider);
    if (dir != null && dir.isNotEmpty) {
      return (path: null, folderSelected: true);
    }
    return (path: null, folderSelected: false);
  }

  /// 仅作「浏览」对话框的起始位置，不会自动写入输出目录。
  String? _pickerInitialDir() {
    final explicit = _outputDir?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final fromTree = _dirFromTreeSelection();
    if (fromTree != null && fromTree.isNotEmpty) return fromTree;
    final root = AppConfig.instance.projectRoot.trim();
    return root.isEmpty ? null : root;
  }

  Future<void> _pickOutputDir() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: '选择生成输出目录',
      initialDirectory: _pickerInitialDir(),
    );
    if (path == null) return;
    setState(() => _outputDir = path);
    _schedulePersistSession();
  }

  void _useSelectedAsOutputDir() {
    final base = _dirFromTreeSelection();
    if (base == null || base.isEmpty) {
      unawaited(_promptTreeSelection(
        title: '未选中目录',
        reason: '请先在目录树中选中文件夹或文件。',
        ctrlHint: '可使用 Ctrl+单击 选中文件（不会打开）；选中文件时将使用其所在目录。',
      ));
      return;
    }
    setState(() => _outputDir = base);
    _schedulePersistSession();
    _releaseTreeCtrlMemoryAfterUse();
    showGlobalToast(context, '已设为输出目录');
  }

  Future<void> _promptTreeSelection({
    required String title,
    required String reason,
    required String ctrlHint,
  }) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        return AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 320,
            child: Text(
              '$reason\n\n$ctrlHint',
              style: TextStyle(
                fontSize: 13,
                height: 1.45,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _promptSelectFile({
    required String reason,
    String ctrlHint =
        '请使用 Ctrl+单击 在目录树中选中文件后再试（不会打开文件）。',
  }) {
    return _promptTreeSelection(
      title: '无法使用当前选中',
      reason: reason,
      ctrlHint: ctrlHint,
    );
  }

  void _useSelectedFile(ComfyExposedField field) {
    final picked = _fileFromTreeSelection();
    if (picked.folderSelected) {
      unawaited(_promptSelectFile(reason: '目录树当前选中的是文件夹。'));
      return;
    }
    final f = picked.path;
    if (f == null || f.isEmpty) {
      unawaited(_promptSelectFile(reason: '目录树尚未选中文件。'));
      return;
    }
    if (!_mediaMatches(field.widget, f)) {
      unawaited(_promptSelectFile(
        reason: '选中文件类型与当前节点不匹配。',
        ctrlHint: '请使用 Ctrl+单击 在目录树中选中匹配类型的文件后再试（不会打开文件）。',
      ));
      return;
    }
    _setFieldValue(field.id, f);
    _releaseTreeCtrlMemoryAfterUse();
  }

  /// 「用当前选中 / 当前选中」消费后：只清 Ctrl 多选会话记忆，保留树高亮。
  /// 下次 Ctrl+单击会当作新一轮起点（丢弃旧集合、只留当前项），避免高亮瞬间消失乱跳。
  void _releaseTreeCtrlMemoryAfterUse() {
    if (!ref.read(treeSelectionByCtrlProvider)) return;
    ref.read(treeSelectionByCtrlProvider.notifier).state = false;
  }

  String _resolveOutputDir() {
    final explicit = _outputDir?.trim() ?? '';
    if (explicit.isEmpty) {
      throw StateError('请先选择输出目录（「当前选中」或「浏览」）');
    }
    return explicit;
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
    final jobId = job.id;
    final promptId = job.promptId;
    final baseUrl = job.baseUrl;
    _mutateJob(jobId, (j) {
      j.cancelling = true;
      j.detail = '正在取消…';
    });
    // 只取消本任务 token；轮询里会按 prompt 决定是否 interrupt。
    job.cancelToken.cancel();
    if (promptId == null || promptId.isEmpty) return;
    final client = ComfyClient(
      baseUrl: baseUrl,
      apiKey: ref.read(comfyApiKeyProvider),
    );
    try {
      try {
        final q = await client.getQueue();
        if (q.runningIds.contains(promptId)) {
          await client.interrupt();
        }
      } catch (_) {}
      try {
        await client.deleteFromQueue([promptId]);
      } catch (_) {}
    } finally {
      client.close();
    }
  }

  void _dismissJob(String jobId) {
    setState(() {
      _jobs.removeWhere((j) => j.id == jobId);
      _openJobIds.remove(jobId);
    });
  }

  void _clearFinishedJobs() {
    final id = _serverId;
    setState(() {
      _jobs.removeWhere((j) => j.serverId == id && j.isTerminal);
      _openJobIds.removeWhere(
        (jobId) => !_jobs.any((j) => j.id == jobId),
      );
    });
  }

  Future<void> _deleteJobOutput(_ComfyJob job, String path) async {
    final ok = await deleteEntityDialog(
      context,
      path: path,
      isDir: false,
      onDone: () => ref.read(treeRefreshTickProvider.notifier).state++,
    );
    if (!ok || !mounted) return;
    _mutateJob(job.id, (j) {
      j.outputs = j.outputs.where((e) => e != path).toList(growable: false);
    });
    showGlobalToast(context, '已删除：${p.basename(path)}');
  }

  Future<void> _deleteAllJobOutputs(_ComfyJob job) async {
    final paths = List<String>.from(job.outputs);
    if (paths.isEmpty) return;
    final ok = await deleteEntitiesDialog(
      context,
      items: [
        for (final path in paths) FsClipboardItem(path: path, isDir: false),
      ],
      onDone: () => ref.read(treeRefreshTickProvider.notifier).state++,
    );
    if (!ok || !mounted) return;
    final remain = <String>[];
    for (final path in paths) {
      if (await File(path).exists()) remain.add(path);
    }
    if (!mounted) return;
    _mutateJob(job.id, (j) => j.outputs = List.unmodifiable(remain));
    final removed = paths.length - remain.length;
    if (removed > 0) {
      showGlobalToast(context, '已删除 $removed 个生成文件');
    }
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
      final msg = e is StateError ? e.message : '$e';
      setState(() => _formError = msg);
      showGlobalToast(context, msg);
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
      _jobs.add(job);
      // 每个 URL 各自保留上限；超限时丢掉该 URL 最早的已结束任务。
      while (_jobs.where((j) => j.serverId == job.serverId).length > _kMaxJobs) {
        final idx = _jobs.indexWhere(
          (j) => j.serverId == job.serverId && j.isTerminal,
        );
        if (idx < 0) break;
        _jobs.removeAt(idx);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_jobListScroll.hasClients) return;
      _jobListScroll.animateTo(
        _jobListScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
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
      // 每次提交都换新种子，避免孪生/同参多 URL 得到完全相同的视频。
      final seeds = ComfyDiscover.randomizeSeedInputs(prompt);
      if (seeds.isNotEmpty) {
        final preview = seeds.entries
            .take(3)
            .map((e) => '${e.key}=${e.value}')
            .join(', ');
        _mutateJob(job.id, (j) {
          j.detail =
              '提交工作流… 种子 ${seeds.length} 处已随机${preview.isEmpty ? '' : '（$preview）'}';
        });
      }
      final history = await client.runPrompt(
        prompt,
        cancelToken: cancel,
        onPromptId: (id) {
          _mutateJob(job.id, (j) => j.promptId = id);
        },
        onStatus: (s) {
          _mutateJob(job.id, (j) {
            j.runStatus = s;
            j.detail = s.detail;
            j.phase = switch (s.phase) {
              ComfyRunPhase.queued => _ComfyJobPhase.queued,
              ComfyRunPhase.running => _ComfyJobPhase.running,
              ComfyRunPhase.completed => _ComfyJobPhase.running,
              ComfyRunPhase.waiting => _ComfyJobPhase.queued,
              ComfyRunPhase.cancelled => _ComfyJobPhase.cancelled,
            };
            if (j.isTerminal) j.freezeElapsed();
          });
        },
      );

      if (cancel.isCancelled) throw const ComfyCancelledException();
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.downloading;
        j.detail = '正在下载结果…';
      });
      final saved = await client.saveOutputsToDir(
        historyEntry: history,
        destDir: job.outputDir,
        preferredFileName: job.outputFileName,
      );
      ref.read(treeRefreshTickProvider.notifier).state++;

      var detail = '已保存 ${saved.length} 个文件';
      final promptId = job.promptId;
      if (ref.read(comfyDeleteRemoteAfterDownloadProvider) &&
          promptId != null &&
          promptId.isNotEmpty) {
        try {
          await client.deleteHistory([promptId]);
          detail = '$detail · 远端已清理';
        } catch (_) {
          detail = '$detail · 远端清理失败';
        }
      }

      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.completed;
        j.detail = detail;
        j.outputs = saved;
        j.freezeElapsed();
        j.runStatus = null;
        j.cancelling = false;
        // 完成后自动展开，方便直接看输出；进行中默认折叠。
        _openJobIds.add(j.id);
      });
      if (mounted) {
        showGlobalToast(
          context,
          '生成完成：${_serverDisplayName(job.serverId)} · ${job.templateName}',
        );
      }
    } on ComfyCancelledException {
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.cancelled;
        j.detail = '已取消';
        j.error = null;
        j.freezeElapsed();
        j.runStatus = null;
        j.cancelling = false;
      });
    } catch (e) {
      _mutateJob(job.id, (j) {
        j.phase = _ComfyJobPhase.failed;
        j.detail = '失败';
        j.error = '$e';
        j.freezeElapsed();
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
    if (!_mediaMatches(field.widget, path)) {
      if (mounted) showGlobalToast(context, '文件类型与字段不匹配');
      return;
    }
    _setFieldValue(field.id, path);
  }

  String _mediaKindLabel(ComfyWidgetKind kind) => switch (kind) {
        ComfyWidgetKind.image => '图片',
        ComfyWidgetKind.audio => '音频',
        ComfyWidgetKind.video => '视频',
        _ => '文件',
      };

  IconData _mediaKindIcon(ComfyWidgetKind kind) => switch (kind) {
        ComfyWidgetKind.image => Icons.image_outlined,
        ComfyWidgetKind.audio => Icons.audiotrack,
        ComfyWidgetKind.video => Icons.videocam_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  /// 锚定在操作按钮旁，列出同目录内符合类型的文件供切换。
  Future<void> _openSiblingMediaPicker({
    required BuildContext anchorContext,
    required ComfyExposedField field,
    required String currentPath,
  }) async {
    final siblings = _siblingMediaPaths(field, currentPath);
    final folderName = p.basename(p.dirname(currentPath));
    final folderPath = p.dirname(currentPath);
    final kindLabel = _mediaKindLabel(field.widget);
    final kindIcon = _mediaKindIcon(field.widget);
    final currentIndex = siblings.indexOf(currentPath);

    final picked = await _showAnchoredPopup<String>(
      anchorContext: anchorContext,
      width: 300,
      estimatedHeight: 320,
      builder: (ctx, cs) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: [
                  Icon(kindIcon, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '同目录$kindLabel',
                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  Text(
                    siblings.isEmpty ? '0' : '${siblings.length}',
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folderName.isEmpty ? folderPath : folderName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  PathEllipsisText(
                    folderPath,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (siblings.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
                child: Text(
                  '此目录没有其它可匹配的$kindLabel文件',
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  itemCount: siblings.length,
                  controller: currentIndex > 2
                      ? ScrollController(
                          initialScrollOffset:
                              ((currentIndex - 1) * 44.0).clamp(0, 9999),
                        )
                      : null,
                  separatorBuilder: (_, _) => const SizedBox(height: 4),
                  itemBuilder: (ctx, i) {
                    final file = siblings[i];
                    final selected = file == currentPath;
                    final name = p.basename(file);
                    final tint = UiPalette.forPath(file, isDir: false);
                    return _HoverChoiceTile(
                      selected: selected,
                      icon: kindIcon,
                      iconColor: tint,
                      title: name,
                      trailing: selected ? '当前' : null,
                      onTap: () => Navigator.of(ctx).pop(file),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
    if (picked == null || picked == currentPath || !mounted) return;
    _setFieldValue(field.id, picked);
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

  @override
  Widget build(BuildContext context) {
    final bundleAsync = ref.watch(comfyBundleProvider);
    final allServers = ref.watch(comfyServersProvider);
    final servers = ref.watch(comfyEnabledServersProvider);
    final selectedServerId = ref.watch(comfySelectedServerIdProvider);
    final cs = Theme.of(context).colorScheme;

    ref.listen(comfySelectedServerIdProvider, (prev, next) {
      if (prev == next) return;
      _checkConnection();
    });

    ref.listen(comfyServersProvider, (prev, next) {
      if (prev == null) return;
      if (prev.length == next.length &&
          prev.every((s) => next.any((n) =>
              n.id == s.id &&
              n.baseUrl == s.baseUrl &&
              n.enabled == s.enabled))) {
        return;
      }
      unawaited(_pingAllServers());
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

    ref.listen(comfyPromptInjectRequestProvider, (prev, next) {
      if (next == null) return;
      if (prev?.nonce == next.nonce) return;
      _applyPromptInject(next);
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
        return DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: cs.outlineVariant.withValues(alpha: 0.85),
              ),
            ),
          ),
          child: LayoutBuilder(
          builder: (context, outer) {
            const minRail = AppConfig.comfyLeftRailWidthMin;
            final room = (outer.maxWidth - 280)
                .clamp(minRail, AppConfig.comfyLeftRailWidthMax)
                .toDouble();
            final railW = _leftRailWidth.clamp(minRail, room).toDouble();
            return Row(
          children: [
            SizedBox(
              width: railW,
              child: Material(
                color: cs.surfaceContainerLow,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const dividerH = 6.0;
                    final avail =
                        (constraints.maxHeight - dividerH).clamp(0.0, double.infinity);
                    final topH = avail * _leftSplit;
                    final bottomH = avail - topH;
                    return Column(
                      children: [
                        SizedBox(
                          height: topH,
                          child: _buildServerList(
                            servers,
                            selectedServerId,
                            hasConfiguredServers: allServers.isNotEmpty,
                          ),
                        ),
                        _ComfyLeftSplitter(
                          onDragUpdate: (d) {
                            if (avail <= 0) return;
                            setState(() {
                              _leftSplit =
                                  (_leftSplit + d.delta.dy / avail).clamp(
                                AppConfig.comfyLeftSplitMin,
                                AppConfig.comfyLeftSplitMax,
                              );
                            });
                            _schedulePersistLeftSplit();
                          },
                        ),
                        SizedBox(
                          height: bottomH,
                          child: _buildTemplateList(
                            boundTemplates,
                            binding,
                            bundle.templates,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            _ComfyLeftRailSplitter(
              onReset: () {
                setState(() {
                  _leftRailWidth = AppConfig.defaultComfyLeftRailWidth
                      .clamp(minRail, room)
                      .toDouble();
                });
                _schedulePersistLeftRail();
              },
              onDragDelta: (dx) {
                setState(() {
                  _leftRailWidth =
                      (railW + dx).clamp(minRail, room).toDouble();
                });
                _schedulePersistLeftRail();
              },
            ),
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
        ),
        );
      },
    );
  }

  String _shortJobPhase(_ComfyJobPhase phase) => switch (phase) {
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

  String _serverTaskSummary(String serverId) {
    final activeCount =
        _jobsForServer(serverId).where((j) => j.isActive).length;
    if (activeCount == 0) return '空闲';
    final oldest = _oldestActiveJob(serverId)!;
    final phase = _shortJobPhase(oldest.phase);
    final queue = oldest.runStatus?.queuePosition;
    final queueBit =
        oldest.phase == _ComfyJobPhase.queued && queue != null ? ' #$queue' : '';
    final extra = activeCount > 1 ? ' · 另有 ${activeCount - 1} 个' : '';
    return '${oldest.templateName} · $phase$queueBit$extra';
  }

  /// 本机会话内该 URL 的任务计数。
  ({int total, int active, int completed, int failed, int cancelled})
      _serverJobCounts(String serverId) {
    final jobs = _jobsForServer(serverId);
    var active = 0, completed = 0, failed = 0, cancelled = 0;
    for (final j in jobs) {
      switch (j.phase) {
        case _ComfyJobPhase.completed:
          completed++;
        case _ComfyJobPhase.failed:
          failed++;
        case _ComfyJobPhase.cancelled:
          cancelled++;
        default:
          active++;
      }
    }
    return (
      total: jobs.length,
      active: active,
      completed: completed,
      failed: failed,
      cancelled: cancelled,
    );
  }

  String _serverJobCountLine(String serverId) {
    final c = _serverJobCounts(serverId);
    if (c.total == 0) return '任务 0';
    final bits = <String>[
      '共 ${c.total}',
      if (c.active > 0) '进行 ${c.active}',
      '完成 ${c.completed}',
      if (c.failed > 0) '失败 ${c.failed}',
      if (c.cancelled > 0) '取消 ${c.cancelled}',
    ];
    return bits.join(' · ');
  }

  Color _linkColor(_ServerLinkState link, ColorScheme cs) => switch (link) {
        _ServerLinkState.online => Colors.green,
        _ServerLinkState.offline => cs.error,
        _ServerLinkState.checking => cs.onSurfaceVariant,
        _ServerLinkState.unknown => cs.outline,
      };

  String _linkHint(_ServerLinkState link) => switch (link) {
        _ServerLinkState.online => '在线',
        _ServerLinkState.offline => '离线',
        _ServerLinkState.checking => '探测中',
        _ServerLinkState.unknown => '未探测',
      };

  Widget _buildServerList(
    List<ComfyServer> servers,
    String selectedId, {
    required bool hasConfiguredServers,
  }) {
    final cs = Theme.of(context).colorScheme;
    final onlineCount = servers
        .where((s) => _linkOf(s.id) == _ServerLinkState.online)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: _kComfyHeaderBarHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(color: cs.outlineVariant),
                bottom: BorderSide(color: cs.outlineVariant),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 4, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Comfy URL',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (servers.isNotEmpty)
                    Text(
                      '$onlineCount/${servers.length}',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  Tooltip(
                    message: '立刻再检测全部实例是否在线',
                    waitDuration: const Duration(milliseconds: 400),
                    child: TextButton(
                      onPressed: _pingingAll ? null : _checkConnection,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        enabledMouseCursor: SystemMouseCursors.click,
                        disabledMouseCursor: SystemMouseCursors.basic,
                      ),
                      child: Text(_pingingAll ? '检测中' : '检测'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: servers.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      hasConfiguredServers
                          ? '没有已开启的实例\n请在设置中启用'
                          : '请先在设置中添加实例',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: servers.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    thickness: 1,
                    indent: 10,
                    endIndent: 10,
                    color: cs.outlineVariant.withValues(alpha: 0.7),
                  ),
                  itemBuilder: (context, i) {
                    final s = servers[i];
                    final selected = s.id == selectedId;
                    final link = _linkOf(s.id);
                    final linkColor = _linkColor(link, cs);
                    final oldest = _oldestActiveJob(s.id);
                    final progress = oldest?.runStatus?.progressFraction;
                    final tip = [
                      s.name,
                      s.baseUrl,
                      _linkHint(link),
                      _serverJobCountLine(s.id),
                      _serverTaskSummary(s.id),
                    ].join('\n');
                    return Tooltip(
                      message: tip,
                      waitDuration: const Duration(milliseconds: 400),
                      child: Material(
                        color: selected
                            ? cs.surfaceContainerHighest.withValues(alpha: 0.65)
                            : Colors.transparent,
                        child: InkWell(
                          mouseCursor: SystemMouseCursors.click,
                          onTap: () => _selectServer(s.id),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: link == _ServerLinkState.online
                                            ? linkColor
                                            : Colors.transparent,
                                        border: Border.all(
                                          color: linkColor,
                                          width: 1.5,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        s.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: selected
                                              ? FontWeight.w600
                                              : FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  s.baseUrl,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                if (_serverJobCounts(s.id).total > 0) ...[
                                  const SizedBox(height: 3),
                                  Text(
                                    _serverJobCountLine(s.id),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    _serverTaskSummary(s.id),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: oldest != null
                                          ? cs.primary
                                          : cs.onSurfaceVariant,
                                    ),
                                  ),
                                  if (oldest != null) ...[
                                    const SizedBox(height: 4),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        value: progress,
                                        minHeight: 3,
                                      ),
                                    ),
                                  ],
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
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
        SizedBox(
          height: _kComfyHeaderBarHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(color: cs.outlineVariant),
                bottom: BorderSide(color: cs.outlineVariant),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 2, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '已绑模板',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '绑定模板',
                    icon: const Icon(Icons.link, size: 18),
                    visualDensity: VisualDensity.compact,
                    mouseCursor: SystemMouseCursors.click,
                    onPressed: () => _bindMore(all, binding),
                  ),
                  IconButton(
                    tooltip: '模板库',
                    icon: const Icon(Icons.library_books_outlined, size: 18),
                    visualDensity: VisualDensity.compact,
                    mouseCursor: SystemMouseCursors.click,
                    onPressed: () => showComfyTemplateLibrary(context, ref),
                  ),
                ],
              ),
            ),
          ),
        ),
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
              : ListView.separated(
                  itemCount: bound.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    thickness: 1,
                    indent: 10,
                    endIndent: 10,
                    color: cs.outlineVariant.withValues(alpha: 0.7),
                  ),
                  itemBuilder: (context, i) {
                    final t = bound[i];
                    final active = _selected?.id == t.id;
                    return _ComfyBoundTemplateRow(
                      name: t.name,
                      selected: active,
                      onTap: () => _selectTemplate(t),
                      onUnbind: () => _unbind(t),
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
        SizedBox(
          height: _kComfyHeaderBarHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                top: BorderSide(color: cs.outlineVariant),
                bottom: BorderSide(color: cs.outlineVariant),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          t.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.workflowFile,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                    fontSize: 11,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (btnCtx) => Tooltip(
                      message: '将当前节点参数与使能复制到其它 Comfy 实例，便于并行同跑',
                      waitDuration: const Duration(milliseconds: 400),
                      child: TextButton.icon(
                        onPressed: () => _twinTaskToOtherServer(btnCtx),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                        ),
                        icon: const Icon(
                          Icons.control_point_duplicate_outlined,
                          size: 18,
                        ),
                        label: const Text('任务孪生'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        _workflow == null || t.nodes.isEmpty ? null : _run,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 32),
                    ),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(
                      serverJobs.any((j) => j.isActive) ? '继续生成' : '生成',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildRunOutputZone(cs),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    Widget nodes() => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildZoneDivider(
                              cs,
                              icon: Icons.tune,
                              title: '节点参数',
                              subtitle: '点选编辑 · 长按拖到竖线处插入 · 拖分区标题调顺序',
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
                        );
                    if (serverJobs.isEmpty) {
                      _jobPanePinned = false;
                      return nodes();
                    }
                    const splitterH = 14.0;
                    const nodeHeaderH = 44.0;
                    const nodeMin = 120.0;
                    const jobMin = 88.0;
                    final room = constraints.maxHeight -
                        splitterH -
                        nodeHeaderH -
                        nodeMin;
                    final jobCap = room < jobMin ? jobMin : room;
                    final jobH = _jobPaneHeight.clamp(jobMin, jobCap);
                    // 未拖过：按内容增高，上限用满可用空间；拖过后锁定高度跟手。
                    final softMax = _jobPanePinned ? jobH : jobCap;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_jobPanePinned)
                          SizedBox(
                            key: _jobPaneKey,
                            height: jobH,
                            child: Container(
                              width: double.infinity,
                              color: cs.surface,
                              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                              child: _buildJobList(cs, serverJobs),
                            ),
                          )
                        else
                          ConstrainedBox(
                            key: _jobPaneKey,
                            constraints: BoxConstraints(maxHeight: softMax),
                            child: Container(
                              width: double.infinity,
                              color: cs.surface,
                              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                              child: _buildJobList(cs, serverJobs),
                            ),
                          ),
                        _ComfyJobSplitter(
                          onReset: () => setState(() => _jobPanePinned = false),
                          onDragStart: () {
                            final box = _jobPaneKey.currentContext
                                ?.findRenderObject() as RenderBox?;
                            final measured = box?.size.height;
                            setState(() {
                              _jobPanePinned = true;
                              if (measured != null && measured > 0) {
                                _jobPaneHeight = measured;
                              }
                            });
                          },
                          onDragDelta: (dy) {
                            setState(() {
                              _jobPanePinned = true;
                              _jobPaneHeight =
                                  (_jobPaneHeight + dy).clamp(jobMin, jobCap);
                            });
                          },
                        ),
                        Expanded(child: nodes()),
                      ],
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

  /// 运行输出功能区：目录 / 文件名 / 远端清理（任务列表单独占 Flexible 区域）。
  Widget _buildRunOutputZone(ColorScheme cs) {
    final explicit = _outputDir?.trim() ?? '';
    final dirText = explicit.isNotEmpty ? explicit : '未选择';
    final deleteRemote = ref.watch(comfyDeleteRemoteAfterDownloadProvider);

    return Container(
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(flex: 3, child: _buildOutputDirField(cs, dirText)),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _outputNameCtrl,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: '保存文件名',
                    hintText: '留空用原名',
                    prefixIcon: Icon(Icons.insert_drive_file_outlined, size: 18),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onChanged: (_) => _schedulePersistSession(),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: deleteRemote
                    ? '下载后删除远端输出：开。本地保存成功后清除 Comfy history/output'
                    : '下载后删除远端输出：关',
                waitDuration: const Duration(milliseconds: 400),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final next = !deleteRemote;
                    ref
                        .read(comfyDeleteRemoteAfterDownloadProvider.notifier)
                        .state = next;
                    await AppConfig.instance
                        .setComfyDeleteRemoteAfterDownload(next);
                  },
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 40),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    foregroundColor:
                        deleteRemote ? cs.primary : cs.onSurfaceVariant,
                    side: BorderSide(
                      color: deleteRemote ? cs.primary : cs.outline,
                    ),
                    enabledMouseCursor: SystemMouseCursors.click,
                  ),
                  icon: Icon(
                    deleteRemote
                        ? Icons.cloud_off_outlined
                        : Icons.cloud_outlined,
                    size: 16,
                  ),
                  label: Text(
                    deleteRemote ? '删远端' : '留远端',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
          if (_formError != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              _formError!,
              style: TextStyle(color: cs.error, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOutputDirField(ColorScheme cs, String dirText) {
    return DragTarget<FsDragItem>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (d) => _applyOutputDirDrop(d.data),
      builder: (context, candidate, rejected) {
        final hot = candidate.isNotEmpty;
        final borderColor = hot ? cs.primary : cs.outline;
        final borderWidth = hot ? 2.0 : 1.0;
        return InputDecorator(
          decoration: InputDecoration(
            isDense: true,
            labelText: '输出目录',
            prefixIcon: Icon(
              Icons.folder_outlined,
              size: 18,
              color: hot ? cs.primary : null,
            ),
            filled: hot,
            fillColor: hot ? cs.primary.withValues(alpha: 0.10) : null,
            border: OutlineInputBorder(
              borderSide: BorderSide(color: borderColor, width: borderWidth),
            ),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: borderColor, width: borderWidth),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: cs.primary, width: 2),
            ),
            contentPadding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          ),
          child: Row(
            children: [
              Expanded(
                child: hot
                    ? Text(
                        '释放以设为输出目录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: cs.primary,
                        ),
                      )
                    : PathEllipsisText(
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
      },
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
          top: BorderSide(
            color: cs.outline.withValues(alpha: 0.55),
            width: 1,
          ),
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
                      final nodeCount = section.nodes.length;
                      final draggingHere =
                          _nodeDragCategory == section.category;
                      return Wrap(
                        spacing: gap,
                        runSpacing: gap,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (var i = 0; i < nodeCount; i++)
                            SizedBox(
                              width: tileW,
                              child: _buildNodeTile(
                                section.nodes[i],
                                category: section.category,
                                index: i,
                                nodeCount: nodeCount,
                              ),
                            ),
                          if (draggingHere)
                            SizedBox(
                              width: tileW,
                              child: _buildNodeEndInsertSlot(
                                category: section.category,
                                insertBefore: nodeCount,
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

  Widget _buildJobList(
    ColorScheme cs,
    List<_ComfyJob> jobs,
  ) {
    final activeCount = jobs.where((j) => j.isActive).length;
    final finishedCount = jobs.length - activeCount;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '生成任务',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          height: 1.1,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    activeCount > 0 ? '进行中 $activeCount' : '无进行中任务',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '点击展开',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.1,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
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
        Flexible(
          fit: FlexFit.loose,
          child: ListView.separated(
            controller: _jobListScroll,
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            itemCount: jobs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) => _buildJobCard(jobs[i], cs),
          ),
        ),
      ],
    );
  }

  void _openOutputDirInAssets(String dir) {
    final raw = dir.trim();
    if (raw.isEmpty) {
      showGlobalToast(context, '输出目录为空');
      return;
    }
    final normalized = p.normalize(raw);
    final d = Directory(normalized);
    if (!d.existsSync()) {
      showGlobalToast(context, '目录不存在：$normalized');
      return;
    }
    ref.read(selectedDirProvider.notifier).state = normalized;
    ref.read(contentModeProvider.notifier).state = 'assets';
  }

  void _revealJobOutputsInAssets(_ComfyJob job) {
    if (job.outputs.isNotEmpty) {
      ref.read(assetsRevealFilesProvider.notifier).state =
          List<String>.from(job.outputs);
    } else {
      ref.read(assetsRevealFilesProvider.notifier).state = null;
    }
    _openOutputDirInAssets(job.outputDir);
    // 同目录时 selectedDir 可能不变，主动刷一下以看到新文件。
    ref.read(treeRefreshTickProvider.notifier).state++;
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
    final accent = switch (job.phase) {
      _ComfyJobPhase.failed => cs.error,
      _ComfyJobPhase.cancelled => cs.onSurfaceVariant,
      _ComfyJobPhase.completed => const Color(0xFF6F9A78),
      _ => cs.primary,
    };
    final progress = job.runStatus?.progressFraction;
    final time = TimeOfDay.fromDateTime(job.createdAt);
    final timeText =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    final muted = TextStyle(fontSize: 11, color: cs.onSurfaceVariant);
    final metaBits = <String>[
      if (job.runStatus?.progressLabel.isNotEmpty == true)
        job.runStatus!.progressLabel,
      if (job.runStatus?.currentNodeId != null)
        '节点 ${job.runStatus!.currentNodeId}',
    ];
    final detail = job.detail.trim();
    final detailAddsInfo = detail.isNotEmpty &&
        detail != phaseLabel &&
        detail != '$phaseLabel…' &&
        !(phaseLabel == '准备中' && detail == '准备中…');

    final open = _openJobIds.contains(job.id);

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: job.isActive
              ? accent.withValues(alpha: 0.7)
              : cs.outlineVariant,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: ColoredBox(color: accent, child: const SizedBox(width: 3)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        mouseCursor: SystemMouseCursors.click,
                        onTap: () => setState(() {
                          if (open) {
                            _openJobIds.remove(job.id);
                          } else {
                            _openJobIds.add(job.id);
                          }
                        }),
                        child: Row(
                          children: [
                            Icon(
                              open ? Icons.expand_more : Icons.chevron_right,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 2),
                            _JobPhaseChip(
                              label: phaseLabel,
                              color: accent,
                              busy: job.isActive,
                              progress: progress,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              timeText,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.2,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '用时 ${job.elapsedLabel}',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.2,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    TextSpan(text: job.templateName),
                                    if (!open &&
                                        job.outputFileName.isNotEmpty)
                                      TextSpan(
                                        text: '  ${job.outputFileName}',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w400,
                                          fontSize: 12,
                                          color: cs.onSurfaceVariant,
                                        ),
                                      ),
                                  ],
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  height: 1.2,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (job.isActive)
                      TextButton(
                        onPressed:
                            job.cancelling ? null : () => _cancelJob(job),
                        style: TextButton.styleFrom(
                          foregroundColor: cs.error,
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          enabledMouseCursor: SystemMouseCursors.click,
                          disabledMouseCursor: SystemMouseCursors.basic,
                        ),
                        child: Text(job.cancelling ? '取消中…' : '取消'),
                      )
                    else
                      IconButton(
                        tooltip: '从列表移除',
                        mouseCursor: SystemMouseCursors.click,
                        icon: const Icon(Icons.close, size: 16),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                        onPressed: () => _dismissJob(job.id),
                      ),
                  ],
                ),
                if (job.isActive) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        value: progress,
                        color: accent,
                        backgroundColor: cs.surfaceContainerLow,
                      ),
                    ),
                  ),
                ],
                if (open) ...[
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.only(left: 22, right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          metaBits.join('  ·  '),
                          style: muted,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (detailAddsInfo) ...[
                          const SizedBox(height: 4),
                          Text(
                            detail,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.3,
                              color: cs.onSurface.withValues(alpha: 0.88),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 4),
                        InkWell(
                          mouseCursor: SystemMouseCursors.click,
                          onTap: () => _revealJobOutputsInAssets(job),
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.folder_open_outlined,
                                  size: 14,
                                  color: cs.primary.withValues(alpha: 0.9),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: PathEllipsisText(
                                    job.outputFileName.isEmpty
                                        ? job.outputDir
                                        : '${job.outputFileName}：${job.outputDir}',
                                    maxLines: 1,
                                    style: muted.copyWith(
                                      color: cs.primary,
                                      decoration: TextDecoration.underline,
                                      decorationColor:
                                          cs.primary.withValues(alpha: 0.4),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (job.error != null) ...[
                          const SizedBox(height: 6),
                          SelectableText(
                            job.error!,
                            style: TextStyle(color: cs.error, fontSize: 11),
                          ),
                        ],
                        if (job.outputs.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '生成文件：',
                                  style: muted.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Wrap(
                                  spacing: 2,
                                  runSpacing: 2,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    for (var i = 0;
                                        i < job.outputs.length;
                                        i++) ...[
                                      if (i > 0)
                                        Text('；', style: muted),
                                      _JobOutputNameChip(
                                        path: job.outputs[i],
                                        style: muted,
                                        onDelete: () => _deleteJobOutput(
                                          job,
                                          job.outputs[i],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: () => _deleteAllJobOutputs(job),
                                style: TextButton.styleFrom(
                                  foregroundColor: cs.error,
                                  visualDensity: VisualDensity.compact,
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                  ),
                                  enabledMouseCursor: SystemMouseCursors.click,
                                ),
                                child: const Text(
                                  '全部删除',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
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

  /// 节点上可本地预览的媒体绝对路径（已存在的文件）。
  List<String> _nodePreviewableMediaPaths(ComfyExposedNode node) {
    final out = <String>[];
    for (final field in node.fields) {
      if (!field.widget.isMedia) continue;
      final path = _values[field.id]?.toString().trim() ?? '';
      if (MediaHoverPreviewIcon.canPreview(path)) {
        out.add(path);
      }
    }
    return out;
  }

  Widget _buildNodeTile(
    ComfyExposedNode node, {
    required int category,
    required int index,
    required int nodeCount,
  }) {
    final cs = Theme.of(context).colorScheme;
    final canBypass = node.bypassWhenDisabled;
    final on = canBypass
        ? (_enabled[node.nodeId] ?? node.defaultEnabled)
        : true;
    final expanded = _expanded[node.nodeId] ?? false;
    final displayLabel = _nodeDisplayLabel(node);
    final preview = _nodeValuePreview(node);
    final mediaPaths = _nodePreviewableMediaPaths(node);

    void toggleExpand() {
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
    }

    // 左侧 InkWell 展开；右侧预览图标在 Expanded 外固定宽度，
    // 标题/副标题 ellipsis 按剩余宽度计算，不与图标抢宽。
    Widget buildTile({required bool dropHot, required bool dropBlocked}) {
      return Material(
        color: expanded
            ? cs.primary.withValues(alpha: 0.16)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: toggleExpand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          displayLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                            color: expanded ? cs.primary : cs.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          dropHot
                              ? '释放以填入路径'
                              : dropBlocked
                                  ? '类型不匹配'
                                  : (preview.isEmpty ? '未填写' : preview),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: dropHot || dropBlocked
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: dropHot
                                ? cs.primary
                                : dropBlocked
                                    ? cs.error
                                    : cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 节点排序拖拽中隐藏媒体预览，避免遮挡插入竖线。
              if (!dropHot &&
                  !dropBlocked &&
                  _nodeDragCategory == null) ...[
                for (final path in mediaPaths.take(3))
                  MediaHoverPreviewIcon(path: path),
                if (mediaPaths.length > 3)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Text(
                      '+',
                      style: TextStyle(
                        fontSize: 10,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
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
      );
    }

    final insertBefore = _nodeInsertBefore;
    final fromIdx = _nodeDragFromIndex;
    final draggingHere = _nodeDragCategory == category && insertBefore != null;
    final insertNoOp = fromIdx != null &&
        insertBefore != null &&
        (fromIdx == insertBefore || fromIdx + 1 == insertBefore);
    final showInsertLeft =
        draggingHere && insertBefore == index && !insertNoOp;
    final showInsertRight = draggingHere &&
        insertBefore == index + 1 &&
        index == nodeCount - 1 &&
        !insertNoOp;

    return _wrapFsDropTarget(
      canAccept: (item) => _nodeCanAcceptMediaDrop(node, item),
      onAccept: (item) => _applyMediaDropToNode(node, item),
      builder: (context, dropHot, dropBlocked) {
        final tile = buildTile(dropHot: dropHot, dropBlocked: dropBlocked);
        return LongPressDraggable<({int category, int index})>(
          data: (category: category, index: index),
          onDragStarted: () {
            dismissActiveMediaHoverPreview();
            setState(() {
              _nodeDragCategory = category;
              _nodeDragFromIndex = index;
              _nodeInsertBefore = null;
            });
          },
          onDragEnd: (_) => _clearNodeReorderDrag(),
          feedback: Material(
            elevation: 10,
            shadowColor: Colors.black.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 168,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.75),
                    width: 1.5,
                  ),
                ),
                child: Opacity(
                  opacity: 0.95,
                  child: buildTile(dropHot: false, dropBlocked: false),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.28,
            child: buildTile(dropHot: false, dropBlocked: false),
          ),
          child: _NodeReorderDropTarget(
            category: category,
            index: index,
            showInsertLeft: showInsertLeft,
            showInsertRight: showInsertRight,
            dropHot: dropHot,
            dropBlocked: dropBlocked,
            expanded: expanded,
            onHoverInsert: (fromIndex, insertBefore) {
              _setNodeInsertBefore(category, fromIndex, insertBefore);
            },
            onLeaveInsert: _clearNodeInsertHint,
            onAccept: (fromIndex, insertBefore) {
              // 必须以源分区落点为准；避免悬停过其它组后残留错误 insertBefore。
              if (_nodeDragCategory != category) return;
              _moveNodeInCategory(
                category,
                fromIndex,
                _nodeInsertBefore ?? insertBefore,
              );
            },
            child: tile,
          ),
        );
      },
    );
  }

  /// 分区网格末尾的落点：拖到空白处也可插到最后。
  Widget _buildNodeEndInsertSlot({
    required int category,
    required int insertBefore,
  }) {
    final cs = Theme.of(context).colorScheme;
    final active = _nodeDragCategory == category &&
        _nodeInsertBefore == insertBefore &&
        _nodeDragFromIndex != null &&
        _nodeDragFromIndex != insertBefore &&
        _nodeDragFromIndex! + 1 != insertBefore;

    return DragTarget<({int category, int index})>(
      onWillAcceptWithDetails: (details) => details.data.category == category,
      onMove: (details) {
        // Flutter 在 willAccept=false 时仍可能回调 onMove，必须再挡一层。
        if (details.data.category != category) return;
        _setNodeInsertBefore(category, details.data.index, insertBefore);
      },
      onLeave: (_) => _clearNodeInsertHint(),
      onAcceptWithDetails: (details) {
        if (details.data.category != category) return;
        _moveNodeInCategory(
          category,
          details.data.index,
          _nodeInsertBefore ?? insertBefore,
        );
      },
      builder: (context, candidate, rejected) {
        // 与节点瓦片同高量级，并在 Wrap 里垂直居中对齐，避免「靠上」。
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: active
                ? cs.primary.withValues(alpha: 0.1)
                : Colors.transparent,
            border: Border.all(
              color: active
                  ? cs.primary.withValues(alpha: 0.65)
                  : cs.outlineVariant.withValues(alpha: 0.4),
              width: active ? 1.5 : 1,
            ),
          ),
          // 竖线由上一张卡的右侧 caret 承担（缝隙正中）；此处只作落点框。
          child: Icon(
            Icons.add,
            size: 18,
            color: active
                ? cs.primary.withValues(alpha: 0.85)
                : cs.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        );
      },
    );
  }

  Widget _buildNodeEditor(ComfyExposedNode node) {
    final cs = Theme.of(context).colorScheme;
    final canBypass = node.bypassWhenDisabled;
    final on = canBypass
        ? (_enabled[node.nodeId] ?? node.defaultEnabled)
        : true;
    final displayLabel = _nodeDisplayLabel(node);

    final editor = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.primary.withValues(alpha: 0.7)),
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
              child: _buildFieldsLayout(node, nodeTitle: displayLabel),
            ),
          ),
        ],
      ),
    );

    // 已启用时只由地址栏接收拖放，避免与外层叠两层提示；
    // 禁用时字段不可点，整块编辑区接收以便拖入后自动使能。
    if (on || !canBypass) return editor;

    return _wrapFsDropTarget(
      canAccept: (item) => _nodeCanAcceptMediaDrop(node, item),
      onAccept: (item) => _applyMediaDropToNode(node, item),
      builder: (context, dropHot, dropBlocked) {
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: dropBlocked
                  ? cs.error
                  : dropHot
                      ? cs.primary
                      : cs.primary.withValues(alpha: 0.7),
              width: dropHot || dropBlocked ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      dropHot
                          ? '释放以填入路径'
                          : dropBlocked
                              ? '文件类型不匹配，无法填入'
                              : displayLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: dropHot
                            ? cs.primary
                            : dropBlocked
                                ? cs.error
                                : null,
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
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '已禁用：本次生成将 Bypass 整个节点',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ),
              Opacity(
                opacity: 0.45,
                child: IgnorePointer(
                  ignoring: true,
                  child: _buildFieldsLayout(node, nodeTitle: displayLabel),
                ),
              ),
            ],
          ),
        );
      },
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
    ComfyWidgetKind? kind;
    for (final field in node.fields) {
      if (!_isTextInputField(field)) continue;
      final fn = _textFocus[field.id];
      if (fn != null) {
        fieldId = field.id;
        target = fn;
        kind = field.widget;
        break;
      }
    }
    if (target == null || fieldId == null || kind == null) return;
    final focus = target;
    final id = fieldId;
    final selectAll =
        kind == ComfyWidgetKind.int || kind == ComfyWidgetKind.float;

    void applySelection() {
      final ctrl = _textCtrls[id];
      if (ctrl == null) return;
      final len = ctrl.text.length;
      ctrl.selection = selectAll
          ? TextSelection(baseOffset: 0, extentOffset: len)
          : TextSelection.collapsed(offset: len);
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      focus.requestFocus();
      applySelection();
      // 桌面端获焦后可能再改一次选区，补一帧稳住目标选区。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !focus.hasFocus) return;
        applySelection();
      });
    });
  }

  bool _isWideField(ComfyExposedField field) =>
      field.widget.isMedia || field.widget == ComfyWidgetKind.multiline;

  Widget _buildFieldsLayout(
    ComfyExposedNode node, {
    required String nodeTitle,
  }) {
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
        for (final field in wide)
          _buildFieldBody(field, node: node, nodeTitle: nodeTitle),
        for (var i = 0; i < narrow.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _buildFieldBody(
                    narrow[i],
                    node: node,
                    nodeTitle: nodeTitle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: i + 1 < narrow.length
                      ? _buildFieldBody(
                          narrow[i + 1],
                          node: node,
                          nodeTitle: nodeTitle,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFieldBody(
    ComfyExposedField field, {
    required ComfyExposedNode node,
    required String nodeTitle,
  }) {
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
        final canPreview = MediaHoverPreviewIcon.canPreview(path);
        return _wrapFsDropTarget(
          canAccept: (item) => _fieldCanAcceptMediaDrop(field, item),
          onAccept: (item) => _applyMediaDropToField(node, field, item),
          radius: BorderRadius.circular(6),
          builder: (context, dropHot, dropBlocked) {
            final fieldCs = Theme.of(context).colorScheme;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(field.label, style: const TextStyle(fontSize: 12)),
                  Row(
                    children: [
                      // 路径在 Expanded 内按剩余宽度折叠；预览图标固定宽在外侧。
                      Expanded(
                        child: dropHot
                            ? Text(
                                '释放以填入路径',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: fieldCs.primary,
                                ),
                              )
                            : dropBlocked
                                ? Text(
                                    '文件类型不匹配，无法填入',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: fieldCs.error,
                                    ),
                                  )
                                : path.isEmpty
                                    ? Text(
                                        '未选择（可拖入文件）',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: fieldCs.onSurfaceVariant,
                                        ),
                                      )
                                    : PathEllipsisText(
                                        path,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: fieldCs.onSurfaceVariant,
                                        ),
                                      ),
                      ),
                      if (!dropHot && !dropBlocked && path.isNotEmpty)
                        Builder(
                          builder: (btnCtx) => TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              minimumSize: const Size(0, 32),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => _openSiblingMediaPicker(
                              anchorContext: btnCtx,
                              field: field,
                              currentPath: path,
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('同目录', style: TextStyle(fontSize: 12)),
                                Icon(Icons.arrow_drop_down, size: 16),
                              ],
                            ),
                          ),
                        ),
                      if (!dropHot && !dropBlocked && canPreview)
                        MediaHoverPreviewIcon(path: path),
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
          },
        );
      case ComfyWidgetKind.multiline:
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Stack(
            children: [
              TextField(
                controller: _textCtrls[field.id],
                focusNode: _textFocus[field.id],
                maxLines: 8,
                minLines: 8,
                onChanged: (_) => _schedulePersistSession(),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: field.label,
                  alignLabelWithHint: true,
                  filled: true,
                  fillColor: cs.surfaceContainerLowest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.outline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: cs.primary, width: 1.4),
                  ),
                  // 右下角留给斜线抓手，避免文字压住。
                  contentPadding: const EdgeInsets.fromLTRB(12, 12, 22, 18),
                ),
              ),
              Positioned(
                right: 1,
                bottom: 1,
                child: Tooltip(
                  message: '放大编辑',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    onTap: () => _openExpandedTextEditor(
                      field,
                      nodeTitle: nodeTitle,
                    ),
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CustomPaint(
                        painter: _TextareaExpandGripPainter(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case ComfyWidgetKind.int:
      case ComfyWidgetKind.float:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _textCtrls[field.id],
            focusNode: _textFocus[field.id],
            onChanged: (_) => _schedulePersistSession(),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // 数值框点击即全选，方便直接覆盖输入（种子等）。
            onTap: () {
              final ctrl = _textCtrls[field.id];
              if (ctrl == null) return;
              ctrl.selection = TextSelection(
                baseOffset: 0,
                extentOffset: ctrl.text.length,
              );
            },
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
      case ComfyWidgetKind.text:
      case ComfyWidgetKind.choice:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            controller: _textCtrls[field.id],
            focusNode: _textFocus[field.id],
            onChanged: (_) => _schedulePersistSession(),
            keyboardType: TextInputType.text,
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

/// 节点排序落点：按左右半区决定插到卡前/卡后，用竖线 caret 指示，不做整卡「替换」高亮。
/// 仅接受同分区拖放；其它分区的 onMove 也忽略，避免误显示插入线。
class _NodeReorderDropTarget extends StatelessWidget {
  const _NodeReorderDropTarget({
    required this.category,
    required this.index,
    required this.showInsertLeft,
    required this.showInsertRight,
    required this.dropHot,
    required this.dropBlocked,
    required this.expanded,
    required this.onHoverInsert,
    required this.onLeaveInsert,
    required this.onAccept,
    required this.child,
  });

  final int category;
  final int index;
  final bool showInsertLeft;
  final bool showInsertRight;
  final bool dropHot;
  final bool dropBlocked;
  final bool expanded;
  final void Function(int fromIndex, int insertBefore) onHoverInsert;
  final VoidCallback onLeaveInsert;
  final void Function(int fromIndex, int insertBefore) onAccept;
  final Widget child;

  int _insertBeforeFor(Offset global, RenderBox box) {
    final local = box.globalToLocal(global);
    return local.dx < box.size.width * 0.5 ? index : index + 1;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DragTarget<({int category, int index})>(
      onWillAcceptWithDetails: (details) => details.data.category == category,
      onMove: (details) {
        // willAccept=false 时 Flutter 仍可能回调 onMove。
        if (details.data.category != category) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) return;
        onHoverInsert(
          details.data.index,
          _insertBeforeFor(details.offset, box),
        );
      },
      onLeave: (_) => onLeaveInsert(),
      onAcceptWithDetails: (details) {
        if (details.data.category != category) return;
        final box = context.findRenderObject() as RenderBox?;
        final insertBefore = box != null && box.hasSize
            ? _insertBeforeFor(details.offset, box)
            : index;
        onAccept(details.data.index, insertBefore);
      },
      builder: (context, candidate, rejected) {
        return Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: dropBlocked
                      ? cs.error
                      : expanded || dropHot
                          ? cs.primary
                          : cs.outlineVariant.withValues(alpha: 0.55),
                  width: expanded || dropHot || dropBlocked ? 1.5 : 1,
                ),
              ),
              child: child,
            ),
            if (showInsertLeft)
              Positioned(
                // 卡缝 gap=6、线宽=3 → 线心落在 -3，左缘应在 -4.5
                left: -(_NodeInsertCaret.gap + _NodeInsertCaret.width) / 2,
                top: 6,
                bottom: 6,
                child: const _NodeInsertCaret(),
              ),
            if (showInsertRight)
              Positioned(
                right: -(_NodeInsertCaret.gap + _NodeInsertCaret.width) / 2,
                top: 6,
                bottom: 6,
                child: const _NodeInsertCaret(),
              ),
          ],
        );
      },
    );
  }
}

/// 插入位置指示：细竖线 + 轻光晕，居中落在两卡 spacing 缝隙正中。
class _NodeInsertCaret extends StatelessWidget {
  const _NodeInsertCaret();

  /// 与节点 Wrap 的 spacing 保持一致。
  static const double gap = 6;
  static const double width = 3;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: SizedBox(
        width: width,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                cs.primary.withValues(alpha: 0.35),
                cs.primary,
                cs.primary.withValues(alpha: 0.35),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: cs.primary.withValues(alpha: 0.45),
                blurRadius: 6,
                spreadRadius: 0.5,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 生成面板媒体/路径拖入：可接收时立即提示；不可接收时悬停片刻再提示原因。
/// 拖拽中指针按下，系统 [Tooltip] 往往不弹出，故用自绘浮层。
/// 锚定选择列表项：悬停时抬高表面与描边，预选对比足够明显。
class _HoverChoiceTile extends StatefulWidget {
  const _HoverChoiceTile({
    required this.selected,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final bool selected;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? trailing;
  final VoidCallback onTap;

  @override
  State<_HoverChoiceTile> createState() => _HoverChoiceTileState();
}

class _HoverChoiceTileState extends State<_HoverChoiceTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selected = widget.selected;
    final Color bg;
    final Color border;
    if (selected) {
      bg = cs.primary.withValues(alpha: _hover ? 0.22 : 0.14);
      border = cs.primary.withValues(alpha: _hover ? 0.9 : 0.65);
    } else if (_hover) {
      bg = cs.surfaceContainerHighest;
      border = cs.outline.withValues(alpha: 0.9);
    } else {
      bg = cs.surfaceContainerLow.withValues(alpha: 0.75);
      border = cs.outlineVariant.withValues(alpha: 0.5);
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          hoverColor: Colors.transparent,
          splashColor: cs.primary.withValues(alpha: 0.12),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 15, color: widget.iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected || _hover ? FontWeight.w600 : FontWeight.w500,
                      color: selected ? cs.primary : cs.onSurface,
                    ),
                  ),
                ),
                if (widget.trailing != null)
                  Text(
                    widget.trailing!,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: cs.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ComfyFsDropTarget extends StatefulWidget {
  const _ComfyFsDropTarget({
    required this.canAccept,
    required this.onAccept,
    required this.builder,
    required this.dropHint,
    required this.rejectHintFor,
    this.radius,
  });

  final bool Function(FsDragItem item) canAccept;
  final void Function(FsDragItem item) onAccept;
  final Widget Function(BuildContext context, bool hot, bool blocked) builder;
  final String dropHint;
  final String Function(FsDragItem item) rejectHintFor;
  final BorderRadius? radius;

  @override
  State<_ComfyFsDropTarget> createState() => _ComfyFsDropTargetState();
}

class _ComfyFsDropTargetState extends State<_ComfyFsDropTarget> {
  static const _rejectTipDelay = Duration(milliseconds: 480);

  Timer? _rejectTipTimer;
  bool _showRejectTip = false;
  String _rejectTip = '';
  final LayerLink _link = LayerLink();
  OverlayEntry? _tipEntry;

  @override
  void dispose() {
    _rejectTipTimer?.cancel();
    _removeTip();
    super.dispose();
  }

  void _removeTip() {
    _tipEntry?.remove();
    _tipEntry = null;
  }

  void _clearRejectTip() {
    _rejectTipTimer?.cancel();
    _rejectTipTimer = null;
    if (_showRejectTip || _rejectTip.isNotEmpty) {
      _showRejectTip = false;
      _rejectTip = '';
      _removeTip();
      if (mounted) setState(() {});
    }
  }

  void _armRejectTip(FsDragItem item) {
    final tip = widget.rejectHintFor(item);
    if (_rejectTipTimer != null && _rejectTip == tip && !_showRejectTip) {
      return;
    }
    if (_showRejectTip && _rejectTip == tip) return;
    _rejectTipTimer?.cancel();
    _rejectTip = tip;
    _showRejectTip = false;
    _removeTip();
    _rejectTipTimer = Timer(_rejectTipDelay, () {
      if (!mounted) return;
      setState(() => _showRejectTip = true);
      _showTipOverlay(tip, isError: true);
    });
  }

  void _showAcceptTip() {
    _clearRejectTip();
    _showTipOverlay(widget.dropHint, isError: false);
  }

  void _showTipOverlay(String message, {required bool isError}) {
    _removeTip();
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final cs = Theme.of(context).colorScheme;
    _tipEntry = OverlayEntry(
      builder: (ctx) {
        return IgnorePointer(
          child: UnconstrainedBox(
            child: CompositedTransformFollower(
              link: _link,
              showWhenUnlinked: false,
              targetAnchor: Alignment.topCenter,
              followerAnchor: Alignment.bottomCenter,
              offset: const Offset(0, -8),
              child: Material(
                elevation: 6,
                color: isError ? cs.errorContainer : cs.inverseSurface,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: isError
                          ? cs.onErrorContainer
                          : cs.onInverseSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_tipEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: DragTarget<FsDragItem>(
        onWillAcceptWithDetails: (d) {
          final ok = widget.canAccept(d.data);
          if (ok) {
            _clearRejectTip();
          } else {
            _armRejectTip(d.data);
          }
          return ok;
        },
        onMove: (details) {
          if (widget.canAccept(details.data)) {
            if (_tipEntry == null || _showRejectTip) {
              _showAcceptTip();
            }
          } else {
            _armRejectTip(details.data);
          }
        },
        onLeave: (_) {
          _clearRejectTip();
          _removeTip();
        },
        onAcceptWithDetails: (d) {
          _clearRejectTip();
          _removeTip();
          widget.onAccept(d.data);
        },
        builder: (context, candidate, rejected) {
          final hot = candidate.isNotEmpty;
          final blocked = !hot && rejected.isNotEmpty;
          final cs = Theme.of(context).colorScheme;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: widget.radius ?? BorderRadius.circular(8),
              border: hot
                  ? Border.all(color: cs.primary, width: 2)
                  : blocked
                      ? Border.all(
                          color: cs.error.withValues(alpha: 0.85),
                          width: 2,
                        )
                      : Border.all(color: Colors.transparent, width: 2),
              color: hot
                  ? cs.primary.withValues(alpha: 0.08)
                  : blocked
                      ? cs.error.withValues(alpha: 0.06)
                      : null,
            ),
            child: widget.builder(context, hot, blocked),
          );
        },
      ),
    );
  }
}

class _JobOutputNameChip extends StatelessWidget {
  const _JobOutputNameChip({
    required this.path,
    required this.style,
    required this.onDelete,
  });

  final String path;
  final TextStyle style;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = p.basename(path);
    final canPreview = MediaHoverPreviewIcon.canPreview(path);
    final nameLabel = Text(
      name,
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPreview) MediaHoverPreviewIcon(path: path, extent: 22),
        canPreview
            ? MediaHoverPreviewAnchor(path: path, child: nameLabel)
            : nameLabel,
        IconButton(
          tooltip: '删除文件',
          mouseCursor: SystemMouseCursors.click,
          icon: Icon(Icons.delete_outline, size: 15, color: cs.error),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
          padding: EdgeInsets.zero,
          onPressed: onDelete,
        ),
      ],
    );
  }
}

class _ComfyJobSplitter extends StatefulWidget {
  const _ComfyJobSplitter({
    required this.onDragStart,
    required this.onDragDelta,
    required this.onReset,
  });

  final VoidCallback onDragStart;
  final ValueChanged<double> onDragDelta;
  final VoidCallback onReset;

  @override
  State<_ComfyJobSplitter> createState() => _ComfyJobSplitterState();
}

class _ComfyJobSplitterState extends State<_ComfyJobSplitter> {
  bool _hover = false;
  bool _dragging = false;
  bool _moved = false;
  double? _lastY;
  DateTime? _lastTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = _hover || _dragging;
    return Tooltip(
      message: '拖动调节任务区高度 · 双击重置',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeUpDown,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) {
          if (!_dragging) setState(() => _hover = false);
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            final now = DateTime.now();
            final doubleTap = _lastTap != null &&
                now.difference(_lastTap!) < const Duration(milliseconds: 280);
            _lastTap = now;
            if (doubleTap) {
              _dragging = false;
              _moved = false;
              _lastY = null;
              widget.onReset();
              return;
            }
            _dragging = true;
            _moved = false;
            _lastY = e.position.dy;
            setState(() {});
          },
          onPointerMove: (e) {
            if (!_dragging || _lastY == null) return;
            final dy = e.position.dy - _lastY!;
            if (dy == 0) return;
            _lastY = e.position.dy;
            if (!_moved) {
              _moved = true;
              widget.onDragStart();
            }
            widget.onDragDelta(dy);
          },
          onPointerUp: (_) {
            _dragging = false;
            _lastY = null;
            _moved = false;
            if (mounted) setState(() => _hover = false);
          },
          onPointerCancel: (_) {
            _dragging = false;
            _lastY = null;
            _moved = false;
            if (mounted) setState(() => _hover = false);
          },
          child: SizedBox(
            height: 14,
            child: Center(
              child: Container(
                height: active ? 3 : 1,
                margin: const EdgeInsets.symmetric(horizontal: 24),
                decoration: BoxDecoration(
                  color: active
                      ? cs.primary.withValues(alpha: 0.9)
                      : cs.outlineVariant.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComfyLeftRailSplitter extends StatefulWidget {
  const _ComfyLeftRailSplitter({
    required this.onDragDelta,
    required this.onReset,
  });

  final ValueChanged<double> onDragDelta;
  final VoidCallback onReset;

  @override
  State<_ComfyLeftRailSplitter> createState() => _ComfyLeftRailSplitterState();
}

class _ComfyLeftRailSplitterState extends State<_ComfyLeftRailSplitter> {
  bool _hover = false;
  bool _dragging = false;
  double? _lastX;
  DateTime? _lastTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = _hover || _dragging;
    return Tooltip(
      message: '拖动调节左侧栏宽度 · 双击重置',
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) {
          if (!_dragging) setState(() => _hover = false);
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            final now = DateTime.now();
            final doubleTap = _lastTap != null &&
                now.difference(_lastTap!) < const Duration(milliseconds: 280);
            _lastTap = now;
            if (doubleTap) {
              _dragging = false;
              _lastX = null;
              widget.onReset();
              return;
            }
            _dragging = true;
            _lastX = e.position.dx;
            setState(() {});
          },
          onPointerMove: (e) {
            if (!_dragging || _lastX == null) return;
            final dx = e.position.dx - _lastX!;
            if (dx == 0) return;
            _lastX = e.position.dx;
            widget.onDragDelta(dx);
          },
          onPointerUp: (_) {
            _dragging = false;
            _lastX = null;
            if (mounted) setState(() => _hover = false);
          },
          onPointerCancel: (_) {
            _dragging = false;
            _lastX = null;
            if (mounted) setState(() => _hover = false);
          },
          child: SizedBox(
            width: 8,
            child: Center(
              child: Container(
                width: active ? 3 : 1,
                color: active
                    ? cs.primary.withValues(alpha: 0.9)
                    : cs.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComfyLeftSplitter extends StatefulWidget {
  const _ComfyLeftSplitter({required this.onDragUpdate});

  final GestureDragUpdateCallback onDragUpdate;

  @override
  State<_ComfyLeftSplitter> createState() => _ComfyLeftSplitterState();
}

class _ComfyLeftSplitterState extends State<_ComfyLeftSplitter> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: widget.onDragUpdate,
        child: SizedBox(
          height: 6,
          child: Center(
            child: Container(
              height: _hover ? 2 : 1,
              color: _hover
                  ? cs.primary.withValues(alpha: 0.85)
                  : cs.outlineVariant.withValues(alpha: 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

class _ComfyBoundTemplateRow extends StatefulWidget {
  const _ComfyBoundTemplateRow({
    required this.name,
    required this.selected,
    required this.onTap,
    required this.onUnbind,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onUnbind;

  @override
  State<_ComfyBoundTemplateRow> createState() => _ComfyBoundTemplateRowState();
}

class _ComfyBoundTemplateRowState extends State<_ComfyBoundTemplateRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: widget.selected
            ? cs.surfaceContainerHighest.withValues(alpha: 0.65)
            : Colors.transparent,
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: widget.name,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(
                      widget.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                if (_hover)
                  IconButton(
                    tooltip: '从此 URL 移除',
                    mouseCursor: SystemMouseCursors.click,
                    icon: Icon(
                      Icons.link_off,
                      size: 18,
                      color: cs.onSurface,
                    ),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  padding: const EdgeInsets.all(6),
                  onPressed: widget.onUnbind,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _JobPhaseChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool busy;
  final double? progress;

  const _JobPhaseChip({
    required this.label,
    required this.color,
    required this.busy,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) ...[
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: color,
                value: progress,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color,
              height: 1.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// 网页 textarea 右下角抓手：靠右下角的小三角，由若干条 `/` 斜线组成。
class _TextareaExpandGripPainter extends CustomPainter {
  final Color color;

  _TextareaExpandGripPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 三条平行 `/`：从底边连到右边，越靠外越长，整体呈右下角三角。
    // d = 距右下角的距离（同时作为线段在两轴上的跨度）。
    const ds = <double>[4, 7.5, 11];
    for (final d in ds) {
      canvas.drawLine(
        Offset(size.width - d, size.height - 1),
        Offset(size.width - 1, size.height - d),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TextareaExpandGripPainter oldDelegate) =>
      oldDelegate.color != color;
}
