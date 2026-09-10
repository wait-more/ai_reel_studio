import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../core/media_types.dart';
import 'media_preview.dart';

/// 全局同时只保留一个悬停预览 Overlay。
OverlayEntry? _activeHoverPreview;

void dismissActiveMediaHoverPreview() {
  _activeHoverPreview?.remove();
  _activeHoverPreview = null;
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
    _entry!.remove();
    _entry = null;
    _playing = false;
    if (!disposeOnly && mounted) {
      // no setState needed; overlay gone
    }
  }

  void _scheduleOpen() {
    _closeTimer?.cancel();
    if (_entry != null) return;
    _openTimer?.cancel();
    _openTimer = Timer(const Duration(milliseconds: 180), _showOverlay);
  }

  void _scheduleCloseIfIdle() {
    _openTimer?.cancel();
    if (_playing) return; // 播放中不因移出自动关
    _closeTimer?.cancel();
    _closeTimer = Timer(const Duration(milliseconds: 280), () {
      if (_overAnchor || _overPopup || _playing) return;
      _removeOverlay();
    });
  }

  void _dismiss() {
    _openTimer?.cancel();
    _closeTimer?.cancel();
    _overAnchor = false;
    _overPopup = false;
    _removeOverlay();
  }

  void _showOverlay() {
    if (!mounted || _entry != null) return;
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlayState = Overlay.maybeOf(context, rootOverlay: true);
    if (overlayState == null) return;

    dismissActiveMediaHoverPreview();

    final origin = box.localToGlobal(Offset.zero);
    final size = box.size;
    final screen = MediaQuery.sizeOf(context);
    const popupW = 320.0;
    const popupH = 240.0;
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
  Player? _player;
  VideoController? _video;
  bool _playing = false;
  bool _starting = false;

  MediaKind get _kind => classifyMedia(widget.path);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _disposePlayer();
    super.dispose();
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

  Future<void> _startPlay() async {
    if (_kind != MediaKind.video || _starting || _playing) return;
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
        _playing = true;
        _starting = false;
      });
      widget.onPlayingChanged(true);
    } catch (_) {
      await player.dispose();
      if (mounted) {
        setState(() => _starting = false);
      }
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

  Widget _poster() {
    if (_kind == MediaKind.image) {
      return Image.file(
        File(widget.path),
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, size: 48),
      );
    }
    if (_kind == MediaKind.video) {
      return const Center(
        child: Icon(Icons.videocam_outlined, size: 56, color: Colors.white54),
      );
    }
    if (_kind == MediaKind.audio) {
      return const Center(
        child: Icon(Icons.audiotrack, size: 56, color: Colors.white54),
      );
    }
    return const Center(
      child: Icon(Icons.insert_drive_file, size: 48, color: Colors.white54),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final name = p.basename(widget.path);

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          // 点外部关闭
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
              child: const SizedBox.expand(),
            ),
          ),
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
                  elevation: 8,
                  borderRadius: BorderRadius.circular(10),
                  color: Colors.black87,
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      SizedBox(
                        height: 36,
                        child: Row(
                          children: [
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭 (Esc)',
                              icon: const Icon(Icons.close, size: 18),
                              color: Colors.white70,
                              visualDensity: VisualDensity.compact,
                              onPressed: widget.onDismiss,
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ColoredBox(
                          color: Colors.black,
                          child: _playing && _video != null
                              ? Video(controller: _video!)
                              : _poster(),
                        ),
                      ),
                      SizedBox(
                        height: 40,
                        child: Row(
                          children: [
                            const SizedBox(width: 8),
                            if (_kind == MediaKind.video) ...[
                              TextButton.icon(
                                onPressed: _starting ? null : _startPlay,
                                icon: Icon(
                                  _playing
                                      ? Icons.play_circle_outline
                                      : Icons.play_arrow,
                                  size: 18,
                                ),
                                label: Text(_playing
                                    ? '播放中'
                                    : (_starting ? '加载…' : '播放')),
                                style: TextButton.styleFrom(
                                  foregroundColor: cs.primary,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                              TextButton.icon(
                                onPressed: widget.onFullscreen,
                                icon: const Icon(Icons.fullscreen, size: 18),
                                label: const Text('全屏'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ] else if (_kind == MediaKind.image) ...[
                              TextButton.icon(
                                onPressed: widget.onFullscreen,
                                icon: const Icon(Icons.zoom_out_map, size: 18),
                                label: const Text('放大'),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ] else if (_kind == MediaKind.audio) ...[
                              TextButton.icon(
                                onPressed: widget.onFullscreen,
                                icon: const Icon(Icons.play_arrow, size: 18),
                                label: const Text('播放'),
                                style: TextButton.styleFrom(
                                  foregroundColor: cs.primary,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ],
                            const Spacer(),
                          ],
                        ),
                      ),
                    ],
                  ),
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
