import 'dart:convert';

/// 一个 ComfyUI 服务实例（全局，多 URL）。
class ComfyServer {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;

  const ComfyServer({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.apiKey = '',
  });

  ComfyServer copyWith({
    String? id,
    String? name,
    String? baseUrl,
    String? apiKey,
  }) {
    return ComfyServer(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
      };

  factory ComfyServer.fromJson(Map<String, dynamic> json) {
    return ComfyServer(
      id: json['id'] as String? ??
          'srv_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'ComfyUI',
      baseUrl: (json['baseUrl'] as String? ?? 'http://127.0.0.1:8188').trim(),
      apiKey: json['apiKey'] as String? ?? '',
    );
  }

  static ComfyServer localDefault() => const ComfyServer(
        id: 'local',
        name: '本机',
        baseUrl: 'http://127.0.0.1:8188',
      );
}

/// 表单控件类型（导入向导可选，运行时按此渲染）。
enum ComfyWidgetKind {
  text,
  multiline,
  int,
  float,
  bool,
  image,
  audio,
  video,
  choice,
}

ComfyWidgetKind comfyWidgetFromName(String? raw) {
  switch (raw) {
    case 'multiline':
      return ComfyWidgetKind.multiline;
    case 'int':
      return ComfyWidgetKind.int;
    case 'float':
      return ComfyWidgetKind.float;
    case 'bool':
      return ComfyWidgetKind.bool;
    case 'image':
      return ComfyWidgetKind.image;
    case 'audio':
      return ComfyWidgetKind.audio;
    case 'video':
      return ComfyWidgetKind.video;
    case 'choice':
      return ComfyWidgetKind.choice;
    case 'text':
    default:
      return ComfyWidgetKind.text;
  }
}

extension ComfyWidgetKindX on ComfyWidgetKind {
  bool get isMedia =>
      this == ComfyWidgetKind.image ||
      this == ComfyWidgetKind.audio ||
      this == ComfyWidgetKind.video;
}

/// 下游消费方：本节点输出接到了谁的哪个输入点位。
class ComfyConsumerLink {
  final String consumerNodeId;
  final String consumerClassType;
  final String? consumerTitle;
  /// 下游节点上的输入口名称（点位），如 ref_image_1。
  final String inputKey;

  const ComfyConsumerLink({
    required this.consumerNodeId,
    required this.consumerClassType,
    this.consumerTitle,
    required this.inputKey,
  });

  String get consumerDisplayName {
    final t = consumerTitle?.trim();
    if (t != null && t.isNotEmpty) return t;
    return consumerClassType;
  }

  /// 点位友好名（参考图 1）；认不出则原样返回 inputKey。
  String get pinLabel {
    final mapped = ComfyNodeGroup.mapConsumerKey(inputKey);
    if (mapped != null && mapped != inputKey) return mapped;
    return inputKey;
  }

  /// 列表主文案：突出点位名。
  String get shortLabel {
    final friendly = pinLabel;
    if (friendly != inputKey) {
      return '点位 $inputKey（$friendly）→ $consumerDisplayName';
    }
    return '点位 $inputKey → $consumerDisplayName';
  }

  /// 详情行：节点 + 精确输入点。
  String get detailLine =>
      '→ 接到「$consumerDisplayName」#$consumerNodeId 的输入点「$inputKey」';
}

/// 单个可编辑输入（属于某个节点）。
class ComfyInputCandidate {
  final String nodeId;
  final String inputKey;
  final String classType;
  final String? metaTitle;
  final List<String> consumerKeys;
  final List<ComfyConsumerLink> consumers;
  final dynamic defaultValue;
  final ComfyWidgetKind suggestedWidget;
  final bool suggestSelect;
  final bool suggestEnabled;

  const ComfyInputCandidate({
    required this.nodeId,
    required this.inputKey,
    required this.classType,
    this.metaTitle,
    this.consumerKeys = const [],
    this.consumers = const [],
    required this.defaultValue,
    required this.suggestedWidget,
    this.suggestSelect = true,
    this.suggestEnabled = true,
  });

  String get fingerprint => '$nodeId::$inputKey';

  String get fieldSuggestedLabel {
    final key = inputKey.toLowerCase();
    if (key == 'image') return '图片';
    if (key == 'audio') return '音频';
    if (key == 'video' || key == 'file') return '视频';
    if (key == 'value') return '值';
    if (key == 'text' || key == 'prompt') return '文本';
    if (key == 'seed' || key == 'noise_seed') return '种子';
    if (key == 'steps') return '步数';
    if (key == 'cfg') return 'CFG';
    if (key == 'width') return '宽度';
    if (key == 'height') return '高度';
    if (key == 'fps') return '帧率';
    return inputKey;
  }

  String get defaultPreview {
    final v = defaultValue;
    if (v == null) return '';
    final s = v.toString();
    if (s.length <= 60) return s;
    return '${s.substring(0, 57)}...';
  }
}

/// 发现结果：按节点归组。
class ComfyNodeGroup {
  final String nodeId;
  final String classType;
  final String? metaTitle;
  final List<String> consumerKeys;
  final List<ComfyConsumerLink> consumers;
  final List<ComfyInputCandidate> inputs;
  final bool bypassable;

  const ComfyNodeGroup({
    required this.nodeId,
    required this.classType,
    this.metaTitle,
    this.consumerKeys = const [],
    this.consumers = const [],
    required this.inputs,
    this.bypassable = false,
  });

  bool get suggestSelect => inputs.any((e) => e.suggestSelect);
  bool get suggestEnabled => inputs.every((e) => e.suggestEnabled);

  /// 同类归组：图 → 音频 → 视频 → 常量/Primitive → 其它，组内按显示名排序。
  static int sortCategory(String classType) {
    final ct = classType.toLowerCase();
    if (ct.contains('loadimage')) return 0;
    if (ct.contains('loadaudio')) return 1;
    if (ct.contains('loadvideo')) return 2;
    if (ct.contains('primitive') || ct.contains('constant')) return 3;
    return 4;
  }

  /// 生成面板分区标题。
  static String categoryLabel(int category) => switch (category) {
        0 => '图片',
        1 => '音频',
        2 => '视频',
        3 => '参数',
        _ => '其它',
      };

  /// 媒体类分区默认展开；参数/其它默认收起，减少滚动。
  static bool categoryExpandedByDefault(int category) => category <= 2;

  static int compareByName(
    String classTypeA,
    String labelA,
    String classTypeB,
    String labelB,
  ) {
    final ca = sortCategory(classTypeA);
    final cb = sortCategory(classTypeB);
    if (ca != cb) return ca.compareTo(cb);
    return labelA.toLowerCase().compareTo(labelB.toLowerCase());
  }

  static List<ComfyNodeGroup> sortedByName(List<ComfyNodeGroup> groups) {
    final list = List<ComfyNodeGroup>.of(groups);
    list.sort(
      (a, b) => compareByName(
        a.classType,
        a.suggestedLabel,
        b.classType,
        b.suggestedLabel,
      ),
    );
    return list;
  }

  /// 生成面板：先按记忆顺序，其余按名称归类插入末尾。
  static List<ComfyExposedNode> orderExposedNodes(
    List<ComfyExposedNode> nodes, {
    List<String>? rememberedOrder,
    String Function(ComfyExposedNode node)? displayLabelOf,
  }) {
    String labelOf(ComfyExposedNode n) =>
        displayLabelOf?.call(n) ?? n.label;

    final byId = {for (final n in nodes) n.nodeId: n};
    final result = <ComfyExposedNode>[];
    if (rememberedOrder != null) {
      for (final id in rememberedOrder) {
        final n = byId.remove(id);
        if (n != null) result.add(n);
      }
    }
    final rest = byId.values.toList()
      ..sort(
        (a, b) => compareByName(
          a.classType,
          labelOf(a),
          b.classType,
          labelOf(b),
        ),
      );
    result.addAll(rest);
    return result;
  }

  bool get _isMediaLoader {
    final ct = classType.toLowerCase();
    return ct.contains('loadimage') ||
        ct.contains('loadaudio') ||
        ct.contains('loadvideo');
  }

  bool get _titleIsUselessConstant {
    final title = metaTitle?.trim() ?? '';
    if (title.isEmpty) return true;
    return RegExp(
      r'^(integer constant|float constant|int constant|constant)$',
      caseSensitive: false,
    ).hasMatch(title);
  }

  /// 节点名 + 自动推断的下游点位编号，如「Load Video · 参考图 1」。
  static String labelWithPins(String baseName, List<ComfyConsumerLink> consumers) {
    final base = baseName.trim();
    if (consumers.isEmpty) return base.isEmpty ? '未命名' : base;
    final pins = <String>[];
    for (final c in consumers) {
      final friendly = c.pinLabel;
      // 优先友好编号；没有编号信息时用原始点位名
      final text = friendly;
      if (!pins.contains(text)) pins.add(text);
    }
    final pinPart = pins.join(' / ');
    if (base.isEmpty) return pinPart;
    // 已含点位信息则不重复追加
    if (pins.any((p) => base.contains(p)) ||
        consumers.any((c) => base.contains(c.inputKey))) {
      return base;
    }
    return '$base · $pinPart';
  }

  String get suggestedLabel {
    // 基础名：节点自身标题（如 Load Video / Float (duration)）
    String base;
    final title = metaTitle?.trim();
    if (title != null && title.isNotEmpty && !_titleIsUselessConstant) {
      base = title;
    } else {
      final ct = classType.toLowerCase();
      if (ct.contains('loadimage')) {
        base = 'Load Image';
      } else if (ct.contains('loadaudio')) {
        base = 'Load Audio';
      } else if (ct.contains('loadvideo')) {
        base = 'Load Video';
      } else if (ct.contains('primitivestring')) {
        base = '文本 / 提示词';
      } else if (ct.contains('primitivefloat')) {
        base = '浮点参数';
      } else if (ct.contains('primitiveint') || ct.contains('intconstant')) {
        base = '整数参数';
      } else {
        base = classType;
      }
      if (consumerKeys.isNotEmpty && !_isMediaLoader) {
        final key = consumerKeys.first;
        final mapped = mapConsumerKey(key);
        if (mapped != null && mapped != key) {
          base = '$mapped（$key）';
        }
      }
    }
    // 媒体等有下游点位时，自动拼编号
    if (consumers.isNotEmpty) {
      return labelWithPins(base, consumers);
    }
    return base;
  }

  String get technicalLabel {
    final base = '$nodeId · $classType';
    if (consumers.isEmpty) return base;
    return '$base · ${consumers.map((c) => c.detailLine).join('；')}';
  }

  /// 生成面板副标题：按行列出每个下游输入点。
  String get consumerSummary {
    if (consumers.isEmpty) return '';
    return consumers.map((c) => c.shortLabel).join('\n');
  }

  /// 返回友好中文名；无法识别时返回 null（勿把 raw 当友好名）。
  static String? mapConsumerKey(String raw) {
    final k = raw.toLowerCase().trim();
    if (k.isEmpty) return null;
    if (k == 'prompt' || k.endsWith('.prompt')) return '提示词';
    if (k == 'width') return '宽度';
    if (k == 'height') return '高度';
    if (k == 'length' || k.contains('duration')) return '时长 / 帧长';

    final numMatch = RegExp(r'(\d+)').firstMatch(k);
    final n = numMatch?.group(1);

    if (k.contains('audio') ||
        RegExp(r'(^|[_.-])aud(io)?([_.-]|$)').hasMatch(k)) {
      if (k.contains('ref') ||
          k.contains('audio') ||
          k.contains('aud')) {
        return n == null ? '参考音频' : '参考音频 $n';
      }
    }
    if (k.contains('video') ||
        RegExp(r'(^|[_.-])vid(eo)?([_.-]|$)').hasMatch(k)) {
      if (k.contains('ref') ||
          k.contains('video') ||
          k.contains('vid')) {
        return n == null ? '参考视频' : '参考视频 $n';
      }
    }
    if (k.contains('image') ||
        RegExp(r'(^|[_.-])img([_.-]|$)').hasMatch(k)) {
      return n == null ? '参考图' : '参考图 $n';
    }

    if (k.startsWith('values.')) return '参数 ${k.substring(7)}';
    return null;
  }
}

/// 节点内一个暴露给用户的输入字段。
class ComfyExposedField {
  final String id;
  final String label;
  final String nodeId;
  final String inputKey;
  final ComfyWidgetKind widget;
  final List<String>? choices;

  const ComfyExposedField({
    required this.id,
    required this.label,
    required this.nodeId,
    required this.inputKey,
    required this.widget,
    this.choices,
  });

  String get fingerprint => '$nodeId::$inputKey';

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'nodeId': nodeId,
        'inputKey': inputKey,
        'widget': widget.name,
        if (choices != null && choices!.isNotEmpty) 'choices': choices,
      };

  factory ComfyExposedField.fromJson(Map<String, dynamic> json) {
    final rawChoices = json['choices'];
    return ComfyExposedField(
      id: json['id'] as String? ??
          '${json['nodeId']}_${json['inputKey']}',
      label: json['label'] as String? ?? json['inputKey'] as String? ?? '',
      nodeId: '${json['nodeId']}',
      inputKey: json['inputKey'] as String? ?? '',
      widget: comfyWidgetFromName(json['widget'] as String?),
      choices: rawChoices is List
          ? rawChoices.map((e) => e.toString()).toList()
          : null,
    );
  }
}

/// 暴露给用户的整节点（使能 / Bypass 以节点为单位）。
class ComfyExposedNode {
  final String nodeId;
  final String label;
  final String classType;
  final bool defaultEnabled;
  final bool bypassWhenDisabled;
  final List<ComfyExposedField> fields;

  const ComfyExposedNode({
    required this.nodeId,
    required this.label,
    required this.classType,
    this.defaultEnabled = true,
    this.bypassWhenDisabled = false,
    this.fields = const [],
  });

  Map<String, dynamic> toJson() => {
        'nodeId': nodeId,
        'label': label,
        'classType': classType,
        'defaultEnabled': defaultEnabled,
        'bypassWhenDisabled': bypassWhenDisabled,
        'fields': fields.map((e) => e.toJson()).toList(),
      };

  factory ComfyExposedNode.fromJson(Map<String, dynamic> json) {
    final fieldsRaw = json['fields'];
    final fields = <ComfyExposedField>[];
    if (fieldsRaw is List) {
      for (final e in fieldsRaw) {
        if (e is Map) {
          fields.add(
            ComfyExposedField.fromJson(Map<String, dynamic>.from(e)),
          );
        }
      }
    }
    final ct = json['classType'] as String? ?? '';
    return ComfyExposedNode(
      nodeId: '${json['nodeId']}',
      label: json['label'] as String? ?? ct,
      classType: ct,
      defaultEnabled: json['defaultEnabled'] as bool? ?? true,
      bypassWhenDisabled: json['bypassWhenDisabled'] as bool? ??
          _guessBypassable(ct),
      fields: fields,
    );
  }

  static bool _guessBypassable(String classType) {
    final ct = classType.toLowerCase();
    return ct.contains('loadimage') ||
        ct.contains('loadaudio') ||
        ct.contains('loadvideo');
  }
}

/// 项目级 Workflow 模板（暴露配置跟模板走，不跟 URL）。
class ComfyTemplate {
  final String id;
  final String name;
  final String workflowFile;
  final String? workflowHash;
  final List<ComfyExposedNode> nodes;
  final String? templatePath;

  const ComfyTemplate({
    required this.id,
    required this.name,
    required this.workflowFile,
    this.workflowHash,
    this.nodes = const [],
    this.templatePath,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'workflow': workflowFile,
        if (workflowHash != null) 'workflowHash': workflowHash,
        'nodes': nodes.map((n) => n.toJson()).toList(),
      };

  factory ComfyTemplate.fromJson(
    Map<String, dynamic> json, {
    String? templatePath,
  }) {
    final nodes = <ComfyExposedNode>[];
    final nodesRaw = json['nodes'];
    if (nodesRaw is List) {
      for (final e in nodesRaw) {
        if (e is Map) {
          nodes.add(ComfyExposedNode.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    }
    // 兼容旧 action：profiles → 取 _default 或首个非空
    if (nodes.isEmpty) {
      final profilesRaw = json['profiles'];
      if (profilesRaw is Map) {
        List<ComfyExposedNode>? pick;
        for (final e in profilesRaw.entries) {
          if (e.key.toString() == '_default' && e.value is List) {
            pick = _nodesFromList(e.value as List);
            break;
          }
        }
        if (pick == null) {
          for (final e in profilesRaw.values) {
            if (e is List && e.isNotEmpty) {
              pick = _nodesFromList(e);
              break;
            }
          }
        }
        if (pick != null) nodes.addAll(pick);
      }
      if (nodes.isEmpty) {
        nodes.addAll(_parseLegacyExposed(json));
      }
    }

    return ComfyTemplate(
      id: json['id'] as String? ??
          'tpl_${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? '未命名模板',
      workflowFile: json['workflow'] as String? ?? '',
      workflowHash: json['workflowHash'] as String?,
      nodes: nodes,
      templatePath: templatePath,
    );
  }

  static List<ComfyExposedNode> _nodesFromList(List raw) {
    final out = <ComfyExposedNode>[];
    for (final n in raw) {
      if (n is Map) {
        out.add(ComfyExposedNode.fromJson(Map<String, dynamic>.from(n)));
      }
    }
    return out;
  }

  static List<ComfyExposedNode> _parseLegacyExposed(Map<String, dynamic> json) {
    final exposedRaw = json['exposed'];
    if (exposedRaw is! List) return const [];
    final byNode = <String, List<ComfyExposedField>>{};
    final enabled = <String, bool>{};
    final labels = <String, String>{};
    for (final e in exposedRaw) {
      if (e is! Map) continue;
      final f = ComfyExposedField.fromJson(Map<String, dynamic>.from(e));
      byNode.putIfAbsent(f.nodeId, () => []).add(f);
      final defEn = e['defaultEnabled'] as bool? ?? true;
      enabled[f.nodeId] = (enabled[f.nodeId] ?? true) && defEn;
      labels.putIfAbsent(f.nodeId, () => f.label);
    }
    return [
      for (final entry in byNode.entries)
        ComfyExposedNode(
          nodeId: entry.key,
          label: labels[entry.key] ?? entry.key,
          classType: '',
          defaultEnabled: enabled[entry.key] ?? true,
          bypassWhenDisabled: false,
          fields: entry.value,
        ),
    ];
  }

  ComfyTemplate copyWith({
    String? id,
    String? name,
    String? workflowFile,
    String? workflowHash,
    List<ComfyExposedNode>? nodes,
    String? templatePath,
    bool clearHash = false,
  }) {
    return ComfyTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      workflowFile: workflowFile ?? this.workflowFile,
      workflowHash: clearHash ? null : (workflowHash ?? this.workflowHash),
      nodes: nodes ?? this.nodes,
      templatePath: templatePath ?? this.templatePath,
    );
  }

  static String prettyJson(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);
}

/// 单个 URL 对模板的选用。
class ComfyServerBinding {
  final List<String> templateIds;
  final String? selectedTemplateId;

  const ComfyServerBinding({
    this.templateIds = const [],
    this.selectedTemplateId,
  });

  ComfyServerBinding copyWith({
    List<String>? templateIds,
    String? selectedTemplateId,
    bool clearSelected = false,
  }) {
    return ComfyServerBinding(
      templateIds: templateIds ?? this.templateIds,
      selectedTemplateId: clearSelected
          ? null
          : (selectedTemplateId ?? this.selectedTemplateId),
    );
  }

  Map<String, dynamic> toJson() => {
        'templateIds': templateIds,
        if (selectedTemplateId != null) 'selectedTemplateId': selectedTemplateId,
      };

  factory ComfyServerBinding.fromJson(Map<String, dynamic> json) {
    final idsRaw = json['templateIds'];
    final ids = <String>[];
    if (idsRaw is List) {
      for (final e in idsRaw) {
        ids.add(e.toString());
      }
    }
    return ComfyServerBinding(
      templateIds: ids,
      selectedTemplateId: json['selectedTemplateId'] as String?,
    );
  }
}

/// 全项目 URL → 模板绑定表。
class ComfyBindings {
  final Map<String, ComfyServerBinding> byServer;

  const ComfyBindings({this.byServer = const {}});

  ComfyServerBinding forServer(String serverId) =>
      byServer[serverId] ?? const ComfyServerBinding();

  ComfyBindings withServer(String serverId, ComfyServerBinding binding) {
    final next = Map<String, ComfyServerBinding>.from(byServer);
    next[serverId] = binding;
    return ComfyBindings(byServer: next);
  }

  /// 从所有绑定中移除某模板 id。
  ComfyBindings withoutTemplate(String templateId) {
    final next = <String, ComfyServerBinding>{};
    for (final e in byServer.entries) {
      final ids =
          e.value.templateIds.where((id) => id != templateId).toList();
      final sel = e.value.selectedTemplateId == templateId
          ? (ids.isNotEmpty ? ids.first : null)
          : e.value.selectedTemplateId;
      next[e.key] = ComfyServerBinding(
        templateIds: ids,
        selectedTemplateId: sel,
      );
    }
    return ComfyBindings(byServer: next);
  }

  Map<String, dynamic> toJson() => {
        for (final e in byServer.entries) e.key: e.value.toJson(),
      };

  factory ComfyBindings.fromJson(Map<String, dynamic> json) {
    final map = <String, ComfyServerBinding>{};
    for (final e in json.entries) {
      if (e.value is Map) {
        map[e.key] = ComfyServerBinding.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        );
      }
    }
    return ComfyBindings(byServer: map);
  }
}
