import 'package:flutter/material.dart';
import 'markdown_highlighter.dart';

/// 带 Markdown 语法高亮的 TextEditingController。
/// TextField 内部会调用 [buildTextSpan] 来渲染，重写后即实现源码着色。
class MarkdownHighlightController extends TextEditingController {
  final bool enabled;

  MarkdownHighlightController({super.text, this.enabled = true});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!enabled) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return highlightMarkdown(
      text,
      base: style ?? const TextStyle(fontFamily: 'Consolas'),
    );
  }
}
