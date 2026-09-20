import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/comfy/comfy_models.dart';
import '../../core/comfy_prompt_bridge.dart';
import '../../core/config.dart';
import '../../core/key_chord.dart';
import '../../core/providers.dart';
import '../layout/main_layout.dart';

class SettingsPage extends ConsumerWidget {
  final bool firstRun;
  const SettingsPage({super.key, this.firstRun = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (firstRun) {
      return Scaffold(body: _FirstRunPanel());
    }
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 600),
        child: const _SettingsShell(),
      ),
    );
  }
}

class _FirstRunPanel extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(
              Icons.movie_filter,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              '欢迎使用 AIReelStudio',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              '选择你的 scripts 目录作为项目根目录',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            const _ProjectDirPicker(firstRun: true),
          ],
        ),
      ),
    );
  }
}

enum _SettingsSection { project, appearance, shell, comfy, shortcuts, about }

class _SettingsShell extends ConsumerStatefulWidget {
  const _SettingsShell();

  @override
  ConsumerState<_SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends ConsumerState<_SettingsShell> {
  _SettingsSection _section = _SettingsSection.project;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Row(
            children: [
              Text('设置', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              IconButton(
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 148,
                child: NavigationRail(
                  selectedIndex: _section.index,
                  onDestinationSelected: (i) {
                    setState(() => _section = _SettingsSection.values[i]);
                  },
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(
                      icon: Icon(Icons.folder_outlined),
                      selectedIcon: Icon(Icons.folder),
                      label: Text('项目'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.palette_outlined),
                      selectedIcon: Icon(Icons.palette),
                      label: Text('外观'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.terminal_outlined),
                      selectedIcon: Icon(Icons.terminal),
                      label: Text('Shell'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.auto_awesome_outlined),
                      selectedIcon: Icon(Icons.auto_awesome),
                      label: Text('Comfy'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.keyboard_outlined),
                      selectedIcon: Icon(Icons.keyboard),
                      label: Text('快捷键'),
                    ),
                    NavigationRailDestination(
                      icon: Icon(Icons.info_outline),
                      selectedIcon: Icon(Icons.info),
                      label: Text('关于'),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: switch (_section) {
                    _SettingsSection.project => const _ProjectSection(),
                    _SettingsSection.appearance => const _AppearanceSection(),
                    _SettingsSection.shell => const _ShellSection(),
                    _SettingsSection.comfy => const _ComfySection(),
                    _SettingsSection.shortcuts => const _ShortcutsSection(),
                    _SettingsSection.about => const _AboutSection(),
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectSection extends StatelessWidget {
  const _ProjectSection();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text('项目目录', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '本地路径或已挂载的 UNC（如 \\\\nas\\share\\scripts）。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        const _ProjectDirPicker(firstRun: false),
      ],
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final uiScale = ref.watch(uiFontScaleProvider);
    final editorSize = ref.watch(editorFontSizeProvider);
    final terminalSize = ref.watch(terminalFontSizeProvider);

    return ListView(
      children: [
        Text('主题', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(value: ThemeMode.dark, label: Text('暗色'), icon: Icon(Icons.dark_mode, size: 16)),
            ButtonSegment(value: ThemeMode.light, label: Text('亮色'), icon: Icon(Icons.light_mode, size: 16)),
            ButtonSegment(value: ThemeMode.system, label: Text('系统'), icon: Icon(Icons.brightness_auto, size: 16)),
          ],
          selected: {themeMode},
          onSelectionChanged: (set) async {
            final mode = set.first;
            ref.read(themeModeProvider.notifier).state = mode;
            await AppConfig.instance.setThemeMode(mode);
          },
        ),
        const SizedBox(height: 24),
        Text('界面字号', style: Theme.of(context).textTheme.titleMedium),
        Text(
          '当前倍率 ${(uiScale * 100).round()}%',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: uiScale,
          min: 0.85,
          max: 1.4,
          divisions: 11,
          label: '${(uiScale * 100).round()}%',
          onChanged: (v) {
            ref.read(uiFontScaleProvider.notifier).state = v;
          },
          onChangeEnd: (v) => AppConfig.instance.setUiFontScale(v),
        ),
        const SizedBox(height: 8),
        Text('编辑器字号', style: Theme.of(context).textTheme.titleMedium),
        Text(
          '${editorSize.round()} px',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: editorSize,
          min: 11,
          max: 24,
          divisions: 13,
          label: '${editorSize.round()}',
          onChanged: (v) {
            ref.read(editorFontSizeProvider.notifier).state = v;
          },
          onChangeEnd: (v) => AppConfig.instance.setEditorFontSize(v),
        ),
        const SizedBox(height: 8),
        Text('终端字号', style: Theme.of(context).textTheme.titleMedium),
        Text(
          '${terminalSize.round()} px',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        Slider(
          value: terminalSize,
          min: 10,
          max: 22,
          divisions: 12,
          label: '${terminalSize.round()}',
          onChanged: (v) {
            ref.read(terminalFontSizeProvider.notifier).state = v;
          },
          onChangeEnd: (v) => AppConfig.instance.setTerminalFontSize(v),
        ),
      ],
    );
  }
}

class _ShellSection extends ConsumerWidget {
  const _ShellSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cmds = ref.watch(startCmdsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('快捷启动', style: Theme.of(context).textTheme.titleMedium),
            ),
            TextButton.icon(
              onPressed: () async {
                final created = await _editStartCmd(context);
                if (created == null) return;
                final next = [...cmds, created];
                ref.read(startCmdsProvider.notifier).state = next;
                await AppConfig.instance.setStartCmds(next);
              },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加'),
            ),
            TextButton(
              onPressed: () async {
                final next = List.of(AppConfig.defaultStartCmds);
                ref.read(startCmdsProvider.notifier).state = next;
                await AppConfig.instance.setStartCmds(next);
              },
              child: const Text('恢复默认'),
            ),
          ],
        ),
        Text(
          '点击芯片时向当前终端发送命令；可指定 cwd 为项目根或当前选中目录。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: cmds.isEmpty
              ? const Center(child: Text('暂无快捷命令'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: cmds.length,
                  onReorder: (oldIndex, newIndex) async {
                    final next = List.of(cmds);
                    if (newIndex > oldIndex) newIndex--;
                    final item = next.removeAt(oldIndex);
                    next.insert(newIndex, item);
                    ref.read(startCmdsProvider.notifier).state = next;
                    await AppConfig.instance.setStartCmds(next);
                  },
                  itemBuilder: (context, index) {
                    final cmd = cmds[index];
                    return ListTile(
                      key: ValueKey('${cmd.name}-$index'),
                      dense: true,
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: const Icon(Icons.drag_handle, size: 18),
                      ),
                      title: Text(cmd.name),
                      subtitle: Text(
                        '${cmd.command}  ·  ${_cwdLabel(cmd.cwd)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '编辑',
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            onPressed: () async {
                              final edited =
                                  await _editStartCmd(context, existing: cmd);
                              if (edited == null) return;
                              final next = List.of(cmds);
                              next[index] = edited;
                              ref.read(startCmdsProvider.notifier).state = next;
                              await AppConfig.instance.setStartCmds(next);
                            },
                          ),
                          IconButton(
                            tooltip: '删除',
                            icon: Icon(Icons.delete_outline,
                                size: 18, color: Colors.red[300]),
                            onPressed: () async {
                              final next = List.of(cmds)..removeAt(index);
                              ref.read(startCmdsProvider.notifier).state = next;
                              await AppConfig.instance.setStartCmds(next);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  static String _cwdLabel(CwdStrategy cwd) {
    switch (cwd) {
      case CwdStrategy.projectRoot:
        return '项目根目录';
      case CwdStrategy.selectedDir:
        return '当前选中目录';
    }
  }
}

class _ComfySection extends ConsumerStatefulWidget {
  const _ComfySection();

  @override
  ConsumerState<_ComfySection> createState() => _ComfySectionState();
}

class _ComfySectionState extends ConsumerState<_ComfySection> {
  @override
  Widget build(BuildContext context) {
    final servers = ref.watch(comfyServersProvider);
    final selectedId = ref.watch(comfySelectedServerIdProvider);
    final cs = Theme.of(context).colorScheme;

    return ListView(
      children: [
        Text('ComfyUI 实例', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '可配置多个 ComfyUI 地址。关闭「启用」后该实例不会出现在生成面板列表中。'
          '同一动作共享一份 workflow 模板，各实例的节点暴露配置可单独保存。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        ...servers.map((s) {
          final active = s.id == selectedId;
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              selected: active,
              enabled: s.enabled,
              leading: Icon(
                active ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 20,
              ),
              title: Text(s.name),
              subtitle: Text(
                s.enabled ? s.baseUrl : '${s.baseUrl} · 已关闭',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: s.enabled ? () => _selectServer(s.id) : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: s.enabled,
                    onChanged: (v) => _setEnabled(s, v),
                  ),
                  IconButton(
                    tooltip: '编辑',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () => _editServer(s),
                  ),
                  IconButton(
                    tooltip: '删除',
                    icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
                    onPressed: servers.length <= 1
                        ? null
                        : () => _deleteServer(s),
                  ),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _addServer,
            icon: const Icon(Icons.add),
            label: const Text('添加实例'),
          ),
        ),
        const SizedBox(height: 28),
        const _ComfyPromptShortcuts(),
      ],
    );
  }

  Future<void> _persist(List<ComfyServer> list, {String? selectedId}) async {
    await AppConfig.instance.setComfyServers(list);
    if (selectedId != null) {
      await AppConfig.instance.setComfySelectedServerId(selectedId);
      ref.read(comfySelectedServerIdProvider.notifier).state = selectedId;
    } else {
      ref.read(comfySelectedServerIdProvider.notifier).state =
          AppConfig.instance.comfySelectedServerId;
    }
    ref.read(comfyServersProvider.notifier).state =
        AppConfig.instance.comfyServers;
  }

  Future<void> _selectServer(String id) async {
    await AppConfig.instance.setComfySelectedServerId(id);
    ref.read(comfySelectedServerIdProvider.notifier).state = id;
  }

  Future<void> _setEnabled(ComfyServer server, bool enabled) async {
    final next = ref
        .read(comfyServersProvider)
        .map((s) => s.id == server.id ? s.copyWith(enabled: enabled) : s)
        .toList();
    await _persist(next);
  }

  Future<void> _addServer() async {
    final created = await _editServerDialog(context);
    if (created == null) return;
    final next = [...ref.read(comfyServersProvider), created];
    await _persist(next, selectedId: created.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加「${created.name}」')),
    );
  }

  Future<void> _editServer(ComfyServer server) async {
    final edited = await _editServerDialog(context, existing: server);
    if (edited == null) return;
    final next = ref
        .read(comfyServersProvider)
        .map((s) => s.id == server.id ? edited : s)
        .toList();
    await _persist(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('实例已更新')),
    );
  }

  Future<void> _deleteServer(ComfyServer server) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除实例'),
        content: Text('确定删除「${server.name}」？动作里该实例的配置会保留在文件中，但不再可选。'),
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
    final next =
        ref.read(comfyServersProvider).where((s) => s.id != server.id).toList();
    await _persist(next);
  }
}

/// 填入生成提示词的固定路径。放在 Comfy 实例下面：路径里含实例，
/// 关掉「启用」后二级菜单会一起藏掉对应项。
class _ComfyPromptShortcuts extends ConsumerStatefulWidget {
  const _ComfyPromptShortcuts();

  @override
  ConsumerState<_ComfyPromptShortcuts> createState() =>
      _ComfyPromptShortcutsState();
}

class _ComfyPromptShortcutsState extends ConsumerState<_ComfyPromptShortcuts> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ComfyPromptSendMemory.hydrateProvider(ref);
    });
  }

  Future<void> _save(List<ComfyPromptSendTarget> next) async {
    ref.read(comfyPromptShortcutsProvider.notifier).state = next;
    await ComfyPromptSendMemory.saveShortcuts(next);
  }

  Future<void> _add() async {
    final picked = await pickComfyPromptShortcut(context);
    if (picked == null || !mounted) return;
    final named = await _promptShortcutName(context);
    if (named == null || !mounted) return;
    final item = picked.copyWith(name: named);
    final current = ref.read(comfyPromptShortcutsProvider);
    final exists = current.any(
      (t) =>
          t.serverId == item.serverId &&
          t.templateId == item.templateId &&
          t.fieldId == item.fieldId,
    );
    if (exists) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这条路径已经在列表里')),
      );
      return;
    }
    await _save([...current, item]);
  }

  Future<void> _rename(int index) async {
    final shortcuts = ref.read(comfyPromptShortcutsProvider);
    if (index < 0 || index >= shortcuts.length) return;
    final named = await _promptShortcutName(
      context,
      initial: shortcuts[index].name,
    );
    if (named == null) return;
    final next = List<ComfyPromptSendTarget>.of(shortcuts);
    next[index] = next[index].copyWith(name: named);
    await _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = ref.watch(comfyPromptShortcutsProvider);
    final servers = ref.watch(comfyServersProvider);
    final cs = Theme.of(context).colorScheme;
    final enabledIds = {
      for (final s in servers)
        if (s.enabled) s.id,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('填入快捷路径', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '出现在文档右键「填入生成提示词」的二级菜单里，排在「填入上次」后面。'
          '实例关闭启用后，对应项会从菜单隐藏。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 12),
        if (shortcuts.isEmpty)
          Text(
            '还没有快捷路径',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else
          for (var i = 0; i < shortcuts.length; i++)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  shortcuts[i].name.trim().isEmpty
                      ? (shortcuts[i].displayLabel.isEmpty
                          ? '未命名路径'
                          : shortcuts[i].displayLabel)
                      : '${shortcuts[i].name.trim()}：',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: enabledIds.contains(shortcuts[i].serverId)
                      ? null
                      : TextStyle(color: cs.onSurface.withValues(alpha: 0.45)),
                ),
                subtitle: () {
                  final lines = [
                    if (shortcuts[i].name.trim().isNotEmpty)
                      shortcuts[i].displayLabel,
                    if (!enabledIds.contains(shortcuts[i].serverId))
                      '实例已关闭，菜单中隐藏',
                  ];
                  if (lines.isEmpty) return null;
                  return Text(
                    lines.join('\n'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  );
                }(),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '命名',
                      icon: const Icon(Icons.drive_file_rename_outline, size: 20),
                      onPressed: () => _rename(i),
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
                      onPressed: () {
                        final next = List<ComfyPromptSendTarget>.of(shortcuts)
                          ..removeAt(i);
                        _save(next);
                      },
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _add,
            icon: const Icon(Icons.add),
            label: const Text('添加快捷路径'),
          ),
        ),
      ],
    );
  }
}

/// 返回 trim 后的名称；取消返回 null。空字符串表示不命名。
Future<String?> _promptShortcutName(
  BuildContext context, {
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _ShortcutNameDialog(initial: initial),
  );
}

class _ShortcutNameDialog extends StatefulWidget {
  final String initial;

  const _ShortcutNameDialog({required this.initial});

  @override
  State<_ShortcutNameDialog> createState() => _ShortcutNameDialogState();
}

class _ShortcutNameDialogState extends State<_ShortcutNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('快捷路径名称', style: TextStyle(fontSize: 15)),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '名称',
          hintText: '可留空',
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

Future<ComfyServer?> _editServerDialog(
  BuildContext context, {
  ComfyServer? existing,
}) {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final urlCtrl = TextEditingController(
    text: existing?.baseUrl ?? AppConfig.defaultComfyBaseUrl,
  );
  final keyCtrl = TextEditingController(text: existing?.apiKey ?? '');
  var enabled = existing?.enabled ?? true;

  return showDialog<ComfyServer>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(existing == null ? '添加 ComfyUI 实例' : '编辑实例'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '名称',
                      hintText: '例如 本机 / 云 GPU',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: AppConfig.defaultComfyBaseUrl,
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: keyCtrl,
                    decoration: const InputDecoration(
                      labelText: 'API Key（可选）',
                      isDense: true,
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用'),
                    subtitle: const Text('关闭后不显示在生成面板'),
                    value: enabled,
                    onChanged: (v) => setLocal(() => enabled = v),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final url = urlCtrl.text.trim();
                  if (url.isEmpty) return;
                  Navigator.pop(
                    ctx,
                    ComfyServer(
                      id: existing?.id ??
                          'srv_${DateTime.now().millisecondsSinceEpoch}',
                      name: name.isEmpty ? 'ComfyUI' : name,
                      baseUrl: url,
                      apiKey: keyCtrl.text,
                      enabled: enabled,
                    ),
                  );
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}

Future<StartCmd?> _editStartCmd(BuildContext context, {StartCmd? existing}) {
  final nameCtrl = TextEditingController(text: existing?.name ?? '');
  final cmdCtrl = TextEditingController(text: existing?.command ?? '');
  var cwd = existing?.cwd ?? CwdStrategy.projectRoot;

  return showDialog<StartCmd>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return AlertDialog(
            title: Text(existing == null ? '添加快捷启动' : '编辑快捷启动'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '显示名称',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: cmdCtrl,
                    decoration: const InputDecoration(
                      labelText: '命令',
                      hintText: '例如 opencode',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<CwdStrategy>(
                    value: cwd,
                    decoration: const InputDecoration(
                      labelText: '工作目录',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: CwdStrategy.projectRoot,
                        child: Text('项目根目录'),
                      ),
                      DropdownMenuItem(
                        value: CwdStrategy.selectedDir,
                        child: Text('当前选中目录'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setLocal(() => cwd = v);
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final command = cmdCtrl.text.trim();
                  if (name.isEmpty || command.isEmpty) return;
                  Navigator.pop(
                    ctx,
                    StartCmd(name: name, command: command, cwd: cwd),
                  );
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _ShortcutsSection extends ConsumerStatefulWidget {
  const _ShortcutsSection();

  @override
  ConsumerState<_ShortcutsSection> createState() => _ShortcutsSectionState();
}

class _ShortcutsSectionState extends ConsumerState<_ShortcutsSection> {
  bool _recording = false;
  late final FocusNode _recordFocus = FocusNode();

  @override
  void dispose() {
    _recordFocus.dispose();
    super.dispose();
  }

  Future<void> _applyChord(KeyChord chord) async {
    ref.read(sendAgentRefChordProvider.notifier).state = chord;
    await AppConfig.instance.setSendAgentRefChord(chord);
    if (mounted) {
      setState(() => _recording = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chord = ref.watch(sendAgentRefChordProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      children: [
        Text('快捷键', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          '向智能体填入引用',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Text(
          '在 Markdown 编辑器中按下组合键，把当前文件或选区变成引用字符串，'
          '写入右侧 Shell 里已检测到的智能体输入区（不自动回车）。\n'
          '• 无选区 → @相对路径\n'
          '• 有选区 → @相对路径#L12 或 @相对路径#L12-L34\n'
          '• 未检测到 opencode / dsh-tui 等智能体时会提示并拒绝填入\n'
          '• 原始 PowerShell 不会填入',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Text('当前组合键', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Text(
                chord.label,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_recording)
          Focus(
            focusNode: _recordFocus,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent) return KeyEventResult.ignored;
              if (KeyChord.isModifierOnly(event.logicalKey)) {
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.escape) {
                setState(() => _recording = false);
                return KeyEventResult.handled;
              }
              final next = KeyChord.fromKeyEvent(event);
              // 至少要有一个修饰键，避免误绑单键
              if (!next.control && !next.alt && !next.shift && !next.meta) {
                return KeyEventResult.handled;
              }
              _applyChord(next);
              return KeyEventResult.handled;
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: scheme.primaryContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: scheme.primary),
              ),
              child: Text(
                '请按下新的组合键…（Esc 取消；需含 Ctrl/Alt/Shift 之一）',
                style: TextStyle(color: scheme.onSurface),
              ),
            ),
          )
        else
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: () {
                  setState(() => _recording = true);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _recordFocus.requestFocus();
                  });
                },
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('重新定义'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: chord == KeyChord.defaultSendAgentRef
                    ? null
                    : () => _applyChord(KeyChord.defaultSendAgentRef),
                child: const Text('恢复默认 (Ctrl+Alt+K)'),
              ),
            ],
          ),
        const SizedBox(height: 20),
        Text('其它内置快捷键', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        Text(
          'Ctrl+P — 全局搜索（暂不支持重定义）',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _AboutSection extends StatefulWidget {
  const _AboutSection();

  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text('AIReelStudio', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        FutureBuilder<PackageInfo>(
          future: _info,
          builder: (context, snapshot) {
            final version = snapshot.data?.version;
            final build = snapshot.data?.buildNumber;
            final label = version == null
                ? '版本 …'
                : (build == null || build.isEmpty)
                    ? '版本 $version'
                    : '版本 $version ($build)';
            return Text(label);
          },
        ),
        const SizedBox(height: 8),
        Text(
          'AI 短视频创作工作台。文件系统为唯一事实来源。',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

class _ProjectDirPicker extends ConsumerWidget {
  final bool firstRun;
  const _ProjectDirPicker({required this.firstRun});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () async {
        final result = await FilePicker.getDirectoryPath();
        if (result == null) return;
        await AppConfig.instance.setProjectRoot(result);
        if (!context.mounted) return;
        if (firstRun) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const MainLayout()),
            (route) => false,
          );
        } else {
          // 触发项目树与物料网格按新根目录重建
          ref.read(treeRefreshTickProvider.notifier).state++;
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_open,
                size: 20, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                AppConfig.instance.isConfigured
                    ? AppConfig.instance.projectRoot
                    : '点击选择目录...',
                style: TextStyle(
                  color: AppConfig.instance.isConfigured
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
