/// Markdown ATX 标题大纲条目。
class OutlineHeading {
  final int level; // 1–6
  final String title;
  final int lineIndex; // 0-based
  final int charOffset; // 该行在全文中的起始偏移

  const OutlineHeading({
    required this.level,
    required this.title,
    required this.lineIndex,
    required this.charOffset,
  });
}

/// 解析 ATX 标题（跳过围栏代码块）。
List<OutlineHeading> parseMarkdownOutline(String src) {
  if (src.isEmpty) return const [];

  final lines = src.split('\n');
  final out = <OutlineHeading>[];
  var inFence = false;
  var fenceMarker = '';
  var offset = 0;

  final headingRe = RegExp(r'^(#{1,6})\s+(.+?)(?:\s+#*)?\s*$');
  final fenceRe = RegExp(r'^(```|~~~)');

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();

    if (inFence) {
      if (fenceMarker.isNotEmpty &&
          trimmed.startsWith(fenceMarker) &&
          RegExp('^${RegExp.escape(fenceMarker)}\\s*\$').hasMatch(trimmed)) {
        inFence = false;
        fenceMarker = '';
      }
    } else {
      final fence = fenceRe.firstMatch(trimmed);
      if (fence != null) {
        inFence = true;
        fenceMarker = fence.group(1)!;
      } else {
        final h = headingRe.firstMatch(line);
        if (h != null) {
          out.add(OutlineHeading(
            level: h.group(1)!.length,
            title: h.group(2)!.trim(),
            lineIndex: i,
            charOffset: offset,
          ));
        }
      }
    }

    offset += line.length;
    if (i < lines.length - 1) offset += 1; // \n
  }
  return out;
}

/// 当前应高亮的大纲项：光标/可见行所在章节（最后一个 lineIndex ≤ [line] 的标题）。
int activeOutlineIndex(List<OutlineHeading> items, int line) {
  if (items.isEmpty) return -1;
  var best = -1;
  for (var i = 0; i < items.length; i++) {
    if (items[i].lineIndex <= line) {
      best = i;
    } else {
      break;
    }
  }
  return best;
}

/// Cursor 式面包屑：从文档开头堆栈到 [activeIndex]，得到 H1→…→当前标题路径。
List<OutlineHeading> outlineBreadcrumb(
  List<OutlineHeading> items,
  int activeIndex,
) {
  if (activeIndex < 0 || activeIndex >= items.length) return const [];
  final stack = <OutlineHeading>[];
  for (var i = 0; i <= activeIndex; i++) {
    final h = items[i];
    while (stack.isNotEmpty && stack.last.level >= h.level) {
      stack.removeLast();
    }
    stack.add(h);
  }
  return List.unmodifiable(stack);
}

/// 字符偏移 → 行号（0-based）。
int lineIndexOfOffset(String text, int offset) {
  final o = offset.clamp(0, text.length);
  var line = 0;
  for (var i = 0; i < o; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// 文本总行数（至少 1）。
int countLines(String text) {
  if (text.isEmpty) return 1;
  var n = 1;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) n++;
  }
  return n;
}
