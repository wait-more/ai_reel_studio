import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'wrap_line_metrics.dart';

/// 行号槽：用 [RenderEditable] 真实行位置映射，软换行续行不编号。
///
/// 垂直对齐策略（与编辑器同一套 strut）：
/// - 行中线 = caret 矩形中心（Flutter 在整行高内垂直居中）
/// - 行号用相同 strut 行高绘制，几何中心对中线，避免墨迹盒/缩小字号造成忽上忽下
class LineNumberGutter extends StatefulWidget {
  final GlobalKey editorFieldKey;
  final String text;
  final int lineCount;
  final double scrollOffset;
  final double fontSize;
  final double lineHeight;
  final int? activeLine; // 0-based

  const LineNumberGutter({
    super.key,
    required this.editorFieldKey,
    required this.text,
    required this.lineCount,
    required this.scrollOffset,
    required this.fontSize,
    required this.lineHeight,
    this.activeLine,
  });

  static double widthFor(int lineCount, double fontSize) {
    final digits = lineCount.toString().length.clamp(2, 6);
    return digits * fontSize * 0.62 + 16;
  }

  @override
  State<LineNumberGutter> createState() => _LineNumberGutterState();
}

class _LineNumberGutterState extends State<LineNumberGutter> {
  final GlobalKey _gutterKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant LineNumberGutter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text ||
        oldWidget.scrollOffset != widget.scrollOffset ||
        oldWidget.fontSize != widget.fontSize ||
        oldWidget.lineCount != widget.lineCount ||
        oldWidget.activeLine != widget.activeLine) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45);
    final active = theme.colorScheme.primary;

    return SizedBox(
      key: _gutterKey,
      width: LineNumberGutter.widthFor(widget.lineCount, widget.fontSize),
      child: ClipRect(
        child: CustomPaint(
          painter: _LineNumberPainter(
            gutterKey: _gutterKey,
            editorFieldKey: widget.editorFieldKey,
            text: widget.text,
            lineCount: widget.lineCount,
            scrollOffset: widget.scrollOffset,
            fontSize: widget.fontSize,
            lineHeight: widget.lineHeight,
            muted: muted,
            active: active,
            activeLine: widget.activeLine,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _LineNumberPainter extends CustomPainter {
  final GlobalKey gutterKey;
  final GlobalKey editorFieldKey;
  final String text;
  final int lineCount;
  final double scrollOffset;
  final double fontSize;
  final double lineHeight;
  final Color muted;
  final Color active;
  final int? activeLine;

  _LineNumberPainter({
    required this.gutterKey,
    required this.editorFieldKey,
    required this.text,
    required this.lineCount,
    required this.scrollOffset,
    required this.fontSize,
    required this.lineHeight,
    required this.muted,
    required this.active,
    required this.activeLine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (lineCount <= 0) return;

    final gutterBox = gutterKey.currentContext?.findRenderObject() as RenderBox?;
    final editable = findRenderEditable(
      editorFieldKey.currentContext?.findRenderObject(),
    );
    if (gutterBox == null ||
        editable == null ||
        !editable.hasSize ||
        !gutterBox.hasSize) {
      return;
    }

    final plh = editable.preferredLineHeight > 0
        ? editable.preferredLineHeight
        : lineHeight;
    final heightFactor = fontSize > 0 ? plh / fontSize : 1.6;

    // 中文/大写视觉重心高于几何中线；以「汉」为正文视觉中心基准
    final bodyVisualCenter = _strutVisualCenterFromTop(
      sample: '汉',
      fontSize: fontSize,
      heightFactor: heightFactor,
      plh: plh,
    );

    final lines = text.isEmpty ? <String>[''] : text.split('\n');
    final n = math.min(lineCount, lines.length);
    var charOffset = 0;

    for (var i = 0; i < n; i++) {
      final o = charOffset.clamp(0, text.length);
      final editableMidY =
          editable.getLocalRectForCaret(TextPosition(offset: o)).center.dy;
      final gutterMidY = gutterBox
          .globalToLocal(editable.localToGlobal(Offset(0, editableMidY)))
          .dy;

      charOffset += lines[i].length;
      if (i < lines.length - 1) charOffset += 1;

      if (gutterMidY - plh > size.height) break;
      if (gutterMidY + plh < 0) continue;

      final isActive = activeLine == i;
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: isActive ? active : muted,
            fontSize: fontSize * 0.85,
            fontFamily: 'Consolas',
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            height: heightFactor,
          ),
        ),
        textDirection: TextDirection.ltr,
        strutStyle: StrutStyle(
          fontSize: fontSize,
          height: heightFactor,
          fontFamily: 'Consolas',
          forceStrutHeight: true,
        ),
      )..layout(minWidth: 0, maxWidth: size.width - 6);

      final numVisualCenter = _visualCenterFromTop(tp, fallback: tp.height / 2);
      // 行号视觉中心对齐正文（汉）视觉中心 → 相对几何中线上移
      final strutTop = gutterMidY - plh / 2;
      final dy = strutTop + bodyVisualCenter - numVisualCenter;
      tp.paint(canvas, Offset(size.width - tp.width - 8, dy));
    }
  }

  double _strutVisualCenterFromTop({
    required String sample,
    required double fontSize,
    required double heightFactor,
    required double plh,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: sample,
        style: TextStyle(
          fontSize: fontSize,
          fontFamily: 'Consolas',
          height: heightFactor,
        ),
      ),
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle(
        fontSize: fontSize,
        height: heightFactor,
        fontFamily: 'Consolas',
        forceStrutHeight: true,
      ),
    )..layout();
    return _visualCenterFromTop(tp, fallback: plh / 2);
  }

  /// 字形视觉中心距 paint 顶（汉字接近占满 ascent，重心约在 0.42*ascent 处）。
  double _visualCenterFromTop(TextPainter tp, {required double fallback}) {
    final metrics = tp.computeLineMetrics();
    if (metrics.isNotEmpty) {
      final m = metrics.first;
      return m.baseline - m.ascent * 0.42;
    }
    final baseline =
        tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
    if (baseline != null) return baseline * 0.55;
    return fallback;
  }

  @override
  bool shouldRepaint(covariant _LineNumberPainter old) =>
      old.text != text ||
      old.lineCount != lineCount ||
      old.scrollOffset != scrollOffset ||
      old.fontSize != fontSize ||
      old.lineHeight != lineHeight ||
      old.activeLine != activeLine ||
      old.muted != muted ||
      old.active != active;
}
