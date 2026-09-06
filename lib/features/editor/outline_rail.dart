import 'dart:async';

import 'package:flutter/material.dart';

import 'markdown_outline.dart';

/// 文档大纲轨：默认窄热区，悬停展开；可钉住；点击跳转；高亮当前章节。
class OutlineRail extends StatefulWidget {
  final List<OutlineHeading> headings;
  final int activeIndex;
  final bool pinned;
  final ValueChanged<bool> onPinnedChanged;
  final ValueChanged<OutlineHeading> onJump;
  final double panelWidth;

  const OutlineRail({
    super.key,
    required this.headings,
    required this.activeIndex,
    required this.pinned,
    required this.onPinnedChanged,
    required this.onJump,
    this.panelWidth = 200,
  });

  static const hotZoneWidth = 12.0;

  @override
  State<OutlineRail> createState() => _OutlineRailState();
}

class _OutlineRailState extends State<OutlineRail> {
  bool _hoverOpen = false;
  Timer? _openTimer;
  Timer? _closeTimer;
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant OutlineRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pinned) {
      _removeOverlay();
      _hoverOpen = false;
    } else if (_hoverOpen) {
      _overlay?.markNeedsBuild();
    }
    // 标题列表 / 高亮变化时刷新浮层
    if (_overlay != null &&
        (oldWidget.headings != widget.headings ||
            oldWidget.activeIndex != widget.activeIndex)) {
      _overlay!.markNeedsBuild();
    }
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  void _ensureOverlay() {
    if (_overlay != null || widget.pinned) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    if (overlayState == null) return;

    final origin = box.localToGlobal(Offset.zero);
    final height = box.size.height;

    _overlay = OverlayEntry(
      builder: (ctx) {
        // 每次 build 取最新 widget 状态
        final rail = context.findAncestorStateOfType<_OutlineRailState>();
        final w = rail?.widget ?? widget;
        return Positioned(
          left: origin.dx,
          top: origin.dy,
          width: w.panelWidth,
          height: height,
          child: MouseRegion(
            onEnter: (_) {
              _closeTimer?.cancel();
              _hoverOpen = true;
            },
            onExit: (_) => _scheduleClose(),
            child: Material(
              elevation: 8,
              shadowColor: Colors.black45,
              color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
              child: _panel(ctx, w),
            ),
          ),
        );
      },
    );
    overlayState.insert(_overlay!);
  }

  void _scheduleOpen() {
    _closeTimer?.cancel();
    if (widget.pinned || _hoverOpen) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || widget.pinned) return;
      setState(() => _hoverOpen = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureOverlay();
      });
    });
  }

  void _scheduleClose() {
    _openTimer?.cancel();
    if (widget.pinned) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      _removeOverlay();
      setState(() => _hoverOpen = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pinned) {
      return SizedBox(
        width: widget.panelWidth,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            border: Border(
              right: BorderSide(
                color: Theme.of(context).dividerColor.withValues(alpha: 0.35),
              ),
            ),
          ),
          child: _panel(context, widget),
        ),
      );
    }

    return SizedBox(
      width: OutlineRail.hotZoneWidth,
      child: MouseRegion(
        onEnter: (_) => _scheduleOpen(),
        onExit: (_) => _scheduleClose(),
        child: _hotZone(context),
      ),
    );
  }

  Widget _hotZone(BuildContext context) {
    final theme = Theme.of(context);
    final has = widget.headings.isNotEmpty;
    return Container(
      width: OutlineRail.hotZoneWidth,
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      child: Column(
        children: [
          const SizedBox(height: 8),
          Icon(
            Icons.list_alt,
            size: 12,
            color: theme.colorScheme.onSurfaceVariant.withValues(
              alpha: has ? 0.7 : 0.35,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: has
                ? CustomPaint(
                    painter: _OutlineTicksPainter(
                      count: widget.headings.length,
                      activeIndex: widget.activeIndex,
                      color: theme.colorScheme.primary,
                      muted: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.35),
                    ),
                    child: const SizedBox.expand(),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _panel(BuildContext context, OutlineRail w) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              const SizedBox(width: 8),
              Text(
                '大纲',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: w.pinned ? '取消钉住' : '钉住大纲',
                icon: Icon(
                  w.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 16,
                  color: w.pinned
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () {
                  final next = !w.pinned;
                  if (next) _removeOverlay();
                  w.onPinnedChanged(next);
                },
              ),
            ],
          ),
        ),
        Divider(height: 1, color: theme.dividerColor.withValues(alpha: 0.4)),
        Expanded(
          child: w.headings.isEmpty
              ? Center(
                  child: Text(
                    '暂无标题',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ListView.builder(
                  primary: false,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: w.headings.length,
                  itemBuilder: (context, i) {
                    final h = w.headings[i];
                    final active = i == w.activeIndex;
                    return InkWell(
                      onTap: () {
                        w.onJump(h);
                        if (!w.pinned) {
                          _removeOverlay();
                          setState(() => _hoverOpen = false);
                        }
                      },
                      child: Container(
                        padding: EdgeInsets.only(
                          left: 8.0 + (h.level - 1) * 10.0,
                          right: 8,
                          top: 5,
                          bottom: 5,
                        ),
                        color: active
                            ? theme.colorScheme.primary.withValues(alpha: 0.14)
                            : null,
                        child: Text(
                          h.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: h.level <= 2 ? 12.5 : 12,
                            fontWeight: active || h.level <= 2
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: active
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurface
                                    .withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _OutlineTicksPainter extends CustomPainter {
  final int count;
  final int activeIndex;
  final Color color;
  final Color muted;

  _OutlineTicksPainter({
    required this.count,
    required this.activeIndex,
    required this.color,
    required this.muted,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (count <= 0) return;
    final gap = size.height / (count + 1);
    for (var i = 0; i < count; i++) {
      final y = gap * (i + 1);
      final active = i == activeIndex;
      final paint = Paint()
        ..color = active ? color : muted
        ..strokeWidth = active ? 2 : 1
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(3, y),
        Offset(size.width - 3, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OutlineTicksPainter old) =>
      old.count != count ||
      old.activeIndex != activeIndex ||
      old.color != color ||
      old.muted != muted;
}
