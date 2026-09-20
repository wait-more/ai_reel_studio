import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'comfy/comfy_gen_session.dart';
import 'comfy/comfy_models.dart';
import 'comfy/comfy_template_store.dart';
import 'config.dart';
import 'providers.dart';
import 'toast.dart';

/// 编辑器选区 → 生成面板提示词字段的注入请求。
class ComfyPromptInjectRequest {
  final String serverId;
  final String templateId;
  final String fieldId;
  final String nodeId;
  final String text;
  final int nonce;

  const ComfyPromptInjectRequest({
    required this.serverId,
    required this.templateId,
    required this.fieldId,
    required this.nodeId,
    required this.text,
    required this.nonce,
  });
}

final comfyPromptInjectRequestProvider =
    StateProvider<ComfyPromptInjectRequest?>((ref) => null);

/// 上次填入目标（含展示文案），供右键「填入上次」快捷项。
final comfyPromptLastTargetProvider =
    StateProvider<ComfyPromptSendTarget?>((ref) => null);

/// 右键二级菜单里的固定填入路径，排在「填入上次」之后。
final comfyPromptShortcutsProvider =
    StateProvider<List<ComfyPromptSendTarget>>((ref) => const []);

class ComfyPromptSendTarget {
  final String serverId;
  final String templateId;
  final String fieldId;
  /// 如：`本地 · 定妆文生图 · 正向提示词`
  final String displayLabel;
  /// 用户起的名字，可为空。
  final String name;

  const ComfyPromptSendTarget({
    required this.serverId,
    required this.templateId,
    required this.fieldId,
    this.displayLabel = '',
    this.name = '',
  });

  ComfyPromptSendTarget copyWith({String? name}) {
    return ComfyPromptSendTarget(
      serverId: serverId,
      templateId: templateId,
      fieldId: fieldId,
      displayLabel: displayLabel,
      name: name ?? this.name,
    );
  }

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'templateId': templateId,
        'fieldId': fieldId,
        'displayLabel': displayLabel,
        'name': name,
      };

  factory ComfyPromptSendTarget.fromJson(Map<String, dynamic> json) =>
      ComfyPromptSendTarget(
        serverId: json['serverId']?.toString() ?? '',
        templateId: json['templateId']?.toString() ?? '',
        fieldId: json['fieldId']?.toString() ?? '',
        displayLabel: json['displayLabel']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
      );

  bool get isValid =>
      serverId.isNotEmpty && templateId.isNotEmpty && fieldId.isNotEmpty;
}

class ComfyPromptSendMemory {
  ComfyPromptSendMemory._();
  static const _kKey = 'comfy_prompt_send_target_v1';
  static const _kShortcuts = 'comfy_prompt_shortcuts_v1';

  static Future<ComfyPromptSendTarget?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw);
      if (map is! Map) return null;
      final t = ComfyPromptSendTarget.fromJson(Map<String, dynamic>.from(map));
      return t.isValid ? t : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(ComfyPromptSendTarget target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(target.toJson()));
    } catch (_) {}
  }

  static Future<List<ComfyPromptSendTarget>> loadShortcuts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kShortcuts);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final item in list)
          if (item is Map)
            ComfyPromptSendTarget.fromJson(Map<String, dynamic>.from(item)),
      ].where((t) => t.isValid).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  static Future<void> saveShortcuts(List<ComfyPromptSendTarget> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kShortcuts,
        jsonEncode(items.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }

  /// 启动时/进入编辑器时灌入 provider，供右键菜单同步读取。
  static Future<void> hydrateProvider(WidgetRef ref) async {
    final loaded = await load();
    final shortcuts = await loadShortcuts();
    ref.read(comfyPromptShortcutsProvider.notifier).state = shortcuts;
    if (loaded == null) {
      ref.read(comfyPromptLastTargetProvider.notifier).state = null;
      return;
    }
    var t = loaded;
    // 旧数据可能没有 displayLabel，尽量补全。
    if (t.displayLabel.trim().isEmpty) {
      try {
        final servers = AppConfig.instance.comfyServers;
        final templates = await ComfyTemplateStore.loadTemplates();
        ComfyServer? server;
        for (final s in servers) {
          if (s.id == t.serverId) {
            server = s;
            break;
          }
        }
        ComfyTemplate? template;
        for (final x in templates) {
          if (x.id == t.templateId) {
            template = x;
            break;
          }
        }
        if (server != null && template != null) {
          final srv = server;
          final tpl = template;
          for (final f in comfyPromptFieldsOf(tpl)) {
            if (f.id == t.fieldId) {
              t = ComfyPromptSendTarget(
                serverId: t.serverId,
                templateId: t.templateId,
                fieldId: t.fieldId,
                displayLabel: _displayLabelFor(
                  server: srv,
                  template: tpl,
                  field: f,
                ),
              );
              await save(t);
              break;
            }
          }
        }
      } catch (_) {}
    }
    ref.read(comfyPromptLastTargetProvider.notifier).state = t;
  }
}

int _promptFieldScore(ComfyExposedField f) {
  final s = '${f.label} ${f.inputKey}'.toLowerCase();
  var score = 0;
  if (f.widget == ComfyWidgetKind.multiline) score += 10;
  if (s.contains('prompt') || s.contains('提示')) score += 5;
  if (s.contains('positive') || s.contains('正向')) score += 4;
  if (s.contains('text') || s.contains('文本')) score += 2;
  return score;
}

/// 适合承接提示词的字段（多行优先，其次单行文本）。
List<ComfyExposedField> comfyPromptFieldsOf(ComfyTemplate template) {
  final list = <ComfyExposedField>[];
  for (final node in template.nodes) {
    for (final field in node.fields) {
      if (field.widget == ComfyWidgetKind.multiline ||
          field.widget == ComfyWidgetKind.text) {
        list.add(field);
      }
    }
  }
  list.sort((a, b) => _promptFieldScore(b).compareTo(_promptFieldScore(a)));
  return list;
}

String _fieldPickLabel(ComfyTemplate template, ComfyExposedField field) {
  String nodeLabel = field.nodeId;
  for (final n in template.nodes) {
    if (n.nodeId == field.nodeId) {
      nodeLabel = n.label;
      break;
    }
  }
  return '$nodeLabel · ${field.label}';
}

String _displayLabelFor({
  required ComfyServer server,
  required ComfyTemplate template,
  required ComfyExposedField field,
}) =>
    '${server.name} · ${template.name} · ${_fieldPickLabel(template, field)}';

Widget _shortcutMenuLabel(ComfyPromptSendTarget shortcut, TextStyle style) {
  final path = shortcut.displayLabel.trim();
  final name = shortcut.name.trim();
  final text = name.isEmpty ? path : '$name：$path';
  return Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: style,
  );
}

Widget _menuDivider(Color color) {
  return Divider(height: 1, thickness: 1, color: color.withValues(alpha: 0.16));
}

class _PromptFillPickResult {
  final ComfyServer server;
  final ComfyTemplate template;
  final ComfyExposedField field;

  const _PromptFillPickResult({
    required this.server,
    required this.template,
    required this.field,
  });
}

/// 单窗完成实例 → 模板 → 字段选择，顶部展示操作流程。
Future<_PromptFillPickResult?> _pickPromptFillTarget({
  required BuildContext context,
  required List<ComfyServer> servers,
  required List<ComfyTemplate> allTemplates,
  required ComfyBindings bindings,
  ComfyPromptSendTarget? last,
  String confirmLabel = '填入',
}) {
  return showDialog<_PromptFillPickResult>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => _PromptFillPickerDialog(
      servers: servers,
      allTemplates: allTemplates,
      bindings: bindings,
      last: last,
      confirmLabel: confirmLabel,
    ),
  );
}

/// 设置页添加快捷路径：选出实例 / 模板 / 字段，不立即填入。
Future<ComfyPromptSendTarget?> pickComfyPromptShortcut(
  BuildContext context,
) async {
  final servers = AppConfig.instance.comfyServers
      .where((s) => s.enabled)
      .toList(growable: false);
  if (servers.isEmpty) {
    showGlobalToast(context, '请先在设置中启用至少一个 Comfy 实例');
    return null;
  }
  final templates = await ComfyTemplateStore.loadTemplates();
  final bindings = await ComfyTemplateStore.loadBindings();
  if (!context.mounted) return null;
  if (templates.isEmpty) {
    showGlobalToast(context, '还没有模板，请先在生成面板导入');
    return null;
  }
  final picked = await _pickPromptFillTarget(
    context: context,
    servers: servers,
    allTemplates: templates,
    bindings: bindings,
    confirmLabel: '添加',
  );
  if (picked == null) return null;
  return ComfyPromptSendTarget(
    serverId: picked.server.id,
    templateId: picked.template.id,
    fieldId: picked.field.id,
    displayLabel: _displayLabelFor(
      server: picked.server,
      template: picked.template,
      field: picked.field,
    ),
  );
}

class _PromptFillPickerDialog extends StatefulWidget {
  final List<ComfyServer> servers;
  final List<ComfyTemplate> allTemplates;
  final ComfyBindings bindings;
  final ComfyPromptSendTarget? last;
  final String confirmLabel;

  const _PromptFillPickerDialog({
    required this.servers,
    required this.allTemplates,
    required this.bindings,
    this.last,
    this.confirmLabel = '填入',
  });

  @override
  State<_PromptFillPickerDialog> createState() =>
      _PromptFillPickerDialogState();
}

class _PromptFillPickerDialogState extends State<_PromptFillPickerDialog> {
  late ComfyServer _server;
  ComfyTemplate? _template;
  ComfyExposedField? _field;

  @override
  void initState() {
    super.initState();
    _server = _initialServer();
    _template = _initialTemplate(_server);
    _field = _initialField(_template);
  }

  ComfyServer _initialServer() {
    final last = widget.last;
    if (last != null) {
      for (final s in widget.servers) {
        if (s.id == last.serverId) return s;
      }
    }
    return widget.servers.first;
  }

  List<ComfyTemplate> _templatesFor(ComfyServer server) {
    final ids = widget.bindings.forServer(server.id).templateIds.toSet();
    return [
      for (final t in widget.allTemplates)
        if (ids.contains(t.id)) t,
    ];
  }

  ComfyTemplate? _initialTemplate(ComfyServer server) {
    final bound = _templatesFor(server);
    if (bound.isEmpty) return null;
    final last = widget.last;
    if (last != null && last.serverId == server.id) {
      for (final t in bound) {
        if (t.id == last.templateId) return t;
      }
    }
    return bound.first;
  }

  ComfyExposedField? _initialField(ComfyTemplate? template) {
    if (template == null) return null;
    final fields = comfyPromptFieldsOf(template);
    if (fields.isEmpty) return null;
    final last = widget.last;
    if (last != null &&
        last.serverId == _server.id &&
        last.templateId == template.id) {
      for (final f in fields) {
        if (f.id == last.fieldId) return f;
      }
    }
    return fields.first;
  }

  void _selectServer(ComfyServer server) {
    if (identical(_server, server)) return;
    setState(() {
      _server = server;
      _template = _initialTemplate(server);
      _field = _initialField(_template);
    });
  }

  void _selectTemplate(ComfyTemplate template) {
    if (_template?.id == template.id) return;
    setState(() {
      _template = template;
      _field = _initialField(template);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final templates = _templatesFor(_server);
    final fields =
        _template == null ? const <ComfyExposedField>[] : comfyPromptFieldsOf(_template!);
    final canSubmit = _template != null && _field != null;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
        child: Material(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 0),
                child: Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 18, color: cs.primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '填入生成提示词',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: _flowGuide(context),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sectionBlock(
                        context,
                        label: '实例',
                        child: Column(
                          children: [
                            for (var i = 0; i < widget.servers.length; i++) ...[
                              if (i > 0) const SizedBox(height: 4),
                              _optionTile(
                                context,
                                selected: widget.servers[i].id == _server.id,
                                title: widget.servers[i].name,
                                subtitle: widget.servers[i].baseUrl,
                                onTap: () => _selectServer(widget.servers[i]),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      _sectionBlock(
                        context,
                        label: '模板',
                        child: templates.isEmpty
                            ? _emptyHint(context, '该实例尚未绑定模板')
                            : Column(
                                children: [
                                  for (var i = 0; i < templates.length; i++) ...[
                                    if (i > 0) const SizedBox(height: 4),
                                    _optionTile(
                                      context,
                                      selected: _template?.id == templates[i].id,
                                      title: templates[i].name,
                                      subtitle:
                                          '${templates[i].nodes.length} 个节点',
                                      onTap: () =>
                                          _selectTemplate(templates[i]),
                                    ),
                                  ],
                                ],
                              ),
                      ),
                      const SizedBox(height: 8),
                      _sectionBlock(
                        context,
                        label: '目标字段',
                        child: _template == null
                            ? _emptyHint(context, '请先选择模板')
                            : fields.isEmpty
                                ? _emptyHint(context, '该模板没有可用文本字段')
                                : Column(
                                    children: [
                                      for (var i = 0; i < fields.length; i++) ...[
                                        if (i > 0) const SizedBox(height: 4),
                                        _optionTile(
                                          context,
                                          selected: _field?.id == fields[i].id,
                                          title: _fieldPickLabel(
                                            _template!,
                                            fields[i],
                                          ),
                                          subtitle: fields[i].widget ==
                                                  ComfyWidgetKind.multiline
                                              ? '多行'
                                              : '单行',
                                          onTap: () => setState(
                                            () => _field = fields[i],
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
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: !canSubmit
                          ? null
                          : () {
                              Navigator.of(context).pop(
                                _PromptFillPickResult(
                                  server: _server,
                                  template: _template!,
                                  field: _field!,
                                ),
                              );
                            },
                      child: Text(widget.confirmLabel),
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

  Widget _flowGuide(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const steps = ['先选实例', '再选模板', '最后选目标字段'];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < steps.length; i++) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right,
                size: 14,
                color: cs.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            Text(
              '${i + 1}. ${steps[i]}',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionBlock(
    BuildContext context, {
    required String label,
    required Widget child,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.outlineVariant.withValues(alpha: 0.65),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionLabel(context, label),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
        color: cs.onSurfaceVariant,
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: cs.error.withValues(alpha: 0.85)),
      ),
    );
  }

  Widget _optionTile(
    BuildContext context, {
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? cs.primary.withValues(alpha: 0.10)
          : cs.surfaceContainerLow.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.outlineVariant.withValues(alpha: 0.55),
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 16,
                color: selected ? cs.primary : cs.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          color: cs.onSurfaceVariant,
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

/// 选区工具栏上的「填入生成提示词」：悬停后在右侧展开二级菜单。
class ComfyPromptFillSubmenuButton extends ConsumerStatefulWidget {
  final String selectedText;
  /// 编辑器宿主 context（关工具栏后仍可用于弹窗）。
  final BuildContext hostContext;

  const ComfyPromptFillSubmenuButton({
    super.key,
    required this.selectedText,
    required this.hostContext,
  });

  @override
  ConsumerState<ComfyPromptFillSubmenuButton> createState() =>
      _ComfyPromptFillSubmenuButtonState();
}

class _ComfyPromptFillSubmenuButtonState
    extends ConsumerState<ComfyPromptFillSubmenuButton> {
  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  Timer? _closeTimer;
  bool _overAnchor = false;
  bool _overMenu = false;

  bool get _highlightParent =>
      _entry != null || _overAnchor || _overMenu;

  @override
  void dispose() {
    _closeTimer?.cancel();
    _removeMenu(notify: false);
    super.dispose();
  }

  void _scheduleClose() {
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!_overAnchor && !_overMenu) _removeMenu();
    });
  }

  void _cancelClose() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  void _removeMenu({bool notify = true}) {
    _entry?.remove();
    _entry = null;
    if (notify && mounted) setState(() {});
  }

  void _openMenu() {
    if (_entry != null) return;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayState = Overlay.maybeOf(context, rootOverlay: true) ??
        Overlay.maybeOf(context);
    if (box == null || !box.hasSize || overlayState == null) return;

    final topLeft = box.localToGlobal(Offset(box.size.width - 2, 0));
    final last = ref.read(comfyPromptLastTargetProvider);
    final enabledIds = {
      for (final s in ref.read(comfyServersProvider))
        if (s.enabled) s.id,
    };
    final fullLabel = last?.displayLabel.trim() ?? '';
    final hasLast = last != null &&
        last.isValid &&
        fullLabel.isNotEmpty &&
        enabledIds.contains(last.serverId);
    final shortcuts = [
      for (final item in ref.read(comfyPromptShortcutsProvider))
        if (item.isValid && enabledIds.contains(item.serverId)) item,
    ];
    final shortLabel = fullLabel.length > 36
        ? '${fullLabel.substring(0, 36)}…'
        : fullLabel;

    _entry = OverlayEntry(
      builder: (ctx) {
        final isDark =
            Theme.of(ctx).colorScheme.brightness == Brightness.dark;
        final fg = isDark ? Colors.white : Colors.black87;
        const labelStyle = TextStyle(
          inherit: false,
          fontSize: 14.0,
          letterSpacing: -0.15,
          fontWeight: FontWeight.w400,
        );
        // 全屏吸收层：避免点击穿透到一级菜单的「点空白关闭」；
        // 点在菜单外则关掉一级+二级。菜单本体用 CodeEditorTapRegion。
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  _removeMenu();
                  ContextMenuController.removeAny();
                },
              ),
            ),
            Positioned(
              left: topLeft.dx,
              top: topLeft.dy,
              child: CodeEditorTapRegion(
                child: MouseRegion(
                  onEnter: (_) {
                    _overMenu = true;
                    _cancelClose();
                    if (mounted) setState(() {});
                  },
                  onExit: (_) {
                    _overMenu = false;
                    _scheduleClose();
                    if (mounted) setState(() {});
                  },
                  child: Material(
                    borderRadius: const BorderRadius.all(Radius.circular(7)),
                    clipBehavior: Clip.antiAlias,
                    elevation: 1,
                    type: MaterialType.card,
                    child: SizedBox(
                      width: 280,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 360),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (hasLast) ...[
                                Tooltip(
                                  message: fullLabel,
                                  waitDuration:
                                      const Duration(milliseconds: 250),
                                  child: DesktopTextSelectionToolbarButton(
                                    onPressed: () => _run(useLast: true),
                                    child: Text(
                                      '填入上次：$shortLabel',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: labelStyle.copyWith(color: fg),
                                    ),
                                  ),
                                ),
                                _menuDivider(fg),
                              ],
                              for (final shortcut in shortcuts)
                                Tooltip(
                                  message: shortcut.displayLabel,
                                  waitDuration:
                                      const Duration(milliseconds: 250),
                                  child: DesktopTextSelectionToolbarButton(
                                    onPressed: () => _run(explicit: shortcut),
                                    child: _shortcutMenuLabel(
                                      shortcut,
                                      labelStyle.copyWith(color: fg),
                                    ),
                                  ),
                                ),
                              if (shortcuts.isNotEmpty) _menuDivider(fg),
                              DesktopTextSelectionToolbarButton.text(
                                context: ctx,
                                onPressed: () => _run(useLast: false),
                                text: '选择目标…',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    overlayState.insert(_entry!);
    setState(() {});
  }

  Future<void> _run({
    bool useLast = false,
    ComfyPromptSendTarget? explicit,
  }) async {
    final text = widget.selectedText;
    final host = widget.hostContext;
    if (!host.mounted) return;
    // 工具栏项马上会随 ContextMenu 一起 dispose，不能再使用本 State 的 ref。
    final container = ProviderScope.containerOf(host);
    _removeMenu();
    ContextMenuController.removeAny();
    await Future<void>.delayed(Duration.zero);
    if (!host.mounted) return;
    await sendSelectionToComfyPrompt(
      host,
      container,
      text: text,
      useLastTarget: useLast,
      explicitTarget: explicit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    final foreground = isDark ? Colors.white : Colors.black87;
    // 与 DesktopTextSelectionToolbarButton 默认字号/字重保持一致。
    const labelStyle = TextStyle(
      inherit: false,
      fontSize: 14.0,
      letterSpacing: -0.15,
      fontWeight: FontWeight.w400,
    );
    // 悬停二级菜单时保持一级项高亮（近似 TextButton overlay）。
    final highlight = _highlightParent
        ? (isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.08))
        : Colors.transparent;

    return MouseRegion(
      key: _anchorKey,
      onEnter: (_) {
        _overAnchor = true;
        _cancelClose();
        _openMenu();
        setState(() {});
      },
      onExit: (_) {
        _overAnchor = false;
        _scheduleClose();
        setState(() {});
      },
      child: ColoredBox(
        color: highlight,
        child: DesktopTextSelectionToolbarButton(
          onPressed: _openMenu,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '填入生成提示词',
                  overflow: TextOverflow.ellipsis,
                  style: labelStyle.copyWith(color: foreground),
                ),
              ),
              Icon(Icons.arrow_right, size: 18, color: foreground),
            ],
          ),
        ),
      ),
    );
  }
}

/// [useLastTarget] 为 true 时直接沿用上次目标（需仍有效），否则走选择流程。
Future<bool> sendSelectionToComfyPrompt(
  BuildContext context,
  ProviderContainer container, {
  required String text,
  bool useLastTarget = false,
  ComfyPromptSendTarget? explicitTarget,
}) async {
  try {
    return await _sendSelectionToComfyPromptImpl(
      context,
      container,
      text: text,
      useLastTarget: useLastTarget,
      explicitTarget: explicitTarget,
    );
  } catch (e) {
    if (context.mounted) {
      showGlobalToast(context, '填入失败：$e');
    }
    return false;
  }
}

Future<bool> _sendSelectionToComfyPromptImpl(
  BuildContext context,
  ProviderContainer container, {
  required String text,
  required bool useLastTarget,
  ComfyPromptSendTarget? explicitTarget,
}) async {
  final trimmed = text.trimRight();
  if (trimmed.trim().isEmpty) {
    showGlobalToast(context, '请先选中要填入的文字');
    return false;
  }

  final servers = container
      .read(comfyServersProvider)
      .where((s) => s.enabled)
      .toList(growable: false);
  if (servers.isEmpty) {
    showGlobalToast(context, '请先在设置中启用至少一个 Comfy 实例');
    return false;
  }

  final templates = await ComfyTemplateStore.loadTemplates();
  final bindings = await ComfyTemplateStore.loadBindings();
  if (!context.mounted) return false;
  if (templates.isEmpty) {
    showGlobalToast(context, '还没有模板，请先在生成面板导入');
    return false;
  }

  final last = container.read(comfyPromptLastTargetProvider) ??
      await ComfyPromptSendMemory.load();
  if (!context.mounted) return false;

  if (useLastTarget || explicitTarget != null) {
    final resolved = _resolveTarget(
      last: explicitTarget ?? last,
      servers: servers,
      templates: templates,
      bindings: bindings,
    );
    if (resolved == null) {
      showGlobalToast(
        context,
        explicitTarget != null ? '该快捷路径已失效，请到设置里更新' : '上次目标已失效，请重新选择',
      );
      if (explicitTarget == null) {
        container.read(comfyPromptLastTargetProvider.notifier).state = null;
      }
      return false;
    }
    return _commitPromptFill(
      context,
      container,
      text: trimmed,
      server: resolved.server,
      template: resolved.template,
      field: resolved.field,
    );
  }

  // 预先校验：至少一个实例有可填模板+字段，避免弹出空窗。
  var anyReady = false;
  for (final s in servers) {
    final boundIds = bindings.forServer(s.id).templateIds.toSet();
    for (final t in templates) {
      if (!boundIds.contains(t.id)) continue;
      if (comfyPromptFieldsOf(t).isNotEmpty) {
        anyReady = true;
        break;
      }
    }
    if (anyReady) break;
  }
  if (!anyReady) {
    showGlobalToast(context, '没有可填入的模板字段，请先在生成面板绑定模板');
    return false;
  }

  final picked = await _pickPromptFillTarget(
    context: context,
    servers: servers,
    allTemplates: templates,
    bindings: bindings,
    last: last,
  );
  if (picked == null || !context.mounted) return false;

  return _commitPromptFill(
    context,
    container,
    text: trimmed,
    server: picked.server,
    template: picked.template,
    field: picked.field,
  );
}

({ComfyServer server, ComfyTemplate template, ComfyExposedField field})?
    _resolveTarget({
  required ComfyPromptSendTarget? last,
  required List<ComfyServer> servers,
  required List<ComfyTemplate> templates,
  required ComfyBindings bindings,
}) {
  if (last == null || !last.isValid) return null;
  ComfyServer? server;
  for (final s in servers) {
    if (s.id == last.serverId) {
      server = s;
      break;
    }
  }
  if (server == null) return null;
  if (!server.enabled) return null;
  if (!bindings.forServer(server.id).templateIds.contains(last.templateId)) {
    return null;
  }
  ComfyTemplate? template;
  for (final t in templates) {
    if (t.id == last.templateId) {
      template = t;
      break;
    }
  }
  if (template == null) return null;
  ComfyExposedField? field;
  for (final f in comfyPromptFieldsOf(template)) {
    if (f.id == last.fieldId) {
      field = f;
      break;
    }
  }
  if (field == null) return null;
  return (server: server, template: template, field: field);
}

Future<bool> _commitPromptFill(
  BuildContext context,
  ProviderContainer container, {
  required String text,
  required ComfyServer server,
  required ComfyTemplate template,
  required ComfyExposedField field,
}) async {
  await ComfyTemplateStore.selectTemplate(
    serverId: server.id,
    templateId: template.id,
  );

  final session = await ComfyGenSession.load(
    serverId: server.id,
    templateId: template.id,
  );
  final values = Map<String, dynamic>.from(session.values);
  values[field.id] = text;
  final enabled = Map<String, bool>.from(session.enabled);
  for (final node in template.nodes) {
    if (node.nodeId == field.nodeId && node.bypassWhenDisabled) {
      enabled[node.nodeId] = true;
    }
  }
  await ComfyGenSession.save(
    serverId: server.id,
    templateId: template.id,
    session: session.copyWith(values: values, enabled: enabled),
  );

  final target = ComfyPromptSendTarget(
    serverId: server.id,
    templateId: template.id,
    fieldId: field.id,
    displayLabel: _displayLabelFor(
      server: server,
      template: template,
      field: field,
    ),
  );
  await ComfyPromptSendMemory.save(target);
  container.read(comfyPromptLastTargetProvider.notifier).state = target;

  await AppConfig.instance.setComfySelectedServerId(server.id);
  if (!context.mounted) return false;
  container.read(comfySelectedServerIdProvider.notifier).state = server.id;
  container.read(contentModeProvider.notifier).state = 'comfy';
  container.read(comfyActionsTickProvider.notifier).state++;
  container.read(comfyPromptInjectRequestProvider.notifier).state =
      ComfyPromptInjectRequest(
    serverId: server.id,
    templateId: template.id,
    fieldId: field.id,
    nodeId: field.nodeId,
    text: text,
    nonce: DateTime.now().millisecondsSinceEpoch,
  );

  showGlobalToast(context, '已填入「${template.name}」提示词');
  return true;
}
