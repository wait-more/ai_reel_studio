import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

enum _SettingsSection { project, appearance, shell, shortcuts, about }

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

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        Text('AIReelStudio', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('版本 0.1.0'),
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
