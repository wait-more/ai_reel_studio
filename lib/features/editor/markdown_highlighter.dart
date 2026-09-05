import 'package:flutter/material.dart';

/// Markdown 源码语法高亮 —— 类 One Dark 深色配色，用于编辑区着色。
class _C {
  static const heading = Color(0xFF61AFEF); // 蓝
  static const bold = Color(0xFFE5C07B); // 金
  static const italic = Color(0xFF98C379); // 绿
  static const code = Color(0xFFE5C07B); // 金
  static const codeBg = Color(0x26FFFFFF);
  static const quote = Color(0xFFABB2BF); // 灰
  static const list = Color(0xFFC678DD); // 紫
  static const link = Color(0xFF61AFEF); // 蓝
  static const hr = Color(0xFF5C6370); // 深灰
}

/// 把整段 Markdown 源码着色为 TextSpan 序列。
/// [base] 为继承的基础样式（字体/字号）；叶子节点继承其上色样式。
TextSpan highlightMarkdown(String src, {TextStyle? base}) {
  final lines = src.split('\n');
  final spans = <InlineSpan>[];
  for (final line in lines) {
    spans.add(_highlightLine(line, base));
    spans.add(const TextSpan(text: '\n'));
  }
  // 去掉末尾额外换行（split 会在最后产生一个空串换行）
  if (spans.length > 1) spans.removeLast();
  return TextSpan(style: base, children: spans);
}

TextSpan _highlightLine(String line, TextStyle? base) {
  // 标题
  final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
  if (h != null) {
    final level = h.group(1)!.length;
    return TextSpan(
      children: [
        TextSpan(
          text: h.group(1),
          style: const TextStyle(
            color: _C.heading,
            fontWeight: FontWeight.w700,
          ),
        ),
        const TextSpan(text: ' '),
        _inline(
          h.group(2)!,
          TextStyle(
            color: _C.heading,
            fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ],
    );
  }

  // 引用
  if (line.startsWith('>')) {
    return TextSpan(
      children: [
        TextSpan(
          text: '>',
          style: const TextStyle(color: _C.quote, fontWeight: FontWeight.w700),
        ),
        _inline(
          line.substring(1),
          const TextStyle(color: _C.quote, fontStyle: FontStyle.italic),
        ),
      ],
    );
  }

  // 分隔线
  if (RegExp(r'^\s*(---|\*\*\*|___)\s*$').hasMatch(line)) {
    return TextSpan(
      text: line,
      style: const TextStyle(
        color: _C.hr,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  // 代码块围栏
  if (line.trimLeft().startsWith('```') || line.trimLeft().startsWith('~~~')) {
    return TextSpan(
      text: line,
      style: TextStyle(color: _C.code, backgroundColor: _C.codeBg),
    );
  }

  // 无序/有序列表项 marker
  final li = RegExp(r'^(\s*)([-*+]|\d+\.)\s+').firstMatch(line);
  if (li != null) {
    return TextSpan(
      children: [
        TextSpan(text: li.group(1)),
        TextSpan(
          text: li.group(2),
          style: const TextStyle(
            color: _C.list,
            fontWeight: FontWeight.w700,
          ),
        ),
        TextSpan(text: ' '),
        _inline(line.substring(li.end), base),
      ],
    );
  }

  return _inline(line, base);
}

final _inlinePattern = RegExp(
  r'(\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*|_([^_\n]+)_|`([^`\n]+)`|\[([^\]\n]+)\]\(([^)\n]+)\))',
);

/// 行内高亮：加粗 / 斜体 / 行内代码 / 链接。
TextSpan _inline(String text, TextStyle? base) {
  final spans = <InlineSpan>[];
  int last = 0;
  for (final m in _inlinePattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final b = m.group(2);
    final bu = m.group(3);
    final i = m.group(4);
    final iu = m.group(5);
    final c = m.group(6);
    final linkText = m.group(7);
    final linkUrl = m.group(8);

    if (b != null || bu != null) {
      final s = b ?? bu!;
      spans
        ..add(TextSpan(
          text: b != null ? '**' : '__',
          style: const TextStyle(color: _C.bold),
        ))
        ..add(TextSpan(
          text: s,
          style: const TextStyle(
            color: _C.bold,
            fontWeight: FontWeight.w700,
          ),
        ))
        ..add(TextSpan(
          text: b != null ? '**' : '__',
          style: const TextStyle(color: _C.bold),
        ));
    } else if (i != null || iu != null) {
      final s = i ?? iu!;
      spans.add(TextSpan(
        text: s,
        style: const TextStyle(
          color: _C.italic,
          fontStyle: FontStyle.italic,
        ),
      ));
    } else if (c != null) {
      spans..add(const TextSpan(text: '`', style: TextStyle(color: _C.code)))
        ..add(TextSpan(
          text: c,
          style: TextStyle(
            color: _C.code,
            fontFamily: 'Consolas',
            backgroundColor: _C.codeBg,
          ),
        ))
        ..add(const TextSpan(text: '`', style: TextStyle(color: _C.code)));
    } else if (linkText != null) {
      spans
        ..add(TextSpan(text: linkText, style: const TextStyle(color: _C.link)))
        ..add(TextSpan(
          text: ' ($linkUrl)',
          style: const TextStyle(color: _C.quote, fontSize: 11),
        ));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return TextSpan(style: base, children: spans);
}
