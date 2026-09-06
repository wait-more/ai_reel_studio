import 'package:flutter/material.dart';

/// Markdown 编辑区语法色板（接近 Cursor / VS Code Markdown）。
class _MdColors {
  final Color punct; // # * > - []() `` 等标记
  final Color heading;
  final Color headingPunct;
  final Color bold;
  final Color italic;
  final Color strike;
  final Color code;
  final Color codeBg;
  final Color fence;
  final Color fenceLang;
  final Color quote;
  final Color list;
  final Color task;
  final Color linkText;
  final Color linkUrl;
  final Color image;
  final Color hr;
  final Color table;
  final Color html;
  final Color text;

  const _MdColors({
    required this.punct,
    required this.heading,
    required this.headingPunct,
    required this.bold,
    required this.italic,
    required this.strike,
    required this.code,
    required this.codeBg,
    required this.fence,
    required this.fenceLang,
    required this.quote,
    required this.list,
    required this.task,
    required this.linkText,
    required this.linkUrl,
    required this.image,
    required this.hr,
    required this.table,
    required this.html,
    required this.text,
  });

  static const dark = _MdColors(
    punct: Color(0xFF6B737E),
    heading: Color(0xFF79B8FF),
    headingPunct: Color(0xFF5A7A9A),
    bold: Color(0xFFE6C07B),
    italic: Color(0xFFB4E0A0),
    strike: Color(0xFF8B949E),
    code: Color(0xFFFFAB70),
    codeBg: Color(0x22FFFFFF),
    fence: Color(0xFF6B737E),
    fenceLang: Color(0xFFD2A8FF),
    quote: Color(0xFF8B949E),
    list: Color(0xFFD2A8FF),
    task: Color(0xFF79B8FF),
    linkText: Color(0xFF58A6FF),
    linkUrl: Color(0xFF7EE787),
    image: Color(0xFFFFA657),
    hr: Color(0xFF484F58),
    table: Color(0xFF6B737E),
    html: Color(0xFFFF7B72),
    text: Color(0xFFE6EDF3),
  );

  static const light = _MdColors(
    punct: Color(0xFF6E7781),
    heading: Color(0xFF0550AE),
    headingPunct: Color(0xFF6E7781),
    bold: Color(0xFF953800),
    italic: Color(0xFF116329),
    strike: Color(0xFF6E7781),
    code: Color(0xFFCF222E),
    codeBg: Color(0x14000000),
    fence: Color(0xFF6E7781),
    fenceLang: Color(0xFF8250DF),
    quote: Color(0xFF6E7781),
    list: Color(0xFF8250DF),
    task: Color(0xFF0550AE),
    linkText: Color(0xFF0969DA),
    linkUrl: Color(0xFF1A7F37),
    image: Color(0xFFBC4C00),
    hr: Color(0xFFD0D7DE),
    table: Color(0xFF6E7781),
    html: Color(0xFFCF222E),
    text: Color(0xFF1F2328),
  );

  factory _MdColors.of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

/// 把整段 Markdown 源码着色为 [TextSpan]。
///
/// **必须保持与 [src] 字符一一对应**（含所有标记符），否则光标会错位。
TextSpan highlightMarkdown(
  String src, {
  TextStyle? base,
  Brightness brightness = Brightness.dark,
}) {
  final c = _MdColors.of(brightness);
  final lines = src.split('\n');
  final spans = <InlineSpan>[];
  var inFence = false;
  var fenceMarker = ''; // ``` or ~~~

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (i > 0) spans.add(const TextSpan(text: '\n'));

    if (inFence) {
      final trimmed = line.trimLeft();
      if (fenceMarker.isNotEmpty &&
          trimmed.startsWith(fenceMarker) &&
          RegExp('^${RegExp.escape(fenceMarker)}\\s*\$').hasMatch(trimmed)) {
        inFence = false;
        fenceMarker = '';
        spans.add(_fenceClosingLine(line, c));
      } else {
        spans.add(TextSpan(
          text: line,
          style: TextStyle(
            color: c.code,
            fontFamily: 'Consolas',
            backgroundColor: c.codeBg,
          ),
        ));
      }
      continue;
    }

    final fenceOpen = RegExp(r'^(\s*)(```|~~~)([^\n]*)$').firstMatch(line);
    if (fenceOpen != null) {
      inFence = true;
      fenceMarker = fenceOpen.group(2)!;
      spans.add(_fenceOpeningLine(line, fenceOpen, c));
      continue;
    }

    spans.add(_highlightLine(line, base, c));
  }

  return TextSpan(style: base, children: spans);
}

TextSpan _fenceOpeningLine(String line, RegExpMatch m, _MdColors c) {
  final indent = m.group(1)!;
  final ticks = m.group(2)!;
  final lang = m.group(3)!;
  return TextSpan(children: [
    TextSpan(text: indent),
    TextSpan(text: ticks, style: TextStyle(color: c.fence)),
    if (lang.isNotEmpty)
      TextSpan(
        text: lang,
        style: TextStyle(
          color: c.fenceLang,
          fontWeight: FontWeight.w600,
          fontFamily: 'Consolas',
        ),
      ),
  ]);
}

TextSpan _fenceClosingLine(String line, _MdColors c) {
  final m = RegExp(r'^(\s*)(```|~~~)\s*$').firstMatch(line);
  if (m == null) {
    return TextSpan(text: line, style: TextStyle(color: c.fence));
  }
  return TextSpan(children: [
    TextSpan(text: m.group(1)),
    TextSpan(text: line.substring(m.start + m.group(1)!.length),
        style: TextStyle(color: c.fence)),
  ]);
}

TextSpan _highlightLine(String line, TextStyle? base, _MdColors c) {
  // ATX 标题：# 标记淡色，标题文字加粗着色（按级别微调）
  final h = RegExp(r'^(#{1,6})(\s+)(.*)$').firstMatch(line);
  if (h != null) {
    final level = h.group(1)!.length;
    final titleStyle = TextStyle(
      color: c.heading,
      fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
    );
    return TextSpan(children: [
      TextSpan(
        text: h.group(1),
        style: TextStyle(color: c.headingPunct, fontWeight: FontWeight.w700),
      ),
      TextSpan(text: h.group(2)),
      _inline(h.group(3)!, titleStyle, c),
    ]);
  }

  // 引用（支持嵌套 >>>）
  final q = RegExp(r'^((?:>\s*)+)(.*)$').firstMatch(line);
  if (q != null) {
    return TextSpan(children: [
      TextSpan(
        text: q.group(1),
        style: TextStyle(color: c.punct, fontWeight: FontWeight.w600),
      ),
      _inline(
        q.group(2)!,
        TextStyle(color: c.quote, fontStyle: FontStyle.italic),
        c,
      ),
    ]);
  }

  // 分隔线
  if (RegExp(r'^\s*(?:-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
    return TextSpan(
      text: line,
      style: TextStyle(color: c.hr, fontWeight: FontWeight.w700),
    );
  }

  // 表格行（含 |）
  if (line.contains('|') &&
      RegExp(r'^\s*\|?.+\|.+\|?\s*$').hasMatch(line) &&
      !line.trimLeft().startsWith('```')) {
    return _tableLine(line, base, c);
  }

  // 任务列表 / 普通列表
  final task = RegExp(r'^(\s*)([-*+])(\s+)\[([ xX])\](\s+)(.*)$').firstMatch(line);
  if (task != null) {
    final checked = task.group(4)!.toLowerCase() == 'x';
    return TextSpan(children: [
      TextSpan(text: task.group(1)),
      TextSpan(
        text: task.group(2),
        style: TextStyle(color: c.list, fontWeight: FontWeight.w700),
      ),
      TextSpan(text: task.group(3)),
      TextSpan(text: '[', style: TextStyle(color: c.punct)),
      TextSpan(
        text: task.group(4),
        style: TextStyle(
          color: c.task,
          fontWeight: FontWeight.w700,
          decoration: checked ? TextDecoration.lineThrough : null,
        ),
      ),
      TextSpan(text: ']', style: TextStyle(color: c.punct)),
      TextSpan(text: task.group(5)),
      _inline(
        task.group(6)!,
        checked
            ? TextStyle(color: c.strike, decoration: TextDecoration.lineThrough)
            : base,
        c,
      ),
    ]);
  }

  final li = RegExp(r'^(\s*)([-*+]|\d+[.)])(\s+)(.*)$').firstMatch(line);
  if (li != null) {
    return TextSpan(children: [
      TextSpan(text: li.group(1)),
      TextSpan(
        text: li.group(2),
        style: TextStyle(color: c.list, fontWeight: FontWeight.w700),
      ),
      TextSpan(text: li.group(3)),
      _inline(li.group(4)!, base, c),
    ]);
  }

  return _inline(line, base, c);
}

TextSpan _tableLine(String line, TextStyle? base, _MdColors c) {
  // 对齐分隔行 |---|:---|
  if (RegExp(r'^\s*\|?[\s:|-]+\|[\s:|-]*$').hasMatch(line)) {
    return TextSpan(
      text: line,
      style: TextStyle(color: c.table, fontFamily: 'Consolas'),
    );
  }

  final parts = <InlineSpan>[];
  var i = 0;
  while (i < line.length) {
    if (line[i] == '|') {
      parts.add(TextSpan(text: '|', style: TextStyle(color: c.table)));
      i++;
      continue;
    }
    final start = i;
    while (i < line.length && line[i] != '|') {
      i++;
    }
    parts.add(_inline(line.substring(start, i), base, c));
  }
  return TextSpan(children: parts);
}

/// 行内：图片 / 链接 / 自动链接 / 代码 / 粗斜体 / 粗体 / 删除线 / 斜体 / HTML。
/// 匹配内容必须原样输出（含标记符）。
final _inlinePattern = RegExp(
  r'('
  r'!\[([^\]]*)\]\(([^)]*)\)' // 1 image: 2=alt 3=url
  r'|\[([^\]]+)\]\(([^)]*)\)' // 4 link text, 5 url
  r'|<(https?:\/\/[^>\s]+)>' // 6 autolink
  r'|`([^`\n]+)`' // 7 code
  r'|\*\*\*([^*\n]+)\*\*\*|___([^_\n]+)___' // 8/9 bold+italic
  r'|\*\*([^*\n]+)\*\*|__([^_\n]+)__' // 10/11 bold
  r'|~~([^~\n]+)~~' // 12 strike
  r'|\*([^*\n]+)\*|_([^_\n]+)_' // 13/14 italic
  r'|==([^=\n]+)==' // 15 highlight
  r'|</?[a-zA-Z][^>\n]*>' // 16 html (whole match)
  r')',
);

TextSpan _inline(String text, TextStyle? base, _MdColors c) {
  if (text.isEmpty) return TextSpan(text: text, style: base);

  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in _inlinePattern.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start), style: base));
    }
    spans.addAll(_styleInlineMatch(m, c, base));
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last), style: base));
  }
  if (spans.isEmpty) return TextSpan(text: text, style: base);
  return TextSpan(style: base, children: spans);
}

List<InlineSpan> _styleInlineMatch(
  RegExpMatch m,
  _MdColors c,
  TextStyle? base,
) {
  final full = m.group(0)!;

  // Image ![alt](url)
  if (m.group(2) != null) {
    final alt = m.group(2)!;
    final url = m.group(3)!;
    return [
      TextSpan(text: '![', style: TextStyle(color: c.punct)),
      TextSpan(text: alt, style: TextStyle(color: c.image)),
      TextSpan(text: '](', style: TextStyle(color: c.punct)),
      TextSpan(text: url, style: TextStyle(color: c.linkUrl, fontSize: 12)),
      TextSpan(text: ')', style: TextStyle(color: c.punct)),
    ];
  }

  // Link [text](url) — 保留方括号与原文
  if (m.group(4) != null) {
    final t = m.group(4)!;
    final url = m.group(5)!;
    return [
      TextSpan(text: '[', style: TextStyle(color: c.punct)),
      TextSpan(
        text: t,
        style: TextStyle(
          color: c.linkText,
          decoration: TextDecoration.underline,
          decorationColor: c.linkText.withValues(alpha: 0.45),
        ),
      ),
      TextSpan(text: '](', style: TextStyle(color: c.punct)),
      TextSpan(text: url, style: TextStyle(color: c.linkUrl, fontSize: 12)),
      TextSpan(text: ')', style: TextStyle(color: c.punct)),
    ];
  }

  // Autolink
  if (m.group(6) != null) {
    return [
      TextSpan(text: '<', style: TextStyle(color: c.punct)),
      TextSpan(text: m.group(6), style: TextStyle(color: c.linkUrl)),
      TextSpan(text: '>', style: TextStyle(color: c.punct)),
    ];
  }

  // Inline code
  if (m.group(7) != null) {
    return [
      TextSpan(text: '`', style: TextStyle(color: c.punct)),
      TextSpan(
        text: m.group(7),
        style: TextStyle(
          color: c.code,
          fontFamily: 'Consolas',
          backgroundColor: c.codeBg,
        ),
      ),
      TextSpan(text: '`', style: TextStyle(color: c.punct)),
    ];
  }

  // Bold+italic
  if (m.group(8) != null || m.group(9) != null) {
    final star = m.group(8) != null;
    final body = m.group(8) ?? m.group(9)!;
    final mark = star ? '***' : '___';
    return [
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
      TextSpan(
        text: body,
        style: TextStyle(
          color: c.bold,
          fontWeight: FontWeight.w700,
          fontStyle: FontStyle.italic,
        ),
      ),
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
    ];
  }

  // Bold
  if (m.group(10) != null || m.group(11) != null) {
    final star = m.group(10) != null;
    final body = m.group(10) ?? m.group(11)!;
    final mark = star ? '**' : '__';
    return [
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
      TextSpan(
        text: body,
        style: TextStyle(color: c.bold, fontWeight: FontWeight.w700),
      ),
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
    ];
  }

  // Strikethrough
  if (m.group(12) != null) {
    return [
      TextSpan(text: '~~', style: TextStyle(color: c.punct)),
      TextSpan(
        text: m.group(12),
        style: TextStyle(
          color: c.strike,
          decoration: TextDecoration.lineThrough,
        ),
      ),
      TextSpan(text: '~~', style: TextStyle(color: c.punct)),
    ];
  }

  // Italic
  if (m.group(13) != null || m.group(14) != null) {
    final star = m.group(13) != null;
    final body = m.group(13) ?? m.group(14)!;
    final mark = star ? '*' : '_';
    return [
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
      TextSpan(
        text: body,
        style: TextStyle(color: c.italic, fontStyle: FontStyle.italic),
      ),
      TextSpan(text: mark, style: TextStyle(color: c.punct)),
    ];
  }

  // ==highlight==
  if (m.group(15) != null) {
    return [
      TextSpan(text: '==', style: TextStyle(color: c.punct)),
      TextSpan(
        text: m.group(15),
        style: TextStyle(
          color: c.bold,
          backgroundColor: const Color(0x33E6C07B),
        ),
      ),
      TextSpan(text: '==', style: TextStyle(color: c.punct)),
    ];
  }

  // HTML tag (group 0 is the whole match when only html matched)
  if (full.startsWith('<') && full.endsWith('>')) {
    return [
      TextSpan(
        text: full,
        style: TextStyle(color: c.html, fontFamily: 'Consolas'),
      ),
    ];
  }

  return [TextSpan(text: full, style: base)];
}
