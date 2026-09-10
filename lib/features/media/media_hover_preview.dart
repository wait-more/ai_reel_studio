import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../core/media_types.dart';
import 'media_preview.dart';

/// 全局同时只保留一个悬停预览 Overlay。
OverlayEntry? _activeHoverPreview;
VoidCallback? _activeHoverDismiss;

void dismissActiveMediaHoverPreview() {
  final dismiss = _activeHoverDismiss;
  _activeHoverDismiss = null;
  _activeHoverPreview = null;
  dismiss?.call();
}

/// 包在文件行上：悬停延迟弹出预览小窗（图直接预览；视频点播放才挂 Player）。
class MediaHoverPreviewAnchor extends StatefulWidget {
  final String path;
  final Widget child;
  final VoidCallback? onOpenFullscreen;

  const MediaHoverPreviewAnchor({
    super.key,
    required this.path,
    required this.child,
    this.onOpenFullscreen,
  });

  @override
  State<MediaHoverPreviewAnchor> createState() =>
      _MediaHoverPreviewAnchorState();
}

class _MediaHoverPreviewAnchorState extends State<MediaHoverPreviewAnchor> {
  final GlobalKey _anchorKey = GlobalKey();
  Timer? _openTimer;
  Timer? _closeTimer;
  OverlayEntry? _entry;
  bool _overAnchor = false;
  bool _overPopup = false;
  bool _playing = false;

  @override
  void dispose() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _removeOverlay(disposeOnly: true);
    super.dispose();
  }

  void _removeOverlay({bool disposeOnly = false}) {
    if (_entry == null) return;
    if (_activeHoverPreview == _entry) {
      _activeHoverPreview = null;
    }
    if (_activeHoverDismiss == _dismiss) {
      _activeHoverDismiss = null;
    }
    _entry!.remove();
    _entry = null;
    _playing = false;
  }

  void _scheduleOpen() {
    _closeTimer?.cancel();
    if (_entry != null) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: 200), _showOverlay);
  }

  void _scheduleCloseIfIdle() {
    _openTimer?.cancel();
    if (_playing) return; // 播放中不因移出自动关
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      if (_overAnchor || _overPopup || _playing) return;
      _removeOverlay();
    });
  }

  void _dismiss() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _overPopup = false;
    // 不强制清 _overAnchor：指针可能仍在图标上（无全屏挡板时）。
    _removeOverlay();
  }

  void _showOverlay() {
    if (!mounted || _entry != null) return;
    if (!_overAnchor) return;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    if (overlayState == null) return;

    // 关掉其它锚点的预览（会走对方完整 _dismiss，避免 _entry 悬空）。
    if (_activeHoverDismiss != null && _activeHoverDismiss != _dismiss) {
      dismissActiveMediaHoverPreview();
    }

    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);
    const popupW = 400.0;
    const popupH = 225.0;
    var left = origin.dx;
    var top = origin.dy + size.height + 4;
    if (left + popupW > screen.width - 8) {
      left = screen.width - popupW - 8;
    }
    if (left < 8) left = 8;
    if (top + popupH > screen.height - 8) {
      top = origin.dy - popupH - 4;
    }
    if (top < 8) top = 8;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => _HoverPreviewLayer(
        left: left,
        top: top,
        width: popupW,
        height: popupH,
        path: widget.path,
        onOverPopup: (v) {
          _overPopup = v;
          if (v) {
            _closeTimer?.cancel();
          } else {
            _scheduleCloseIfIdle();
          }
        },
        onPlayingChanged: (v) {
          _playing = v;
          if (!v) _scheduleCloseIfIdle();
        },
        onDismiss: _dismiss,
        onFullscreen: () {
          final path = widget.path;
          _dismiss();
          final kind = classifyMedia(path);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!context.mounted) return;
            if (kind == MediaKind.image) {
              showImageViewerDialog(context, path);
            } else if (kind == MediaKind.video || kind == MediaKind.audio) {
              showMediaPreviewDialog(
                context,
                path: path,
                isVideo: kind == MediaKind.video,
              );
            }
            widget.onOpenFullscreen?.call();
          });
        },
      ),
    );
    _entry = entry;
    _activeHoverPreview = entry;
    _activeHoverDismiss = _dismiss;
    overlayState.insert(entry);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      key: _anchorKey,
      onEnter: (_) {
        _overAnchor = true;
        _scheduleOpen();
      },
      onExit: (_) {
        _overAnchor = false;
        _scheduleCloseIfIdle();
      },
      child: widget.child,
    );
  }
}

class _HoverPreviewLayer extends StatefulWidget {
  final double left;
  final double top;
  final double width;
  final double height;
  final String path;
  final ValueChanged<bool> onOverPopup;
  final ValueChanged<bool> onPlayingChanged;
  final VoidCallback onDismiss;
  final VoidCallback onFullscreen;

  const _HoverPreviewLayer({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.path,
    required this.onOverPopup,
    required this.onPlayingChanged,
    required this.onDismiss,
    required this.onFullscreen,
  });

  @override
  State<_HoverPreviewLayer> createState() => _HoverPreviewLayerState();
}

class _HoverPreviewLayerState extends State<_HoverPreviewLayer> {
  final FocusNode _focus = FocusNode();
  final GlobalKey _popupKey = GlobalKey();
  Player? _player;
  VideoController? _video;
  bool _ready = false;
  bool _starting = false;

  MediaKind get _kind => classifyMedia(widget.path);

  bool get _isAv =>
      _kind == MediaKind.video || _kind == MediaKind.audio;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      if (_isAv) unawaited(_startPlayer());
    });
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    _focus.dispose();
    unawaited(_disposePlayer());
    super.dispose();
  }

  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerDownEvent) return;
    final box = _popupKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > box.size.width ||
        local.dy > box.size.height) {
      widget.onDismiss();
    }
  }

  Future<void> _disposePlayer() async {
    final player = _player;
    _player = null;
    _video = null;
    if (player != null) {
      try {
        await player.dispose();
      } catch (_) {}
    }
  }

  Future<void> _startPlayer() async {
    if (!_isAv || _starting || _ready) return;
    if (!File(widget.path).existsSync()) return;
    setState(() => _starting = true);
    final player = Player();
    final video = VideoController(player);
    try {
      await player.open(Media(widget.path), play: true);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _video = video;
        _ready = true;
        _starting = false;
      });
      // 音视频打开后视为「在播」，移出不自动关。
      widget.onPlayingChanged(true);
    } catch (_) {
      await player.dispose();
      if (mounted) setState(() => _starting = false);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _floatingBtn({
    required IconData icon,
    required String tip,
    required VoidCallback onPressed,
  }) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        tooltip: tip,
        icon: Icon(icon, size: 18, color: Colors.white),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.all(8),
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        onPressed: onPressed,
      ),
    );
  }

  Widget _imageBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: Image.file(
            File(widget.path),
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Center(child: Icon(Icons.broken_image, size: 48)),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _floatingBtn(
                icon: Icons.zoom_out_map,
                tip: '放大',
                onPressed: widget.onFullscreen,
              ),
              const SizedBox(width: 6),
              _floatingBtn(
                icon: Icons.close,
                tip: '关闭 (Esc)',
                onPressed: widget.onDismiss,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _avBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_ready && _video != null)
          Video(
            controller: _video!,
            // 自带播放 / 音量 / 进度 / 全屏，不再外包一层窗口控件。
            controls: AdaptiveVideoControls,
          )
        else
          ColoredBox(
            color: Colors.black,
            child: Center(
              child: _starting
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _kind == MediaKind.audio
                          ? Icons.audiotrack
                          : Icons.videocam_outlined,
                      size: 48,
                      color: Colors.white54,
                    ),
            ),
          ),
        Positioned(
          top: 6,
          right: 6,
          child: _floatingBtn(
            icon: Icons.close,
            tip: '关闭 (Esc)',
            onPressed: widget.onDismiss,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned(
            left: widget.left,
            top: widget.top,
            width: widget.width,
            height: widget.height,
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _onKey,
              child: MouseRegion(
                onEnter: (_) => widget.onOverPopup(true),
                onExit: (_) => widget.onOverPopup(false),
                child: Material(
                  key: _popupKey,
                  elevation: 10,
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                  clipBehavior: Clip.antiAlias,
                  child: _kind == MediaKind.image ? _imageBody() : _avBody(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输出文件行：图标 + 名；悬停预览。
class MediaOutputFileRow extends StatelessWidget {
  final String path;
  final TextStyle? style;

  const MediaOutputFileRow({
    super.key,
    required this.path,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final kind = classifyMedia(path);
    final icon = switch (kind) {
      MediaKind.image => Icons.image_outlined,
      MediaKind.video => Icons.videocam_outlined,
      MediaKind.audio => Icons.audiotrack,
      _ => Icons.insert_drive_file_outlined,
    };
    final name = p.basename(path);
    final row = Row(
      children: [
        Icon(icon, size: 14, color: style?.color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );

    if (kind == MediaKind.image ||
        kind == MediaKind.video ||
        kind == MediaKind.audio) {
      return MediaHoverPreviewAnchor(path: path, child: row);
    }
    return row;
  }
}

/// 固定宽度的媒体预览锚点图标（约 28px），便于 [PathEllipsisText] 所在
/// [Expanded] 正确拿到剩余宽度；点击被吞掉，不触发展开等父手势。
class MediaHoverPreviewIcon extends StatelessWidget {
  final String path;
  final double extent;
  final String? tooltip;

  const MediaHoverPreviewIcon({
    super.key,
    required this.path,
    this.extent = 28,
    this.tooltip,
  });

  static bool canPreview(String? path) {
    final s = path?.trim() ?? '';
    if (s.isEmpty) return false;
    if (!File(s).existsSync()) return false;
    final kind = classifyMedia(s);
    return kind == MediaKind.image ||
        kind == MediaKind.video ||
        kind == MediaKind.audio;
  }

  @override
  Widget build(BuildContext context) {
    if (!canPreview(path)) return const SizedBox.shrink();
    final kind = classifyMedia(path);
    final icon = switch (kind) {
      MediaKind.image => Icons.image_outlined,
      MediaKind.video => Icons.videocam_outlined,
      MediaKind.audio => Icons.audiotrack,
      _ => Icons.insert_drive_file_outlined,
    };
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: extent,
      height: extent,
      child: MediaHoverPreviewAnchor(
        path: path,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {},
          child: Center(
            child: Icon(icon, size: 16, color: cs.primary),
          ),
        ),
      ),
    );
  }
}
