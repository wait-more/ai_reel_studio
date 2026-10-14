import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/fresh_file_image.dart';
import '../../core/media_types.dart';

const double _kMinScale = 0.25;
const double _kMaxScale = 5.0;

/// 同目录下的图片路径（按文件名排序），找不到则退回单张。
List<String> siblingImagePaths(String path) {
  try {
    final parent = File(path).parent;
    final items = parent
        .listSync()
        .whereType<File>()
        .where((f) => classifyMedia(f.path) == MediaKind.image)
        .map((f) => f.path)
        .toList();
    items.sort((a, b) {
      final na = a.split(Platform.pathSeparator).last.toLowerCase();
      final nb = b.split(Platform.pathSeparator).last.toLowerCase();
      return na.compareTo(nb);
    });
    if (items.isEmpty) return [path];
    return items;
  } catch (_) {
    return [path];
  }
}

/// 打开图片查看器。
///
/// [gallery] 为当前文件夹里的图片列表（顺序应与界面显示一致）。
/// 省略时自动扫描同目录并按文件名排序。
void showImageViewerDialog(
  BuildContext context,
  String path, {
  List<String>? gallery,
}) {
  final paths = _normalizeGallery(path, gallery);
  final index =
      paths.indexWhere((p) => _samePath(p, path)).clamp(0, paths.length - 1);

  showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.black.withValues(alpha: 0.58),
    builder: (dialogCtx) => ImageViewerDialog(
      paths: paths,
      initialIndex: index,
    ),
  );
}

List<String> _normalizeGallery(String path, List<String>? gallery) {
  if (gallery == null || gallery.isEmpty) {
    return siblingImagePaths(path);
  }
  final paths = <String>[];
  final seen = <String>{};
  for (final p in gallery) {
    final key = p.toLowerCase();
    if (seen.add(key)) paths.add(p);
  }
  if (!paths.any((p) => _samePath(p, path))) {
    paths.insert(0, path);
  }
  return paths;
}

bool _samePath(String a, String b) =>
    a.replaceAll('/', '\\').toLowerCase() ==
    b.replaceAll('/', '\\').toLowerCase();

String _fileName(String path) => path.split(Platform.pathSeparator).last;

/// 居中画板式图片查看：有边界、适中画幅、底部切图、右侧缩放。
class ImageViewerDialog extends StatefulWidget {
  final List<String> paths;
  final int initialIndex;

  const ImageViewerDialog({
    super.key,
    required this.paths,
    required this.initialIndex,
  });

  @override
  State<ImageViewerDialog> createState() => _ImageViewerDialogState();
}

/// 自管平移/缩放，彻底绕开 InteractiveViewer 的滚轮双通道问题。
class _ViewXf {
  const _ViewXf({required this.scale, required this.offset});
  final double scale;
  final Offset offset;
}

class _ImageViewerDialogState extends State<ImageViewerDialog> {
  late int _index;
  late final ValueNotifier<_ViewXf> _view;
  Size _viewport = Size.zero;

  bool get _hasGallery => widget.paths.length > 1;
  bool get _canPrev => _index > 0;
  bool get _canNext => _index < widget.paths.length - 1;
  String get _path => widget.paths[_index];
  String get _name => _fileName(_path);
  double get _scale => _view.value.scale;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.paths.length - 1);
    _view = ValueNotifier(const _ViewXf(scale: 1, offset: Offset.zero));
  }

  @override
  void dispose() {
    _view.dispose();
    super.dispose();
  }

  void _resetTransform() {
    _view.value = const _ViewXf(scale: 1, offset: Offset.zero);
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.paths.length) return;
    setState(() {
      _index = next;
      _resetTransform();
    });
  }

  /// 绕 [focal]（视口局部坐标）缩放到 [newScale]，硬夹在 [_kMinScale, _kMaxScale]。
  void _zoomTo(double newScale, Offset focal) {
    final next = newScale.clamp(_kMinScale, _kMaxScale);
    final cur = _view.value;
    if ((next - cur.scale).abs() < 0.0001) return;
    final child = Offset(
      (focal.dx - cur.offset.dx) / cur.scale,
      (focal.dy - cur.offset.dy) / cur.scale,
    );
    _view.value = _ViewXf(
      scale: next,
      offset: Offset(
        focal.dx - child.dx * next,
        focal.dy - child.dy * next,
      ),
    );
  }

  void _setScale(double value) {
    final center = Offset(_viewport.width / 2, _viewport.height / 2);
    _zoomTo(value, center);
  }

  void _nudgeScale(double delta) => _setScale(_scale + delta);

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final factor = math.exp(-event.scrollDelta.dy / 200);
    _zoomTo(_scale * factor, event.localPosition);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final cur = _view.value;
    _view.value = _ViewXf(
      scale: cur.scale,
      offset: cur.offset + details.delta,
    );
  }

  void _close() => Navigator.of(context).pop();

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.equal ||
        key == LogicalKeyboardKey.numpadAdd ||
        key == LogicalKeyboardKey.add) {
      _nudgeScale(0.15);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.minus ||
        key == LogicalKeyboardKey.numpadSubtract) {
      _nudgeScale(-0.15);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      _resetTransform();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    // 居中画板：约占屏宽 72%、屏高 78%，留出明显边距
    final panelW = (size.width * 0.72).clamp(520.0, 1100.0);
    final panelH = (size.height * 0.78).clamp(420.0, 860.0);

    return Dialog.fullscreen(
      backgroundColor: Colors.transparent,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: const ColoredBox(color: Colors.transparent),
            ),
            Center(
              child: GestureDetector(
                onTap: () {}, // 阻止点到画板时关闭
                child: SizedBox(
                  width: panelW,
                  height: panelH,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 画板本体
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0xFF16181D),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                              width: 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.45),
                                blurRadius: 40,
                                offset: const Offset(0, 18),
                              ),
                              BoxShadow(
                                color: scheme.primary.withValues(alpha: 0.08),
                                blurRadius: 28,
                                spreadRadius: -4,
                              ),
                            ],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                // 底衬：透明图可见棋盘；不透明图被 contain 铺满一边后盖住
                                const CustomPaint(
                                  painter: _CheckerPainter(),
                                ),
                                // 自管 Transform：滚轮/拖拽/按钮同一套 scale，硬卡 25%–500%
                                Positioned.fill(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      _viewport = Size(
                                        constraints.maxWidth,
                                        constraints.maxHeight,
                                      );
                                      return Listener(
                                        onPointerSignal: _onPointerSignal,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onPanUpdate: _onPanUpdate,
                                          child: ClipRect(
                                            child: ValueListenableBuilder<_ViewXf>(
                                              valueListenable: _view,
                                              builder: (_, xf, __) {
                                                return Transform(
                                                  transform: Matrix4.identity()
                                                    ..translateByDouble(
                                                      xf.offset.dx,
                                                      xf.offset.dy,
                                                      0,
                                                      1,
                                                    )
                                                    ..scaleByDouble(
                                                      xf.scale,
                                                      xf.scale,
                                                      1,
                                                      1,
                                                    ),
                                                  child: SizedBox(
                                                    width:
                                                        constraints.maxWidth,
                                                    height:
                                                        constraints.maxHeight,
                                                    child: ProjectFileImage(
                                                      _path,
                                                      fit: BoxFit.contain,
                                                      width:
                                                          constraints.maxWidth,
                                                      height:
                                                          constraints.maxHeight,
                                                      errorBuilder:
                                                          (_, __, ___) =>
                                                              _BrokenImage(
                                                        name: _name,
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                                // 顶部轻量：文件名浮于图上，无实心横条
                                Positioned(
                                  top: 12,
                                  left: 48,
                                  right: 48,
                                  child: IgnorePointer(
                                    child: Text(
                                      _name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.92),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: 0.2,
                                        shadows: [
                                          Shadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.75),
                                            blurRadius: 10,
                                          ),
                                          Shadow(
                                            color: Colors.black
                                                .withValues(alpha: 0.45),
                                            blurRadius: 2,
                                            offset: const Offset(0, 1),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                Positioned(
                                  top: 10,
                                  right: 10,
                                  child: _CloseButton(onTap: _close),
                                ),
                                // 叠在图片中下部，不挤占显示区域
                                if (_hasGallery)
                                  Positioned(
                                    left: 0,
                                    right: 0,
                                    bottom: 18,
                                    child: Center(
                                      child: _BottomNavBar(
                                        canPrev: _canPrev,
                                        canNext: _canNext,
                                        label:
                                            '${_index + 1} / ${widget.paths.length}',
                                        onPrev: () => _go(-1),
                                        onNext: () => _go(1),
                                      ),
                                    ),
                                  ),
                                Positioned(
                                  right: 10,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(
                                    child: ValueListenableBuilder<_ViewXf>(
                                      valueListenable: _view,
                                      builder: (_, xf, __) => _ZoomRail(
                                        scale: xf.scale,
                                        onChanged: _setScale,
                                        onZoomIn: () => _nudgeScale(0.2),
                                        onZoomOut: () => _nudgeScale(-0.2),
                                        onReset: _resetTransform,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部居中的前后切换条（贴在图片中下部）。
class _BottomNavBar extends StatelessWidget {
  final bool canPrev;
  final bool canNext;
  final String label;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  const _BottomNavBar({
    required this.canPrev,
    required this.canNext,
    required this.label,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.28),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NavChip(
                icon: Icons.chevron_left_rounded,
                tooltip: '上一张 (←)',
                enabled: canPrev,
                onTap: onPrev,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              _NavChip(
                icon: Icons.chevron_right_rounded,
                tooltip: '下一张 (→)',
                enabled: canNext,
                onTap: onNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '关闭 (Esc)',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.08),
              border: Border.all(
                color: Colors.white.withValues(alpha: _hover ? 0.3 : 0.12),
              ),
            ),
            child: const Icon(Icons.close_rounded, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }
}

class _NavChip extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  const _NavChip({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_NavChip> createState() => _NavChipState();
}

class _NavChipState extends State<_NavChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.32,
          duration: const Duration(milliseconds: 140),
          child: GestureDetector(
            onTap: enabled ? widget.onTap : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(
                  alpha: _hover && enabled ? 0.2 : 0.08,
                ),
              ),
              child: Icon(widget.icon, color: Colors.white, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class _ZoomRail extends StatelessWidget {
  final double scale;
  final ValueChanged<double> onChanged;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  const _ZoomRail({
    required this.scale,
    required this.onChanged,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (scale * 100).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: 40,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ZoomIconButton(
                icon: Icons.add_rounded,
                tooltip: '放大 (+)',
                onTap: onZoomIn,
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 132,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                      activeTrackColor: Colors.white.withValues(alpha: 0.9),
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
                      thumbColor: Colors.white,
                      overlayColor: Colors.white.withValues(alpha: 0.12),
                    ),
                    child: Slider(
                      value: scale.clamp(_kMinScale, _kMaxScale),
                      min: _kMinScale,
                      max: _kMaxScale,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              _ZoomIconButton(
                icon: Icons.remove_rounded,
                tooltip: '缩小 (−)',
                onTap: onZoomOut,
              ),
              const SizedBox(height: 4),
              GestureDetector(
                onTap: onReset,
                child: Tooltip(
                  message: '重置缩放 (0)',
                  child: Text(
                    '$pct%',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ZoomIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ZoomIconButton> createState() => _ZoomIconButtonState();
}

class _ZoomIconButtonState extends State<_ZoomIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover
                  ? Colors.white.withValues(alpha: 0.18)
                  : Colors.transparent,
            ),
            child: Icon(widget.icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 淡棋盘底，让透明图和画板边界更清晰。
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const cell = 14.0;
    final a = Paint()..color = const Color(0xFF1C1F26);
    final b = Paint()..color = const Color(0xFF22262F);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        final odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
        canvas.drawRect(
          Rect.fromLTWH(x, y, cell + 0.5, cell + 0.5),
          odd ? a : b,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BrokenImage extends StatelessWidget {
  final String name;
  const _BrokenImage({required this.name});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      height: 200,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 40,
            color: Colors.white.withValues(alpha: 0.45),
          ),
          const SizedBox(height: 10),
          Text(
            '无法加载\n$name',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
