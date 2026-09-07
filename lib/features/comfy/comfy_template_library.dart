import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/comfy/comfy_models.dart';
import '../../core/comfy/comfy_template_store.dart';
import '../../core/providers.dart';
import '../../core/toast.dart';
import 'comfy_import_wizard.dart';

/// 独立模板库：导入 / 重新配置 / 删除（不绑 URL）。
Future<void> showComfyTemplateLibrary(
  BuildContext context,
  WidgetRef ref,
) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _ComfyTemplateLibraryDialog(),
  ).then((_) {
    ref.read(comfyActionsTickProvider.notifier).state++;
  });
}

class _ComfyTemplateLibraryDialog extends ConsumerStatefulWidget {
  const _ComfyTemplateLibraryDialog();

  @override
  ConsumerState<_ComfyTemplateLibraryDialog> createState() =>
      _ComfyTemplateLibraryDialogState();
}

class _ComfyTemplateLibraryDialogState
    extends ConsumerState<_ComfyTemplateLibraryDialog> {
  List<ComfyTemplate> _templates = const [];
  ComfyBindings _bindings = const ComfyBindings();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ComfyTemplateStore.loadTemplates();
      final bindings = await ComfyTemplateStore.loadBindings();
      if (!mounted) return;
      setState(() {
        _templates = list;
        _bindings = bindings;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  String _refSummary(String templateId) {
    final names = <String>[];
    final servers = ref.read(comfyServersProvider);
    for (final e in _bindings.byServer.entries) {
      if (!e.value.templateIds.contains(templateId)) continue;
      String name = e.key;
      for (final s in servers) {
        if (s.id == e.key) {
          name = s.name;
          break;
        }
      }
      names.add(name);
    }
    if (names.isEmpty) return '未被任何 URL 绑定';
    return '已绑定：${names.join('、')}';
  }

  Future<void> _import() async {
    final t = await showComfyTemplateWizard(context);
    if (t == null) return;
    await _reload();
    if (mounted) showGlobalToast(context, '已保存模板「${t.name}」');
  }

  Future<void> _reconfigure(ComfyTemplate t) async {
    final updated = await showComfyTemplateWizard(context, existing: t);
    if (updated == null) return;
    await _reload();
    if (mounted) showGlobalToast(context, '已更新模板「${updated.name}」');
  }

  Future<void> _delete(ComfyTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板'),
        content: Text(
          '确定删除「${t.name}」？将移除模板文件，并从所有 URL 绑定中清除。',
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
    await ComfyTemplateStore.deleteTemplate(t);
    await _reload();
    if (mounted) showGlobalToast(context, '已删除模板');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Text(
                    'Workflow 模板库',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  FilledButton.tonalIcon(
                    onPressed: _import,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('导入'),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: _reload,
                    icon: const Icon(Icons.refresh, size: 18),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '在此管理模板的导入、暴露配置与删除。生成面板只负责把模板绑定到 URL。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(child: Text(_error!))
                      : _templates.isEmpty
                          ? Center(
                              child: Text(
                                '尚无模板。点击右上角「导入」添加 API JSON。',
                                style: TextStyle(color: cs.onSurfaceVariant),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _templates.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (context, i) {
                                final t = _templates[i];
                                return ListTile(
                                  title: Text(t.name),
                                  subtitle: Text(
                                    '${t.nodes.length} 个节点 · ${_refSummary(t.id)}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      TextButton(
                                        onPressed: () => _reconfigure(t),
                                        child: const Text('重新配置'),
                                      ),
                                      TextButton(
                                        onPressed: () => _delete(t),
                                        style: TextButton.styleFrom(
                                          foregroundColor: cs.error,
                                        ),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 从模板库多选，绑定到指定 URL。
Future<List<String>?> showBindTemplatesPicker(
  BuildContext context, {
  required List<ComfyTemplate> all,
  required Set<String> alreadyBound,
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (ctx) => _BindPickerDialog(
      all: all,
      alreadyBound: alreadyBound,
    ),
  );
}

class _BindPickerDialog extends StatefulWidget {
  const _BindPickerDialog({
    required this.all,
    required this.alreadyBound,
  });
  final List<ComfyTemplate> all;
  final Set<String> alreadyBound;

  @override
  State<_BindPickerDialog> createState() => _BindPickerDialogState();
}

class _BindPickerDialogState extends State<_BindPickerDialog> {
  late final Set<String> _picked;

  @override
  void initState() {
    super.initState();
    _picked = {};
  }

  @override
  Widget build(BuildContext context) {
    final candidates =
        widget.all.where((t) => !widget.alreadyBound.contains(t.id)).toList();
    return AlertDialog(
      title: const Text('绑定模板'),
      content: SizedBox(
        width: 420,
        height: 320,
        child: candidates.isEmpty
            ? const Center(child: Text('没有可绑定的模板（请先在模板库导入）'))
            : ListView(
                children: [
                  for (final t in candidates)
                    CheckboxListTile(
                      value: _picked.contains(t.id),
                      title: Text(t.name),
                      subtitle: Text('${t.nodes.length} 个节点'),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _picked.add(t.id);
                          } else {
                            _picked.remove(t.id);
                          }
                        });
                      },
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(context, _picked.toList()),
          child: const Text('绑定'),
        ),
      ],
    );
  }
}
