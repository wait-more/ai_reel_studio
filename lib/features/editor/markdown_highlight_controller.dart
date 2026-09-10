import 'package:flutter/material.dart';
import 'markdown_highlighter.dart';

/// 带 Markdown 语法高亮的 TextEditingController。
///
/// 着色只改颜色、不改字重/斜体/字号，尽量与系统 plain 度量一致。
/// 组字时不改 TextSpan 拓扑（不下划线重切），IME 位置由编辑器侧几何同步兜底。
class MarkdownHighlightController extends TextEditingController {
  final bool enabled;

  MarkdownHighlightController({super.text, this.enabled = true});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle(fontFamily: 'Consolas');
    if (!enabled) {
      return super.buildTextSpan(
        context: context,
        style: base,
        withComposing: withComposing,
      );
    }

    return highlightMarkdown(
      text,
      base: base,
      brightness: Theme.of(context).brightness,
    );
  }
}
