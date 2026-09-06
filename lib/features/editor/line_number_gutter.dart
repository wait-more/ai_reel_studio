import 'package:flutter/material.dart';

/// 行号槽：由外部传入 [scrollOffset]，不挂载 ScrollController（避免多 ScrollView 冲突）。
class LineNumberGutter extends StatelessWidget {
  final double scrollOffset;
  final int lineCount;
  final double fontSize;
  final double lineHeightFactor;
  final EdgeInsets contentPadding;
  final int? activeLine; // 0-based，当前光标行

  const LineNumberGutter({
    super.key,
    required this.scrollOffset,
    required this.lineCount,
    required this.fontSize,
    this.lineHeightFactor = 1.6,
    this.contentPadding = const EdgeInsets.all(8),
    this.activeLine,
  });

  double get _lineHeight => fontSize * lineHeightFactor;

  double get _width {
    final digits = lineCount.toString().length.clamp(2, 6);
    return digits * fontSize * 0.62 + 16;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45);
    final active = theme.colorScheme.primary;

    return SizedBox(
      width: _width,
      child: ClipRect(
        child: CustomPaint(
          painter: _LineNumberPainter(
            lineCount: lineCount,
            lineHeight: _lineHeight,
            fontSize: fontSize,
            scrollOffset: scrollOffset,
            topPadding: contentPadding.top,
            muted: muted,
            active: active,
            activeLine: activeLine,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _LineNumberPainter extends CustomPainter {
  final int lineCount;
  final double lineHeight;
  final double fontSize;
  final double scrollOffset;
  final double topPadding;
  final Color muted;
  final Color active;
  final int? activeLine;

  _LineNumberPainter({
    required this.lineCount,
    required this.lineHeight,
    required this.fontSize,
    required this.scrollOffset,
    required this.topPadding,
    required this.muted,
    required this.active,
    required this.activeLine,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (lineCount <= 0) return;

    final first =
        ((scrollOffset - topPadding) / lineHeight).floor().clamp(0, lineCount - 1);
    final visible = (size.height / lineHeight).ceil() + 2;
    final last = (first + visible).clamp(0, lineCount);

    for (var i = first; i < last; i++) {
      final y = topPadding + i * lineHeight - scrollOffset;
      if (y + lineHeight < 0 || y > size.height) continue;

      final isActive = activeLine == i;
      final tp = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: isActive ? active : muted,
            fontSize: fontSize * 0.85,
            fontFamily: 'Consolas',
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: size.width - 6);

      final dy = y + (lineHeight - tp.height) / 2;
      tp.paint(canvas, Offset(size.width - tp.width - 8, dy));
    }
  }

  @override
  bool shouldRepaint(covariant _LineNumberPainter old) =>
      old.lineCount != lineCount ||
      old.lineHeight != lineHeight ||
      old.fontSize != fontSize ||
      old.scrollOffset != scrollOffset ||
      old.activeLine != activeLine ||
      old.muted != muted ||
      old.active != active;
}
