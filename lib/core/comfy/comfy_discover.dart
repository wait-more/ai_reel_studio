import 'comfy_models.dart';

/// 从 ComfyUI API Format workflow 扫描可编辑输入。
class ComfyDiscover {
  ComfyDiscover._();

  /// 「人常改」的字段；向导「仅常见」筛选用。媒体加载器 / Primitive 一律算常见。
  static bool isCommonCandidate(ComfyInputCandidate c) {
    final ct = c.classType.toLowerCase();
    final key = c.inputKey.toLowerCase();

    if (_isLoaderClass(ct)) return true;
    if (_isPrimitiveOrConstant(ct) && (key == 'value' || key == 'text')) {
      return true;
    }
    if (ct.contains('cliptextencode') && key == 'text') return true;
    if (ct.contains('ksampler') || ct.contains('randomnoise')) {
      return const {
        'seed',
        'noise_seed',
        'steps',
        'cfg',
        'denoise',
        'sampler_name',
        'scheduler',
      }.contains(key);
    }
    if (key == 'width' ||
        key == 'height' ||
        key == 'length' ||
        key == 'fps' ||
        key == 'prompt' ||
        key.contains('prompt')) {
      return true;
    }
    if (ct.contains('checkpoint') && key == 'ckpt_name') return true;
    if (ct.contains('loraloader') &&
        (key == 'lora_name' || key == 'strength_model')) {
      return true;
    }
    // 下游接到提示词/宽高/参考槽的节点也算常见
    for (final ck in c.consumerKeys) {
      final l = ck.toLowerCase();
      if (l == 'prompt' ||
          l == 'width' ||
          l == 'height' ||
          l == 'length' ||
          l.contains('ref_image') ||
          l.contains('ref_audio') ||
          l.contains('ref_video') ||
          l.startsWith('values.')) {
        return true;
      }
    }
    return false;
  }

  static bool _isLoaderClass(String ct) {
    return ct.contains('loadimage') ||
        ct.contains('loadaudio') ||
        ct.contains('loadvideo') ||
        ct.contains('loadimageMask'.toLowerCase()) ||
        ct == 'loadimagemask';
  }

  static bool _isPrimitiveOrConstant(String ct) {
    return ct.contains('primitive') ||
        ct.contains('intconstant') ||
        ct.contains('floatconstant') ||
        ct.contains('stringconstant') ||
        ct.contains('constant');
  }

  static List<ComfyInputCandidate> discover(Map<String, dynamic> workflow) {
    return [
      for (final g in discoverNodes(workflow)) ...g.inputs,
    ];
  }

  /// 按节点归组的可编辑输入。
  static List<ComfyNodeGroup> discoverNodes(Map<String, dynamic> workflow) {
    final flat = _discoverFlat(workflow);
    final order = <String>[];
    final byNode = <String, List<ComfyInputCandidate>>{};
    for (final c in flat) {
      if (!byNode.containsKey(c.nodeId)) order.add(c.nodeId);
      byNode.putIfAbsent(c.nodeId, () => []).add(c);
    }
    return [
      for (final id in order)
        ComfyNodeGroup(
          nodeId: id,
          classType: byNode[id]!.first.classType,
          metaTitle: byNode[id]!.first.metaTitle,
          consumerKeys: byNode[id]!.first.consumerKeys,
          consumers: byNode[id]!.first.consumers,
          inputs: byNode[id]!,
          bypassable: _isLoaderClass(byNode[id]!.first.classType.toLowerCase()),
        ),
    ];
  }

  /// 运行时：查某节点接到了谁（用于生成面板副标题）。
  static List<ComfyConsumerLink> consumersOf(
    Map<String, dynamic> workflow,
    String nodeId,
  ) {
    return buildConsumerLinks(workflow)[nodeId] ?? const [];
  }

  static bool isCommonNode(ComfyNodeGroup g) => g.suggestSelect;

  static List<ComfyInputCandidate> _discoverFlat(Map<String, dynamic> workflow) {
    final consumersBySrc = buildConsumerLinks(workflow);
    final out = <ComfyInputCandidate>[];
    final entries = workflow.entries.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a.key) ?? 0;
        final bi = int.tryParse(b.key) ?? 0;
        if (ai != bi) return ai.compareTo(bi);
        return a.key.compareTo(b.key);
      });

    for (final entry in entries) {
      final nodeId = entry.key;
      final node = entry.value;
      if (node is! Map) continue;
      final classType = node['class_type']?.toString() ?? 'Unknown';
      final metaTitle = _metaTitle(node);
      final inputs = node['inputs'];
      if (inputs is! Map) continue;

      final consumers = consumersBySrc[nodeId] ?? const <ComfyConsumerLink>[];
      final consumerKeys = consumers.map((c) => c.inputKey).toList();

      for (final input in inputs.entries) {
        final key = input.key.toString();
        final value = input.value;
        if (_isNodeLink(value)) continue;

        final widget = _inferWidget(classType, key, value);
        final candidate = ComfyInputCandidate(
          nodeId: nodeId,
          inputKey: key,
          classType: classType,
          metaTitle: metaTitle,
          consumerKeys: consumerKeys,
          consumers: consumers,
          defaultValue: value,
          suggestedWidget: widget,
          suggestSelect: false,
          suggestEnabled: true,
        );
        final isMediaLoader =
            widget.isMedia && _isLoaderClass(classType.toLowerCase());
        final emptyMedia = isMediaLoader &&
            (value == null || '$value'.trim().isEmpty);

        out.add(
          ComfyInputCandidate(
            nodeId: nodeId,
            inputKey: key,
            classType: classType,
            metaTitle: metaTitle,
            consumerKeys: consumerKeys,
            consumers: consumers,
            defaultValue: value,
            suggestedWidget: widget,
            suggestSelect: isCommonCandidate(candidate) || isMediaLoader,
            suggestEnabled: !emptyMedia,
          ),
        );
      }
    }
    return out;
  }

  static String? _metaTitle(Map node) {
    final meta = node['_meta'];
    if (meta is Map && meta['title'] != null) {
      return meta['title'].toString();
    }
    return null;
  }

  /// srcNodeId → 下游消费链接（含消费节点标题与输入名）。
  /// 会穿透一层 Reroute / 纯转发类节点。
  static Map<String, List<ComfyConsumerLink>> buildConsumerLinks(
    Map<String, dynamic> workflow,
  ) {
    final direct = <String, List<ComfyConsumerLink>>{};
    for (final entry in workflow.entries) {
      final consumerId = entry.key;
      final node = entry.value;
      if (node is! Map) continue;
      final classType = node['class_type']?.toString() ?? 'Unknown';
      final title = _metaTitle(node);
      final inputs = node['inputs'];
      if (inputs is! Map) continue;
      for (final input in inputs.entries) {
        final value = input.value;
        if (!_isNodeLink(value)) continue;
        final src = '${(value as List)[0]}';
        direct.putIfAbsent(src, () => <ComfyConsumerLink>[]).add(
          ComfyConsumerLink(
            consumerNodeId: consumerId,
            consumerClassType: classType,
            consumerTitle: title,
            inputKey: input.key.toString(),
          ),
        );
      }
    }

    // 穿透 Reroute：若 A→Reroute→B.input，则 A 也记 B.input
    final out = <String, List<ComfyConsumerLink>>{};
    for (final e in direct.entries) {
      out.putIfAbsent(e.key, () => <ComfyConsumerLink>[]).addAll(e.value);
    }
    for (final e in direct.entries) {
      final src = e.key;
      for (final link in e.value) {
        if (!_isPassthroughClass(link.consumerClassType)) continue;
        final next = direct[link.consumerNodeId];
        if (next == null || next.isEmpty) continue;
        out.putIfAbsent(src, () => <ComfyConsumerLink>[]).addAll(next);
      }
    }

    // 去重，并按输入点位名排序，方便对照 ref_image_1 / 2 / 3
    for (final e in out.entries) {
      final seen = <String>{};
      e.value.retainWhere((c) {
        final k = '${c.consumerNodeId}::${c.inputKey}';
        return seen.add(k);
      });
      e.value.sort((a, b) => a.inputKey.compareTo(b.inputKey));
    }
    return out;
  }

  static bool _isPassthroughClass(String classType) {
    final ct = classType.toLowerCase();
    return ct == 'reroute' ||
        ct.contains('reroute') ||
        ct == 'previewany' ||
        ct.contains('getnodeset') ||
        ct.contains('setnode');
  }

  /// 形如 `["3", 0]` 的节点连线。
  static bool _isNodeLink(dynamic value) {
    if (value is! List || value.length < 2) return false;
    final a = value[0];
    final b = value[1];
    final nodeOk = a is String || a is num;
    final slotOk = b is int || (b is num && b == b.roundToDouble());
    return nodeOk && slotOk;
  }

  static ComfyWidgetKind _inferWidget(
    String classType,
    String key,
    dynamic value,
  ) {
    final ct = classType.toLowerCase();
    final k = key.toLowerCase();

    if (ct.contains('loadaudio') || k == 'audio') {
      if (value is String || ct.contains('loadaudio')) {
        return ComfyWidgetKind.audio;
      }
    }
    if (ct.contains('loadvideo') && (k == 'file' || k == 'video' || k == 'image')) {
      return ComfyWidgetKind.video;
    }
    if (ct.contains('loadimage') || (k == 'image' && value is String)) {
      return ComfyWidgetKind.image;
    }

    if (ct.contains('primitivefloat') || ct.contains('floatconstant')) {
      return ComfyWidgetKind.float;
    }
    if (ct.contains('primitiveint') || ct.contains('intconstant')) {
      return ComfyWidgetKind.int;
    }
    if (ct.contains('primitiveboolean') || ct.contains('boolconstant')) {
      return ComfyWidgetKind.bool;
    }

    if (value is bool) return ComfyWidgetKind.bool;
    if (value is int) return ComfyWidgetKind.int;
    if (value is double) return ComfyWidgetKind.float;
    if (value is num) {
      return value == value.roundToDouble()
          ? ComfyWidgetKind.int
          : ComfyWidgetKind.float;
    }
    if (value is String) {
      if (ct.contains('cliptextencode') && k == 'text') {
        return ComfyWidgetKind.multiline;
      }
      if (ct.contains('primitivestring') ||
          ct.contains('stringmultiline') ||
          k == 'prompt' ||
          k == 'text' ||
          k == 'value') {
        if (value.contains('\n') ||
            value.length > 60 ||
            ct.contains('multiline') ||
            ct.contains('primitivestringmultiline')) {
          return ComfyWidgetKind.multiline;
        }
      }
      if (value.contains('\n') || value.length > 60) {
        return ComfyWidgetKind.multiline;
      }
      if (k.endsWith('_name') || k == 'sampler_name' || k == 'scheduler') {
        return ComfyWidgetKind.choice;
      }
      return ComfyWidgetKind.text;
    }
    return ComfyWidgetKind.text;
  }

  /// 合并表单值；[enabledByNode] 以节点为单位。禁用且 bypassable 的节点会被摘掉。
  static Map<String, dynamic> applyExposedValues(
    Map<String, dynamic> workflow,
    List<ComfyExposedNode> nodes,
    Map<String, dynamic> values, {
    Map<String, bool>? enabledByNode,
  }) {
    final copy = _deepCopyMap(workflow);

    for (final node in nodes) {
      final isOn = enabledByNode?[node.nodeId] ?? node.defaultEnabled;
      if (!isOn) continue;
      for (final field in node.fields) {
        if (!values.containsKey(field.id)) continue;
        final n = copy[field.nodeId];
        if (n is! Map) continue;
        final inputs = n['inputs'];
        if (inputs is! Map) continue;
        inputs[field.inputKey] = _coerceValue(field.widget, values[field.id]);
      }
    }

    for (final node in nodes) {
      final isOn = enabledByNode?[node.nodeId] ?? node.defaultEnabled;
      if (isOn) continue;
      if (!node.bypassWhenDisabled) continue;
      _bypassNode(copy, node.nodeId);
    }

    return copy;
  }

  /// 删除节点，并清除其它节点里指向它的输入（可选参考口直接拿掉）。
  static void _bypassNode(Map<String, dynamic> workflow, String nodeId) {
    workflow.remove(nodeId);
    for (final entry in workflow.entries) {
      final node = entry.value;
      if (node is! Map) continue;
      final inputs = node['inputs'];
      if (inputs is! Map) continue;
      final removeKeys = <String>[];
      for (final input in inputs.entries) {
        final value = input.value;
        if (!_isNodeLink(value)) continue;
        if ('${(value as List)[0]}' == nodeId) {
          removeKeys.add(input.key.toString());
        }
      }
      for (final k in removeKeys) {
        inputs.remove(k);
      }
    }
  }

  static dynamic _coerceValue(ComfyWidgetKind widget, dynamic raw) {
    switch (widget) {
      case ComfyWidgetKind.int:
        if (raw is int) return raw;
        if (raw is num) return raw.toInt();
        return int.tryParse('$raw') ?? 0;
      case ComfyWidgetKind.float:
        if (raw is double) return raw;
        if (raw is num) return raw.toDouble();
        return double.tryParse('$raw') ?? 0.0;
      case ComfyWidgetKind.bool:
        if (raw is bool) return raw;
        final s = '$raw'.toLowerCase();
        return s == 'true' || s == '1' || s == 'yes';
      case ComfyWidgetKind.image:
      case ComfyWidgetKind.audio:
      case ComfyWidgetKind.video:
      case ComfyWidgetKind.text:
      case ComfyWidgetKind.multiline:
      case ComfyWidgetKind.choice:
        return raw?.toString() ?? '';
    }
  }

  static Map<String, dynamic> _deepCopyMap(Map<String, dynamic> src) {
    final out = <String, dynamic>{};
    for (final e in src.entries) {
      out[e.key] = _deepCopyValue(e.value);
    }
    return out;
  }

  static dynamic _deepCopyValue(dynamic v) {
    if (v is Map) {
      return {
        for (final e in v.entries) e.key.toString(): _deepCopyValue(e.value),
      };
    }
    if (v is List) {
      return v.map(_deepCopyValue).toList();
    }
    return v;
  }
}
