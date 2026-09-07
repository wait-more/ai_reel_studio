import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/comfy/comfy_discover.dart';
import '../../core/comfy/comfy_models.dart';
import '../../core/comfy/comfy_template_store.dart';

/// 导入或重新配置 Workflow 模板（不绑定 URL）。
Future<ComfyTemplate?> showComfyTemplateWizard(
  BuildContext context, {
  ComfyTemplate? existing,
}) {
  return showDialog<ComfyTemplate>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ComfyTemplateWizardDialog(existing: existing),
  );
}

class _ComfyTemplateWizardDialog extends StatefulWidget {
  const _ComfyTemplateWizardDialog({this.existing});
  final ComfyTemplate? existing;

  @override
  State<_ComfyTemplateWizardDialog> createState() =>
      _ComfyTemplateWizardDialogState();
}

class _ComfyTemplateWizardDialogState extends State<_ComfyTemplateWizardDialog> {
  final _nameCtrl = TextEditingController();

  Map<String, dynamic>? _workflow;
  List<ComfyNodeGroup> _groups = const [];
  final Map<String, bool> _selected = {};
  final Map<String, bool> _defaultEnabled = {};
  final Map<String, bool> _expanded = {};
  final Map<String, TextEditingController> _nodeLabelCtrls = {};
  final Map<String, TextEditingController> _fieldLabelCtrls = {};
  final Map<String, ComfyWidgetKind> _widgets = {};
  bool _commonOnly = false;
  bool _busy = false;
  String? _error;
  String? _sourceHint;

  @override
  void initState() {
    super.initState();
    final ex = widget.existing;
    if (ex != null) {
      _nameCtrl.text = ex.name;
      _loadExisting();
    }
  }

  Future<void> _loadExisting() async {
    final ex = widget.existing!;
    try {
      final wf = await ComfyTemplateStore.loadWorkflowMap(ex);
      _applyWorkflow(wf, preserveNodes: ex.nodes);
      setState(() => _sourceHint = ex.workflowFile);
    } catch (e) {
      setState(() => _error = '加载已有 workflow 失败：$e');
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _nodeLabelCtrls.values) {
      c.dispose();
    }
    for (final c in _fieldLabelCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _disposeMaps() {
    for (final c in _nodeLabelCtrls.values) {
      c.dispose();
    }
    for (final c in _fieldLabelCtrls.values) {
      c.dispose();
    }
    _nodeLabelCtrls.clear();
    _fieldLabelCtrls.clear();
    _selected.clear();
    _defaultEnabled.clear();
    _expanded.clear();
    _widgets.clear();
  }

  void _applyWorkflow(
    Map<String, dynamic> wf, {
    List<ComfyExposedNode>? preserveNodes,
  }) {
    _disposeMaps();

    final groups = ComfyDiscover.discoverNodes(wf);
    final preserved = {
      for (final n in preserveNodes ?? const <ComfyExposedNode>[]) n.nodeId: n,
    };

    for (final g in groups) {
      final prev = preserved[g.nodeId];
      _selected[g.nodeId] =
          prev != null || (preserveNodes == null && g.suggestSelect);
      _defaultEnabled[g.nodeId] = prev?.defaultEnabled ?? g.suggestEnabled;
      _expanded[g.nodeId] = false;
      _nodeLabelCtrls[g.nodeId] = TextEditingController(
        text: _preferLabel(prev?.label, g),
      );

      final prevFields = {
        for (final f in prev?.fields ?? const <ComfyExposedField>[])
          f.inputKey: f,
      };
      for (final input in g.inputs) {
        final pf = prevFields[input.inputKey];
        _widgets[input.fingerprint] = pf?.widget ?? input.suggestedWidget;
        _fieldLabelCtrls[input.fingerprint] = TextEditingController(
          text: pf?.label ?? input.fieldSuggestedLabel,
        );
      }
    }

    if (_nameCtrl.text.trim().isEmpty) {
      _nameCtrl.text = '生成模板';
    }

    setState(() {
      _workflow = wf;
      _groups = ComfyNodeGroup.sortedByName(groups);
      _error = null;
      if (preserveNodes == null) _commonOnly = false;
    });
  }

  /// 旧标签若缺编号，用「节点名 · 点位」补全。
  String _preferLabel(String? prev, ComfyNodeGroup g) {
    final p = prev?.trim() ?? '';
    if (p.isEmpty) return g.suggestedLabel;
    // 已是「名 · 编号」或含点位，保留
    if (p.contains(' · ') ||
        g.consumers.any((c) => p.contains(c.inputKey) || p.contains(c.pinLabel))) {
      return p;
    }
    // Load Video 等：保留原名并追加推断编号
    if (g.consumers.isNotEmpty) {
      return ComfyNodeGroup.labelWithPins(p, g.consumers);
    }
    return p;
  }

  Future<void> _pickJson() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: '选择 ComfyUI API Format JSON',
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        setState(() => _error = 'JSON 根节点必须是对象（API Format）');
        return;
      }
      Map<String, dynamic> wf;
      if (decoded['prompt'] is Map) {
        wf = Map<String, dynamic>.from(decoded['prompt'] as Map);
      } else if (decoded.values
          .every((v) => v is Map && v['class_type'] != null)) {
        wf = Map<String, dynamic>.from(decoded);
      } else if (decoded['nodes'] != null) {
        setState(() =>
            _error = '这看起来是 UI 格式，请在 ComfyUI 使用 Save (API Format)');
        return;
      } else {
        wf = Map<String, dynamic>.from(decoded);
      }

      if (_nameCtrl.text.trim().isEmpty ||
          _nameCtrl.text == '生成模板' ||
          _nameCtrl.text == '生成动作') {
        _nameCtrl.text = p.basenameWithoutExtension(path);
      }
      _applyWorkflow(wf, preserveNodes: widget.existing?.nodes);
      setState(() => _sourceHint = path);
    } catch (e) {
      setState(() => _error = '读取失败：$e');
    }
  }

  List<ComfyNodeGroup> get _visible {
    final source = !_commonOnly
        ? _groups
        : [
            ..._groups.where(ComfyDiscover.isCommonNode),
            ..._groups.where((g) {
              if (ComfyDiscover.isCommonNode(g)) return false;
              return _selected[g.nodeId] == true;
            }),
          ];
    return ComfyNodeGroup.sortedByName(source);
  }

  Future<void> _save() async {
    final wf = _workflow;
    if (wf == null) {
      setState(() => _error = '请先导入 API JSON');
      return;
    }
    final nodes = <ComfyExposedNode>[];
    for (final g in ComfyNodeGroup.sortedByName(_groups)) {
      if (_selected[g.nodeId] != true) continue;
      final fields = <ComfyExposedField>[];
      for (final input in g.inputs) {
        final label = _fieldLabelCtrls[input.fingerprint]?.text.trim();
        fields.add(
          ComfyExposedField(
            id: '${input.nodeId}_${input.inputKey}',
            label: (label == null || label.isEmpty)
                ? input.fieldSuggestedLabel
                : label,
            nodeId: input.nodeId,
            inputKey: input.inputKey,
            widget: _widgets[input.fingerprint] ?? input.suggestedWidget,
          ),
        );
      }
      if (fields.isEmpty) continue;
      final nodeLabel = _nodeLabelCtrls[g.nodeId]?.text.trim();
      nodes.add(
        ComfyExposedNode(
          nodeId: g.nodeId,
          label: (nodeLabel == null || nodeLabel.isEmpty)
              ? g.suggestedLabel
              : nodeLabel,
          classType: g.classType,
          defaultEnabled: _defaultEnabled[g.nodeId] ?? true,
          bypassWhenDisabled: g.bypassable,
          fields: fields,
        ),
      );
    }
    if (nodes.isEmpty) {
      setState(() => _error = '请至少勾选一个节点');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ex = widget.existing;
      final template = await ComfyTemplateStore.saveTemplate(
        name: _nameCtrl.text,
        workflow: wf,
        nodes: nodes,
        existingId: ex?.id,
        overwriteTemplatePath: ex?.templatePath,
        existingWorkflowFile: ex?.workflowFile,
      );
      if (!mounted) return;
      Navigator.of(context).pop(template);
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Text(
                    widget.existing == null ? '导入 Workflow 模板' : '重新配置模板',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: '模板名称',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _pickJson,
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: Text(_workflow == null ? '选择 JSON' : '更换 JSON'),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('仅常见'),
                    selected: _commonOnly,
                    onSelected: _workflow == null
                        ? null
                        : (v) => setState(() => _commonOnly = v),
                  ),
                ],
              ),
            ),
            if (_sourceHint != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  _sourceHint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(_error!, style: TextStyle(color: cs.error)),
              ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(
              child: _workflow == null
                  ? Center(
                      child: Text(
                        '请选择 ComfyUI API Format JSON',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final g in _visible) _buildGroup(g),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Text(
                    '勾选要暴露的节点；保存后进入模板库，需在生成面板绑定到 URL。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _busy || _workflow == null ? null : _save,
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('保存模板'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroup(ComfyNodeGroup g) {
    final cs = Theme.of(context).colorScheme;
    final selected = _selected[g.nodeId] == true;
    final expanded = _expanded[g.nodeId] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, 4, 12, expanded ? 12 : 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Checkbox(
                  value: selected,
                  onChanged: (v) =>
                      setState(() => _selected[g.nodeId] = v == true),
                ),
                IconButton(
                  tooltip: expanded ? '折叠' : '展开',
                  icon: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 22,
                  ),
                  onPressed: () =>
                      setState(() => _expanded[g.nodeId] = !expanded),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () =>
                        setState(() => _expanded[g.nodeId] = !expanded),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          g.suggestedLabel,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${g.nodeId} · ${g.classType}',
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (g.consumers.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              g.consumerSummary,
                              style: TextStyle(
                                fontSize: 11,
                                color: cs.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (g.bypassable)
                  Text(
                    '可 Bypass',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
              ],
            ),
            if (expanded && selected) ...[
              if (g.consumers.isNotEmpty) ...[
                const SizedBox(height: 4),
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: Text(
                    '下游输入点（同一节点用点位名区分）',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                ...g.consumers.map(
                  (c) => Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(left: 8, bottom: 4),
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
              const SizedBox(height: 8),
              TextField(
                controller: _nodeLabelCtrls[g.nodeId],
                decoration: InputDecoration(
                  labelText: '节点显示名',
                  helperText: g.consumers.isNotEmpty
                      ? '建议：${g.suggestedLabel}'
                      : null,
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('默认启用'),
                value: _defaultEnabled[g.nodeId] ?? true,
                onChanged: (v) =>
                    setState(() => _defaultEnabled[g.nodeId] = v),
              ),
              for (final input in g.inputs) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _fieldLabelCtrls[input.fingerprint],
                        decoration: InputDecoration(
                          labelText: '字段「${input.inputKey}」标签',
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 140,
                      child: DropdownButtonFormField<ComfyWidgetKind>(
                        value: _widgets[input.fingerprint] ??
                            input.suggestedWidget,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: '控件',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final w in ComfyWidgetKind.values)
                            DropdownMenuItem(
                              value: w,
                              child: Text(w.name),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _widgets[input.fingerprint] = v);
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
