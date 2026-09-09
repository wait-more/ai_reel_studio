import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'comfy_models.dart';

/// 模板库在项目 `.aireel/comfy/templates/`；URL↔模板绑定在本机（按项目根隔离）。
class ComfyTemplateStore {
  ComfyTemplateStore._();

  static const _kBindingsPrefix = 'comfy_bindings_v1:';

  static String? get comfyDir {
    final root = AppConfig.instance.projectRoot;
    if (root.isEmpty) return null;
    return p.join(root, '.aireel', 'comfy');
  }

  static String? get templatesDir {
    final root = comfyDir;
    if (root == null) return null;
    return p.join(root, 'templates');
  }

  /// 旧版项目内绑定文件；仅作一次性迁移来源，不再回写。
  static String? get legacyProjectBindingsPath {
    final root = comfyDir;
    if (root == null) return null;
    return p.join(root, 'bindings.json');
  }

  static String? _bindingsPrefsKey() {
    final root = AppConfig.instance.projectRoot.trim();
    if (root.isEmpty) return null;
    final normalized =
        root.replaceAll('/', Platform.pathSeparator).toLowerCase();
    return '$_kBindingsPrefix$normalized';
  }

  static Directory? ensureTemplatesDir() {
    final dirPath = templatesDir;
    if (dirPath == null) return null;
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static Future<void> migrateLegacyActionsIfNeeded() async {
    final root = comfyDir;
    final tplDirPath = templatesDir;
    if (root == null || tplDirPath == null) return;

    final tplDir = Directory(tplDirPath);
    if (await tplDir.exists()) {
      var hasTpl = false;
      await for (final e in tplDir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.template.json')) {
          hasTpl = true;
          break;
        }
      }
      if (hasTpl) return;
    }

    final rootDir = Directory(root);
    if (!await rootDir.exists()) return;

    final migrated = <ComfyTemplate>[];
    await for (final entity in rootDir.list()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.action.json')) continue;
      try {
        final map =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final tpl = ComfyTemplate.fromJson(map);
        final wfName = tpl.workflowFile;
        if (wfName.isEmpty) continue;

        final srcWf = File(p.join(root, wfName));
        final destDir = ensureTemplatesDir();
        if (destDir == null) continue;

        final safeBase = _sanitizeFileBase(tpl.name);
        final newWfName = '$safeBase.workflow.json';
        final newTplName = '$safeBase.template.json';
        if (await srcWf.exists()) {
          await srcWf.copy(p.join(destDir.path, newWfName));
        }

        final id = tpl.id.startsWith('act_')
            ? 'tpl_${tpl.id.substring(4)}'
            : (tpl.id.startsWith('tpl_')
                ? tpl.id
                : 'tpl_${DateTime.now().millisecondsSinceEpoch}');
        final saved = tpl.copyWith(
          id: id,
          workflowFile: newWfName,
          templatePath: p.join(destDir.path, newTplName),
        );
        await File(saved.templatePath!)
            .writeAsString(ComfyTemplate.prettyJson(saved.toJson()));
        migrated.add(saved);

        try {
          await entity.delete();
        } catch (_) {}
        try {
          if (await srcWf.exists()) await srcWf.delete();
        } catch (_) {}
      } catch (_) {}
    }

    if (migrated.isEmpty) return;

    final servers = AppConfig.instance.comfyServers;
    var bindings = await loadBindings();
    for (final s in servers) {
      final ids = migrated.map((t) => t.id).toList();
      bindings = bindings.withServer(
        s.id,
        ComfyServerBinding(
          templateIds: ids,
          selectedTemplateId: ids.isNotEmpty ? ids.first : null,
        ),
      );
    }
    await saveBindings(bindings);
  }

  static Future<List<ComfyTemplate>> loadTemplates() async {
    await migrateLegacyActionsIfNeeded();
    final dirPath = templatesDir;
    if (dirPath == null) return const [];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];

    final list = <ComfyTemplate>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.template.json')) continue;
      try {
        final map =
            jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        list.add(ComfyTemplate.fromJson(map, templatePath: entity.path));
      } catch (_) {}
    }
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  static Future<ComfyBindings> loadBindings() async {
    final key = _bindingsPrefsKey();
    if (key == null) return const ComfyBindings();

    final prefs = await SharedPreferences.getInstance();
    // 本机已有记录（含空绑定）则不再读项目文件，避免多用户互相覆盖。
    if (prefs.containsKey(key)) {
      return _decodeBindings(prefs.getString(key));
    }

    final migrated = await _loadLegacyProjectBindings();
    await prefs.setString(key, jsonEncode(migrated.toJson()));
    return migrated;
  }

  static Future<void> saveBindings(ComfyBindings bindings) async {
    final key = _bindingsPrefsKey();
    if (key == null) {
      throw StateError('未配置项目根');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonEncode(bindings.toJson()));
  }

  static ComfyBindings _decodeBindings(String? raw) {
    if (raw == null || raw.isEmpty) return const ComfyBindings();
    try {
      final map = jsonDecode(raw);
      if (map is! Map) return const ComfyBindings();
      return ComfyBindings.fromJson(Map<String, dynamic>.from(map));
    } catch (_) {
      return const ComfyBindings();
    }
  }

  static Future<ComfyBindings> _loadLegacyProjectBindings() async {
    final path = legacyProjectBindingsPath;
    if (path == null) return const ComfyBindings();
    final file = File(path);
    if (!await file.exists()) return const ComfyBindings();
    try {
      final map = jsonDecode(await file.readAsString());
      if (map is! Map) return const ComfyBindings();
      return ComfyBindings.fromJson(Map<String, dynamic>.from(map));
    } catch (_) {
      return const ComfyBindings();
    }
  }

  static Future<String> directorySignature() async {
    final root = comfyDir;
    if (root == null) return '';
    final dir = Directory(root);
    if (!await dir.exists()) return '';
    final parts = <String>[];

    Future<void> addFile(File f) async {
      final name = p.basename(f.path).toLowerCase();
      final stat = await f.stat();
      parts.add('$name:${stat.modified.millisecondsSinceEpoch}:${stat.size}');
    }

    final tpl = templatesDir;
    if (tpl != null) {
      final d = Directory(tpl);
      if (await d.exists()) {
        await for (final e in d.list()) {
          if (e is! File) continue;
          final n = p.basename(e.path).toLowerCase();
          if (n.endsWith('.template.json') || n.endsWith('.workflow.json')) {
            await addFile(e);
          }
        }
      }
    }

    // 旧 action 仍可能存在于迁移前
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final n = p.basename(e.path).toLowerCase();
      if (n.endsWith('.action.json')) await addFile(e);
    }

    parts.sort();
    return parts.join('|');
  }

  static Future<Map<String, dynamic>> loadWorkflowMap(
    ComfyTemplate template,
  ) async {
    final dir = templatesDir;
    if (dir == null) throw StateError('未配置项目根');
    final file = File(p.join(dir, template.workflowFile));
    if (!await file.exists()) {
      throw StateError('找不到 workflow：${template.workflowFile}');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw StateError('workflow 不是 JSON 对象');
    return Map<String, dynamic>.from(decoded);
  }

  static String hashWorkflowText(String text) {
    var h = 0xcbf29ce484222325;
    for (final unit in text.codeUnits) {
      h ^= unit;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  static Future<ComfyTemplate> saveTemplate({
    required String name,
    required Map<String, dynamic> workflow,
    required List<ComfyExposedNode> nodes,
    String? existingId,
    String? overwriteTemplatePath,
    String? existingWorkflowFile,
  }) async {
    final dir = ensureTemplatesDir();
    if (dir == null) throw StateError('未配置项目根');

    final safeBase = _sanitizeFileBase(name);
    final id = existingId ?? 'tpl_${DateTime.now().millisecondsSinceEpoch}';
    final workflowFile = existingWorkflowFile ?? '$safeBase.workflow.json';
    final workflowText = ComfyTemplate.prettyJson(workflow);
    final hash = hashWorkflowText(workflowText);

    await File(p.join(dir.path, workflowFile)).writeAsString(workflowText);

    final template = ComfyTemplate(
      id: id,
      name: name.trim().isEmpty ? safeBase : name.trim(),
      workflowFile: workflowFile,
      workflowHash: hash,
      nodes: nodes,
    );

    final templatePath = overwriteTemplatePath ??
        p.join(dir.path, '$safeBase.template.json');
    await File(templatePath)
        .writeAsString(ComfyTemplate.prettyJson(template.toJson()));
    return template.copyWith(templatePath: templatePath);
  }

  static Future<void> deleteTemplate(ComfyTemplate template) async {
    final dir = templatesDir;
    if (template.templatePath != null) {
      final f = File(template.templatePath!);
      if (await f.exists()) await f.delete();
    }
    if (dir != null && template.workflowFile.isNotEmpty) {
      final wf = File(p.join(dir, template.workflowFile));
      if (await wf.exists()) await wf.delete();
    }
    final bindings = await loadBindings();
    await saveBindings(bindings.withoutTemplate(template.id));
  }

  static Future<ComfyBindings> bindTemplates({
    required String serverId,
    required List<String> addTemplateIds,
  }) async {
    final bindings = await loadBindings();
    final cur = bindings.forServer(serverId);
    final ids = [...cur.templateIds];
    for (final id in addTemplateIds) {
      if (!ids.contains(id)) ids.add(id);
    }
    final sel = cur.selectedTemplateId ?? (ids.isNotEmpty ? ids.first : null);
    final next = bindings.withServer(
      serverId,
      ComfyServerBinding(templateIds: ids, selectedTemplateId: sel),
    );
    await saveBindings(next);
    return next;
  }

  static Future<ComfyBindings> unbindTemplate({
    required String serverId,
    required String templateId,
  }) async {
    final bindings = await loadBindings();
    final cur = bindings.forServer(serverId);
    final ids = cur.templateIds.where((id) => id != templateId).toList();
    final sel = cur.selectedTemplateId == templateId
        ? (ids.isNotEmpty ? ids.first : null)
        : cur.selectedTemplateId;
    final next = bindings.withServer(
      serverId,
      ComfyServerBinding(templateIds: ids, selectedTemplateId: sel),
    );
    await saveBindings(next);
    return next;
  }

  static Future<ComfyBindings> selectTemplate({
    required String serverId,
    required String? templateId,
  }) async {
    final bindings = await loadBindings();
    final cur = bindings.forServer(serverId);
    final next = bindings.withServer(
      serverId,
      cur.copyWith(
        selectedTemplateId: templateId,
        clearSelected: templateId == null,
      ),
    );
    await saveBindings(next);
    return next;
  }

  static String _sanitizeFileBase(String name) {
    var s = name.trim();
    if (s.isEmpty) s = 'template';
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), '_');
    if (s.length > 64) s = s.substring(0, 64);
    return s;
  }
}
