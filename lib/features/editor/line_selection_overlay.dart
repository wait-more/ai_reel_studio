import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'wrap_line_metrics.dart';

/// 失焦时按 [RenderEditable] 字符选区盒绘制高亮（与原生选区同形，非整行）。
class SelectionHighlightOverlay extends StatefulWidget {
  final GlobalKey editorFieldKey;
  final TextSelection selection;
  final Color color;
  /// 滚动变化时触发重绘。
  final double scrollOffset;

  const SelectionHighlightOverlay({
    super.key,
    required this.editorFieldKey,
    required this.selection,
    required this.color,
    required this.scrollOffset,
  });

  @override
  State<SelectionHighlightOverlay> createState() =>
      _SelectionHighlightOverlayState();
}

class _SelectionHighlightOverlayState extends State<SelectionHighlightOverlay> {
  final GlobalKey _layerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant SelectionHighlightOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selection != widget.selection ||
        oldWidget.scrollOffset != widget.scrollOffset) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        key: _layerKey,
        painter: _SelectionBoxesPainter(
          layerKey: _layerKey,
          editorFieldKey: widget.editorFieldKey,
          selection: widget.selection,
          color: widget.color,
          scrollOffset: widget.scrollOffset,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _SelectionBoxesPainter extends CustomPainter {
  final GlobalKey layerKey;
  final GlobalKey editorFieldKey;
  final TextSelection selection;
  final Color color;
  final double scrollOffset;

  _SelectionBoxesPainter({
    required this.layerKey,
    required this.editorFieldKey,
    required this.selection,
    required this.color,
    required this.scrollOffset,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!selection.isValid || selection.isCollapsed) return;

    final layerBox = layerKey.currentContext?.findRenderObject() as RenderBox?;
    final editable = findRenderEditable(
      editorFieldKey.currentContext?.findRenderObject(),
    );
    if (layerBox == null ||
        editable == null ||
        !editable.hasSize ||
        !layerBox.hasSize) {
      return;
    }

    final boxes = editable.getBoxesForSelection(selection);
    if (boxes.isEmpty) return;

    final paint = Paint()..color = color;
    for (final b in boxes) {
      final topLeft = editable.localToGlobal(Offset(b.left, b.top));
      final bottomRight = editable.localToGlobal(Offset(b.right, b.bottom));
      final localTL = layerBox.globalToLocal(topLeft);
      final localBR = layerBox.globalToLocal(bottomRight);
      final rect = Rect.fromPoints(localTL, localBR);
      if (rect.bottom < 0 || rect.top > size.height) continue;
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SelectionBoxesPainter old) =>
      old.selection != selection ||
      old.scrollOffset != scrollOffset ||
      old.color != color;
}
