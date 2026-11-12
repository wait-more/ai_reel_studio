import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../text_file_io.dart';

/// 把内置制片 skill 同步到项目 `.opencode/skills/`，供 OpenCode 自动发现。
class PipelineSkillSync {
  PipelineSkillSync._();

  static const skillId = 'aireel-produce';
  static const assetPath = 'assets/skills/aireel-produce/SKILL.md';

  /// 相对项目根的落盘路径。
  static String relativeSkillPath =
      '.opencode/skills/$skillId/SKILL.md';

  /// 打开/切换项目时调用；内容与内置资源一致时跳过写入。
  static Future<String?> syncToProject({String? projectRoot}) async {
    final root = (projectRoot ?? AppConfig.instance.projectRoot).trim();
    if (root.isEmpty) return null;

    late final String content;
    try {
      content = await rootBundle.loadString(assetPath);
    } catch (_) {
      return null;
    }
    if (content.trim().isEmpty) return null;

    final destPath = p.join(root, '.opencode', 'skills', skillId, 'SKILL.md');
    final dest = File(destPath);
    try {
      if (await dest.exists()) {
        final old = await dest.readAsString();
        if (old == content) return destPath;
      } else {
        await dest.parent.create(recursive: true);
      }
      await writeTextFileReliable(destPath, content);

      // 旁路一份到 .aireel，方便在 Studio 配置树里看到。
      final mirror = p.join(
        root,
        '.aireel',
        'skills',
        skillId,
        'SKILL.md',
      );
      await Directory(p.dirname(mirror)).create(recursive: true);
      await writeTextFileReliable(mirror, content);

      return destPath;
    } catch (_) {
      return null;
    }
  }
}
