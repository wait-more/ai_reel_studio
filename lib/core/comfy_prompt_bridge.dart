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

class ComfyPromptSendTarget {
  final String serverId;
  final String templateId;
  final String fieldId;
  /// 如：`本地 · 定妆文生图 · 正向提示词`
  final String displayLabel;

  const ComfyPromptSendTarget({
    required this.serverId,
    required this.templateId,
    required this.fieldId,
    this.displayLabel = '',
  });

  Map<String, dynamic> toJson() => {
        'serverId': serverId,
        'templateId': templateId,
        'fieldId': fieldId,
        'displayLabel': displayLabel,
      };

  factory ComfyPromptSendTarget.fromJson(Map<String, dynamic> json) =>
      ComfyPromptSendTarget(
        serverId: json['serverId']?.toString() ?? '',
        templateId: json['templateId']?.toString() ?? '',
        fieldId: json['fieldId']?.toString() ?? '',
        displayLabel: json['displayLabel']?.toString() ?? '',
      );

  bool get isValid =>
      serverId.isNotEmpty && templateId.isNotEmpty && fieldId.isNotEmpty;
}

class ComfyPromptSendMemory {
  ComfyPromptSendMemory._();
  static const _kKey = 'comfy_prompt_send_target_v1';

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

  /// 启动时/进入编辑器时灌入 provider，供右键菜单同步读取。
  static Future<void> hydrateProvider(WidgetRef ref) async {
    final loaded = await load();
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

Future<T?> _pickOne<T>({
  required BuildContext context,
  required String title,
  required List<T> items,
  required String Function(T) labelOf,
  String Function(T)? subtitleOf,
  T? initiallySelected,
  bool forceDialog = false,
}) async {
  if (items.isEmpty) return null;
  if (!forceDialog && items.length == 1) return items.first;
  return showDialog<T>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        for (final item in items)
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(item),
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              selected: initiallySelected != null &&
                      identical(item, initiallySelected)
                  ? true
                  : (initiallySelected != null && item == initiallySelected),
              title: Text(labelOf(item)),
              subtitle: subtitleOf == null
                  ? null
                  : Text(
                      subtitleOf(item),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
            ),
          ),
      ],
    ),
  );
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
    final fullLabel = last?.displayLabel.trim() ?? '';
    final hasLast = last != null && last.isValid && fullLabel.isNotEmpty;
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
                      width: 222,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (hasLast)
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
          ],
        );
      },
    );
    overlayState.insert(_entry!);
    setState(() {});
  }

  Future<void> _run({required bool useLast}) async {
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
}) async {
  try {
    return await _sendSelectionToComfyPromptImpl(
      context,
      container,
      text: text,
      useLastTarget: useLastTarget,
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
}) async {
  final trimmed = text.trimRight();
  if (trimmed.trim().isEmpty) {
    showGlobalToast(context, '请先选中要填入的文字');
    return false;
  }

  final servers = container.read(comfyServersProvider);
  if (servers.isEmpty) {
    showGlobalToast(context, '请先在设置中添加 Comfy 实例');
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

  if (useLastTarget) {
    final resolved = _resolveTarget(
      last: last,
      servers: servers,
      templates: templates,
      bindings: bindings,
    );
    if (resolved == null) {
      showGlobalToast(context, '上次目标已失效，请重新选择');
      container.read(comfyPromptLastTargetProvider.notifier).state = null;
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

  ComfyServer? preferredServer;
  if (last != null) {
    for (final s in servers) {
      if (s.id == last.serverId) {
        preferredServer = s;
        break;
      }
    }
  }

  final server = await _pickOne<ComfyServer>(
    context: context,
    title: '填入生成提示词 · 选择实例',
    items: servers,
    labelOf: (s) => s.name,
    subtitleOf: (s) => s.baseUrl,
    initiallySelected: preferredServer,
  );
  if (server == null || !context.mounted) return false;

  final boundIds = bindings.forServer(server.id).templateIds.toSet();
  final boundTemplates = [
    for (final t in templates)
      if (boundIds.contains(t.id)) t,
  ];
  if (boundTemplates.isEmpty) {
    showGlobalToast(context, '该实例尚未绑定模板');
    return false;
  }

  ComfyTemplate? preferredTemplate;
  if (last != null && last.serverId == server.id) {
    for (final t in boundTemplates) {
      if (t.id == last.templateId) {
        preferredTemplate = t;
        break;
      }
    }
  }

  final template = await _pickOne<ComfyTemplate>(
    context: context,
    title: '选择模板',
    items: boundTemplates,
    labelOf: (t) => t.name,
    subtitleOf: (t) => '${t.nodes.length} 个节点',
    initiallySelected: preferredTemplate,
  );
  if (template == null || !context.mounted) return false;

  final fields = comfyPromptFieldsOf(template);
  if (fields.isEmpty) {
    showGlobalToast(context, '该模板没有可用的文本/多行字段');
    return false;
  }

  ComfyExposedField? preferredField;
  if (last != null &&
      last.serverId == server.id &&
      last.templateId == template.id) {
    for (final f in fields) {
      if (f.id == last.fieldId) {
        preferredField = f;
        break;
      }
    }
  }
  preferredField ??= fields.first;

  // 节点/字段始终弹出选择（即使只有一个），模板仅一个时可自动跳过。
  final field = await _pickOne<ComfyExposedField>(
    context: context,
    title: '选择目标节点',
    items: fields,
    labelOf: (f) => _fieldPickLabel(template, f),
    subtitleOf: (f) =>
        f.widget == ComfyWidgetKind.multiline ? '多行' : '单行',
    initiallySelected: preferredField,
    forceDialog: true,
  );
  if (field == null || !context.mounted) return false;

  return _commitPromptFill(
    context,
    container,
    text: trimmed,
    server: server,
    template: template,
    field: field,
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
