import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 软换行下文档逻辑行的垂直度量（与 Cursor/VS Code 行号一致：
/// 一行只占一个行号，续行空白不编号）。
class WrapLineMetrics {
  /// 每个逻辑行的视觉高度。
  final List<double> heights;

  /// 每个逻辑行顶部相对文本内容原点的偏移（不含 InputDecoration padding）。
  final List<double> tops;

  final double lineHeight;
  final double totalHeight;

  const WrapLineMetrics({
    required this.heights,
    required this.tops,
    required this.lineHeight,
    required this.totalHeight,
  });

  int get lineCount => heights.length;

  double topOf(int line) {
    if (tops.isEmpty) return 0;
    return tops[line.clamp(0, tops.length - 1)];
  }

  double heightOf(int line) {
    if (heights.isEmpty) return lineHeight;
    return heights[line.clamp(0, heights.length - 1)];
  }

  double bottomOf(int line) => topOf(line) + heightOf(line);

  /// 内容区 Y（不含 padding）→ 逻辑行（0-based）。
  int lineAtY(double y) {
    if (tops.isEmpty) return 0;
    if (y <= 0) return 0;
    var lo = 0;
    var hi = tops.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (tops[mid] <= y) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// 与另一份度量是否足够接近（避免无意义刷新）。
  bool nearlyEquals(WrapLineMetrics other, {double eps = 0.6}) {
    if (identical(this, other)) return true;
    if (lineCount != other.lineCount) return false;
    if ((totalHeight - other.totalHeight).abs() > eps) return false;
    for (var i = 0; i < tops.length; i++) {
      if ((tops[i] - other.tops[i]).abs() > eps) return false;
      if ((heights[i] - other.heights[i]).abs() > eps) return false;
    }
    return true;
  }
}

/// EditableText 默认 caret 边距（与 RenderEditable._caretMargin 一致）。
const double kEditableCaretMargin = 1.0 + 2.0; // gap + default cursorWidth

/// 用与编辑器相同的 [InlineSpan] / 宽度测量逻辑行顶边与高度。
///
/// 关键用整篇 [TextPainter.getOffsetForCaret] 取行首 Y，避免逐行估高再累加漂移。
WrapLineMetrics buildWrapLineMetrics({
  required String text,
  required InlineSpan span,
  required double maxWidth,
  required double lineHeight,
  StrutStyle? strutStyle,
}) {
  final width = math.max(20.0, maxWidth);
  final lines = text.isEmpty ? <String>[''] : text.split('\n');

  final tp = TextPainter(
    text: span,
    textDirection: TextDirection.ltr,
    strutStyle: strutStyle,
  )..layout(maxWidth: width);

  final tops = <double>[];
  var charOffset = 0;
  for (var i = 0; i < lines.length; i++) {
    final o = charOffset.clamp(0, text.length);
    tops.add(
      tp.getOffsetForCaret(TextPosition(offset: o), Rect.zero).dy,
    );
    charOffset += lines[i].length;
    if (i < lines.length - 1) charOffset += 1;
  }

  final heights = <double>[];
  for (var i = 0; i < lines.length; i++) {
    late final double bottom;
    if (i + 1 < lines.length) {
      bottom = tops[i + 1];
    } else {
      bottom = _lineBottomFromPainter(tp, text, lines, i, tops[i], lineHeight);
    }
    heights.add(math.max(lineHeight * 0.5, bottom - tops[i]));
  }

  return WrapLineMetrics(
    heights: heights,
    tops: tops,
    lineHeight: lineHeight,
    totalHeight: math.max(tp.height, tops.isEmpty ? lineHeight : bottomOfLast(tops, heights)),
  );
}

double bottomOfLast(List<double> tops, List<double> heights) {
  if (tops.isEmpty) return 0;
  final i = tops.length - 1;
  return tops[i] + heights[i];
}

double _lineBottomFromPainter(
  TextPainter tp,
  String text,
  List<String> lines,
  int lineIndex,
  double top,
  double lineHeight,
) {
  var start = 0;
  for (var i = 0; i < lineIndex; i++) {
    start += lines[i].length + 1;
  }
  final end = text.length;
  if (end <= start) return top + lineHeight;

  final boxes = tp.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  if (boxes.isEmpty) return top + lineHeight;
  var maxBottom = top + lineHeight;
  for (final b in boxes) {
    if (b.bottom > maxBottom) maxBottom = b.bottom;
  }
  return maxBottom;
}

/// 从已布局的 [RenderEditable] 读取真实行顶（内容坐标，已扣除滚动）。
WrapLineMetrics? buildWrapLineMetricsFromEditable({
  required RenderEditable editable,
  required String text,
  required double lineHeight,
}) {
  if (!editable.hasSize) return null;

  final lines = text.isEmpty ? <String>[''] : text.split('\n');
  final scrollY = editable.offset.pixels;

  final tops = <double>[];
  var charOffset = 0;
  for (var i = 0; i < lines.length; i++) {
    final o = charOffset.clamp(0, text.length);
    tops.add(_contentTopForOffset(editable, text, o, scrollY, lineHeight));
    charOffset += lines[i].length;
    if (i < lines.length - 1) charOffset += 1;
  }

  final heights = <double>[];
  for (var i = 0; i < lines.length; i++) {
    late final double bottom;
    if (i + 1 < lines.length) {
      bottom = tops[i + 1];
    } else {
      bottom = _lineBottomFromEditable(
        editable,
        text,
        lines,
        i,
        tops[i],
        lineHeight,
        scrollY,
      );
    }
    heights.add(math.max(lineHeight * 0.5, bottom - tops[i]));
  }

  return WrapLineMetrics(
    heights: heights,
    tops: tops,
    lineHeight: lineHeight,
    totalHeight: bottomOfLast(tops, heights),
  );
}

/// 取某字符处逻辑行顶（内容坐标）。优先用 glyph box，避免 caret 垂直居中偏移。
double _contentTopForOffset(
  RenderEditable editable,
  String text,
  int offset,
  double scrollY,
  double lineHeight,
) {
  final o = offset.clamp(0, text.length);
  if (text.isNotEmpty && o < text.length) {
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: o, extentOffset: o + 1),
    );
    if (boxes.isNotEmpty) {
      var minTop = boxes.first.top;
      for (final b in boxes) {
        if (b.top < minTop) minTop = b.top;
      }
      return minTop + scrollY;
    }
  }
  // 空行或末尾：退回 caret，并近似对齐到行高网格
  final local = editable.getLocalRectForCaret(TextPosition(offset: o));
  final raw = local.top + scrollY;
  if (lineHeight <= 0) return raw;
  return (raw / lineHeight).round() * lineHeight;
}

double _lineBottomFromEditable(
  RenderEditable editable,
  String text,
  List<String> lines,
  int lineIndex,
  double top,
  double lineHeight,
  double scrollY,
) {
  var start = 0;
  for (var i = 0; i < lineIndex; i++) {
    start += lines[i].length + 1;
  }
  final end = text.length;
  if (end <= start) return top + lineHeight;

  final List<TextBox> boxes = editable.getBoxesForSelection(
    TextSelection(baseOffset: start, extentOffset: end),
  );
  if (boxes.isEmpty) return top + lineHeight;
  var maxBottom = top + lineHeight;
  for (final b in boxes) {
    final contentBottom = b.bottom + scrollY;
    if (contentBottom > maxBottom) maxBottom = contentBottom;
  }
  return maxBottom;
}

/// 在 [root] 子树中查找 [RenderEditable]。
RenderEditable? findRenderEditable(RenderObject? root) {
  if (root == null) return null;
  RenderEditable? found;
  void visit(RenderObject object) {
    if (found != null) return;
    if (object is RenderEditable) {
      found = object;
      return;
    }
    object.visitChildren(visit);
  }

  visit(root);
  return found;
}
