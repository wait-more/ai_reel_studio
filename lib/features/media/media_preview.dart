import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/video_frame_extract.dart';
import '../../core/toast.dart';

/// 打开媒体预览对话框（视频/音频内嵌播放）。
///
/// 功能：
/// - 音视频同步播放、暂停
/// - 细粒度进度控制（毫秒级拖动/±5s 步进）
/// - 快捷键：Esc 关闭、Ctrl+Shift+Home 提取首帧、Ctrl+Shift+End 提取末帧、
///   Ctrl+S 截取当前帧、空格播放/暂停、←/→ ±5s
/// - 截帧保存为 PNG 到媒体同目录，并通知 [onChanged] 刷新网格/树
Future<void> showMediaPreviewDialog(
  BuildContext context, {
  required String path,
  required bool isVideo,
  VoidCallback? onChanged,
}) async {
  await showDialog(
    context: context,
    barrierDismissible: true,
    builder: (_) => MediaPreviewDialog(
      path: path,
      isVideo: isVideo,
      onChanged: onChanged,
    ),
  );
}

/// 打开图片查看对话框（可缩放；Esc 关闭）。
void showImageViewerDialog(BuildContext context, String path) {
  showDialog(
    context: context,
    barrierDismissible: true,
    builder: (dialogCtx) => Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.pop(dialogCtx);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(24),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4,
                child: Image.file(File(path), fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                tooltip: '关闭 (Esc)',
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.pop(dialogCtx),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// 独立提取媒体某一帧并保存 PNG（目录树右键 / 播放页共用）。
///
/// 使用应用内置 OpenCV（opencv_dart / dartcv）解码，不经过播放器截屏。
Future<String?> extractMediaFrame({
  required String path,
  Duration? target,
  bool lastFrame = false,
  String? tag,
}) async {
  final base = '${Directory(path).parent.path}${Platform.pathSeparator}'
      '${_stemOf(path)}${tag == null ? '' : '_$tag'}';
  final file = await dedupTargetFile(base);

  final ok = await VideoFrameExtract.extract(
    videoPath: path,
    outputPng: file.path,
    lastFrame: lastFrame,
    at: lastFrame ? null : target,
  );
  return ok ? file.path : null;
}

/// 从文件名去除扩展名。
String _stemOf(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 以 [basePath].png 为目标，若已存在则依次加 _2/_3... 后缀去重。
Future<File> dedupTargetFile(String basePath) async {
  var file = File('$basePath.png');
  var i = 2;
  while (await file.exists()) {
    file = File('${basePath}_$i.png');
    i++;
  }
  return file;
}

class MediaPreviewDialog extends StatefulWidget {
  final String path;
  final bool isVideo;
  final VoidCallback? onChanged;

  const MediaPreviewDialog({
    super.key,
    required this.path,
    required this.isVideo,
    this.onChanged,
  });

  @override
  State<MediaPreviewDialog> createState() => _MediaPreviewDialogState();
}

class _MediaPreviewDialogState extends State<MediaPreviewDialog> {
  late final Player _player;
  VideoController? _videoController;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _opened = false;
  bool _busy = false; // 截图/提取操作进行中（防连点）
  double? _dragValue; // 拖动进度条时的预览值（0-1）

  String get _name => widget.path.split(Platform.pathSeparator).last;
  String get _stem => _name.contains('.')
      ? _name.substring(0, _name.lastIndexOf('.'))
      : _name;
  String get _dir => Directory(widget.path).parent.path;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<String>? _errSub;
  StreamSubscription<void>? _endSub;

  @override
  void initState() {
    super.initState();
    _player = Player();
    // 视频必须先挂 VideoController，再 open；否则首帧解码时无渲染表面，
    // 会出现「有比例的黑屏」，播过其它片后再开又正常（解码器/上下文被热起来）。
    if (widget.isVideo) {
      _videoController = VideoController(_player);
    }
    _subcribeEvents();
    _open();
  }

  void _subcribeEvents() {
    _posSub = _player.stream.position.listen((p) {
      if (!mounted || _dragValue != null) return;
      setState(() => _position = p);
    });
    _durSub = _player.stream.duration.listen((p) {
      if (!mounted) return;
      setState(() => _duration = p);
    });
    _playSub = _player.stream.playing.listen((p) {
      if (!mounted) return;
      setState(() => _playing = p);
    });
    _errSub = _player.stream.error.listen((e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('播放错误：$e', style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ));
    });
    _endSub = _player.stream.completed.listen((_) {
      if (mounted) setState(() => _position = _duration);
    });
  }

  /// 覆盖 media_kit 硬编码默认值（必须在 open 之前设置，last-write-wins）：
  /// - `cache-on-disk=no`：避免部分环境下磁盘缓存文件创建失败导致流选择失败
  /// - `audio-fallback-to-null=yes`：无声卡/音频设备失败时自动静音
  /// - `vid=auto`：确保选中视频轨（与静默截帧路径一致）
  /// - `hwdec=auto-safe`：降低个别编码首次硬解黑屏概率
  Future<void> _applyHardening() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('cache-on-disk', 'no');
    await platform.setProperty('audio-fallback-to-null', 'yes');
    if (widget.isVideo) {
      await platform.setProperty('vid', 'auto');
      await platform.setProperty('hwdec', 'auto-safe');
    }
  }

  Future<void> _open() async {
    try {
      await _applyHardening();
      // 等一帧，让 Video 控件先挂上 texture / platform view
      if (widget.isVideo) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }
      await _player.open(Media(widget.path), play: true);
      if (!mounted) return;
      setState(() => _opened = true);
      if (widget.isVideo) {
        await _ensureVideoVisible();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('无法打开媒体：$e', style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ));
    }
  }

  /// 打开后若长时间拿不到宽高，做一次轻量恢复（不换片源）。
  Future<void> _ensureVideoVisible() async {
    for (var i = 0; i < 25; i++) {
      if (!mounted) return;
      final w = _player.state.width ?? 0;
      final h = _player.state.height ?? 0;
      if (w > 0 && h > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (!mounted) return;
    try {
      // 轻推一下解码/渲染管线：停一下 → 回 0 → 再播
      await _player.pause();
      await _player.seek(Duration.zero);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      await _player.play();
      // 仍无尺寸则关掉硬解再试一次（部分机型/编码首次硬解会黑屏）
      final w2 = _player.state.width ?? 0;
      if (w2 <= 0) {
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty('hwdec', 'no');
        }
        await _player.stop();
        await _player.open(Media(widget.path), play: true);
      }
    } catch (_) {
      // 恢复失败不打断预览壳
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _errSub?.cancel();
    _endSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ── 播放控制 ──────────────────────────────────────────────

  void _togglePlay() {
    if (!_opened) return;
    _playing ? _player.pause() : _player.play();
  }

  void _seekBy(int seconds) {
    if (!_opened || _dragValue != null) return;
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    _player.seek(clamped);
  }

  void _finishDrag(double v) {
    _dragValue = null;
    if (!_opened) return;
    final target = Duration(
        milliseconds: (v * _duration.inMilliseconds.toDouble()).round());
    _player.seek(target);
    setState(() => _position = target);
  }

  // ── 截帧（与目录树右键同一条静默路径，不碰预览进度） ────

  Future<void> _extractSilent({
    required bool lastFrame,
    required String tag,
  }) async {
    if (_busy) {
      _toast('正在处理上一个操作，请稍候…');
      return;
    }
    setState(() => _busy = true);
    // 截帧时先停预览，避免双 Player 抢解码导致与目录树落点不一致
    final wasPlaying = _playing;
    try {
      await _player.pause();
      final path = await extractMediaFrame(
        path: widget.path,
        lastFrame: lastFrame,
        tag: tag,
      );
      if (!mounted) return;
      if (path == null) {
        final err = VideoFrameExtract.lastError;
        _toast(err != null && err.isNotEmpty
            ? '截图失败：$err'
            : (lastFrame ? '截图失败：未能取得末帧' : '截图失败：未取得帧数据'));
        return;
      }
      _toast('已保存：$path');
      widget.onChanged?.call();
    } catch (e) {
      _toast('截图失败：$e');
    } finally {
      if (wasPlaying) {
        try {
          await _player.play();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 当前帧：直接截取预览播放器当前画面，不 seek。
  Future<void> _currentFrame() async {
    if (_busy) {
      _toast('正在处理上一个操作，请稍候…');
      return;
    }
    setState(() => _busy = true);
    try {
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null) {
        _toast('截图失败：未取得帧数据');
        return;
      }
      final base = '$_dir${Platform.pathSeparator}${_stem}_帧';
      final file = await dedupTargetFile(base);
      await file.writeAsBytes(bytes, flush: true);
      _toast('已保存：${file.path}');
      widget.onChanged?.call();
    } catch (e) {
      _toast('截图失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _firstFrame() =>
      _extractSilent(lastFrame: false, tag: '首帧');
  Future<void> _lastFrame() =>
      _extractSilent(lastFrame: true, tag: '末帧');

  void _toast(String msg) {
    if (!mounted) return;
    // 全局置顶提示条：显示在所有弹窗之上（不依赖局部 ScaffoldMessenger）
    showGlobalToast(context, msg);
  }

  // ── 键盘快捷键 ────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.home) {
      _firstFrame();
      return KeyEventResult.handled;
    }
    if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.end) {
      _lastFrame();
      return KeyEventResult.handled;
    }
    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyS) {
      _currentFrame();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _seekBy(-5);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _seekBy(5);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = d.inMilliseconds.remainder(1000) ~/ 100;
    return '$m:$s.$ms';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: const Color(0xFF101014),
      // Dialog 无自己的 Scaffold，SnackBar 会绑到底层主窗体被遮挡；
      // 局部 ScaffoldMessenger + Scaffold 让提示显示在对话框层之上。
      child: ScaffoldMessenger(
        child: Scaffold(
          backgroundColor: const Color(0xFF101014),
          body: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(context),
                  Expanded(child: _buildVisual()),
                  _buildControls(context),
                  _buildShortcutHint(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(
            widget.isVideo ? Icons.videocam : Icons.audiotrack,
            size: 16,
            color: Colors.white70,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: Colors.white70),
            tooltip: '关闭 (Esc)',
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildVisual() {
    if (widget.isVideo && _videoController != null) {
      // 尽早挂上 Video，保证 open 时已有渲染表面
      return Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: _videoController!,
            controls: NoVideoControls,
            fit: BoxFit.contain,
          ),
          if (!_opened)
            const ColoredBox(
              color: Colors.black54,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white54,
                ),
              ),
            ),
        ],
      );
    }
    if (!_opened) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
      );
    }
    // 音频：画面区显示音符与文件名
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.music_note, size: 96, color: Colors.white24),
          const SizedBox(height: 12),
          Text(
            _name,
            style: const TextStyle(fontSize: 13, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final durationMs = _duration.inMilliseconds.toDouble();
    final shown = _dragValue ??
        (durationMs > 0
            ? (_position.inMilliseconds.toDouble() / durationMs).clamp(0.0, 1.0)
            : 0.0);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      color: Colors.black38,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.replay_5, size: 20, color: Colors.white),
                tooltip: '后退 5 秒 (←)',
                onPressed: _opened ? () => _seekBy(-5) : null,
              ),
              IconButton(
                icon: Icon(
                  _playing ? Icons.pause : Icons.play_arrow,
                  size: 26,
                  color: Colors.white,
                ),
                tooltip: '播放/暂停 (空格)',
                onPressed: _opened ? _togglePlay : null,
              ),
              IconButton(
                icon: const Icon(Icons.forward_5, size: 20, color: Colors.white),
                tooltip: '前进 5 秒 (→)',
                onPressed: _opened ? () => _seekBy(5) : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6),
                    activeTrackColor: Colors.teal,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.teal,
                  ),
                  child: Slider(
                    value: shown,
                    onChangeStart: (_) => _dragValue = shown,
                    onChanged: (v) => setState(() => _dragValue = v),
                    onChangeEnd: _finishDrag,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_fmt(_dragValue != null ? _duration * _dragValue! : _position)} / ${_fmt(_duration)}',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _actionButton(
                Icons.first_page,
                '提取首帧\n(Ctrl+Shift+Home)',
                _busy ? null : _firstFrame,
              ),
              const SizedBox(width: 10),
              _actionButton(
                Icons.last_page,
                '提取末帧\n(Ctrl+Shift+End)',
                _busy ? null : _lastFrame,
              ),
              const SizedBox(width: 10),
              _actionButton(
                Icons.photo_camera,
                '截取当前帧\n(Ctrl+S)',
                _busy ? null : _currentFrame,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback? onPressed) {
    return SizedBox(
      width: 130,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16, color: Colors.tealAccent),
        label: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.white70),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.white24),
          padding: const EdgeInsets.symmetric(vertical: 6),
        ),
      ),
    );
  }

  Widget _buildShortcutHint(BuildContext context) {
    return Container(
      height: 30,
      alignment: Alignment.center,
      child: Text(
        '空格 播放/暂停 · ←/→ 快退/快进 5s',
        style: TextStyle(fontSize: 11, color: Colors.white38),
      ),
    );
  }
}