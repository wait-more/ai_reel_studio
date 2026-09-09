import 'package:flutter/material.dart';

/// 路径过长时从左侧省略、保留尾部（按父级可用宽度计算，含旁边按钮已占宽度）；
/// 悬停显示完整文本。
class PathEllipsisText extends StatelessWidget {
  const PathEllipsisText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.tooltip = true,
    this.waitDuration = const Duration(milliseconds: 350),
  });

  final String text;
  final TextStyle? style;
  final int maxLines;
  final bool tooltip;
  final Duration waitDuration;

  @override
  Widget build(BuildContext context) {
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);

    final child = LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        if (!maxW.isFinite || maxW <= 0) {
          return Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            softWrap: maxLines > 1,
            style: effective,
          );
        }
        final display = _fitKeepingTail(
          text: text,
          style: effective,
          maxWidth: maxW,
          maxLines: maxLines,
          textScaler: scaler,
        );
        return Text(
          display,
          maxLines: maxLines,
          softWrap: maxLines > 1,
          overflow: TextOverflow.clip,
          style: effective,
          textAlign: TextAlign.left,
        );
      },
    );

    final tip = text.trim();
    if (!tooltip || tip.isEmpty) return child;
    return Tooltip(
      message: tip,
      waitDuration: waitDuration,
      child: child,
    );
  }

  /// 在 [maxWidth] 内尽量保留尾部，放不下时前缀 `…`。
  static String _fitKeepingTail({
    required String text,
    required TextStyle style,
    required double maxWidth,
    required int maxLines,
    required TextScaler textScaler,
  }) {
    bool fits(String s) {
      final painter = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: maxLines,
      )..layout(maxWidth: maxWidth);
      return !painter.didExceedMaxLines && painter.width <= maxWidth + 0.5;
    }

    if (text.isEmpty || fits(text)) return text;

    const ellipsis = '…';
    if (!fits(ellipsis)) return ellipsis;

    var lo = 0;
    var hi = text.length;
    var best = ellipsis;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      final candidate = '$ellipsis${text.substring(text.length - mid)}';
      if (fits(candidate)) {
        best = candidate;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }
}
