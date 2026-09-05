import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../../core/toast.dart';

/// 打开媒体预览对话框（视频/音频内嵌播放）。
///
/// 功能：
/// - 音视频同步播放、暂停
/// - 细粒度进度控制（毫秒级拖动/±5s 步进）
/// - 快捷键：Ctrl+Shift+Home 提取首帧、Ctrl+Shift+End 提取末帧、
///   Ctrl+S 截取当前帧
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

/// 打开图片查看对话框（可缩放）。
void showImageViewerDialog(BuildContext context, String path) {
  showDialog(
    context: context,
    builder: (_) => Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(24),
      child: InteractiveViewer(
        minScale: 0.5,
        maxScale: 4,
        child: Image.file(File(path), fit: BoxFit.contain),
      ),
    ),
  );
}

/// 独立提取媒体某一帧并保存 PNG 到媒体同目录（供右键菜单等无预览场景）。
///
/// 自建临时 Player，完成后释放。返回保存的文件路径，失败返回 null。
/// - [lastFrame]：为 true 时取末帧（回退 150ms 避免 completed 清屏）
/// - [target]：指定时间点；不传且非末帧则取首帧
/// - [tag]：文件名后缀（如 '首帧' → `<stem>_首帧.png`）
Future<String?> extractMediaFrame({
  required String path,
  Duration? target,
  bool lastFrame = false,
  String? tag,
}) async {
  final player = Player();
  try {
    // 与预览对话框一致的 hardening（无渲染表面时需 vid=auto 才能解码视频帧）
    final platform = player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty('cache-on-disk', 'no');
      await platform.setProperty('audio-fallback-to-null', 'yes');
      await platform.setProperty('vid', 'auto');
    }
    await player.open(Media(path));

    var dur = player.state.duration;
    for (var i = 0; i < 40 && dur == Duration.zero; i++) {
      await Future.delayed(const Duration(milliseconds: 200));
      dur = player.state.duration;
    }
    player.pause();

    final Duration eff;
    if (lastFrame) {
      eff = dur > const Duration(milliseconds: 300)
          ? dur - const Duration(milliseconds: 150)
          : dur;
    } else {
      eff = target ?? Duration.zero;
    }
    await player.seek(eff);
    // 等待 libmpv 解码出目标帧
    await Future.delayed(const Duration(milliseconds: 450));
    final bytes = await player.screenshot(format: 'image/png');
    if (bytes == null) return null;

    final base = '${Directory(path).parent.path}${Platform.pathSeparator}'
        '${_stemOf(path)}${tag == null ? '' : '_$tag'}';
    final file = await dedupTargetFile(base);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  } finally {
    await player.dispose();
  }
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
  /// - `audio-fallback-to-null=yes`：无声卡/音频设备失败时自动静音，
  ///   播放时钟照常推进；有声卡则正常输出声音
  Future<void> _applyHardening() async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return;
    await platform.setProperty('cache-on-disk', 'no');
    await platform.setProperty('audio-fallback-to-null', 'yes');
  }

  Future<void> _open() async {
    try {
      await _applyHardening();
      await _player.open(Media(widget.path));
      if (widget.isVideo) {
        // 视频：创建 VideoController 渲染画面（含解复用音频，同步输出）
        _videoController = VideoController(_player);
      }
      if (mounted) setState(() => _opened = true);
      _player.play();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('无法打开媒体：$e', style: const TextStyle(fontSize: 12)),
        duration: const Duration(seconds: 3),
      ));
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

  // ── 截帧（首帧/末帧/当前帧） ──────────────────────────────

  /// 提取指定时间点的帧并保存 PNG 到媒体同目录，返回保存路径。
  Future<String?> _grabAndSave(Duration target, String tag) async {
    if (_busy) {
      _toast('正在处理上一个操作，请稍候…');
      return null;
    }
    setState(() => _busy = true);
    try {
      _player.pause();
      // 末帧：避免 seek 到末尾触发 completed 清屏，回退 150ms
      final seekTarget = target > _duration
          ? _duration - const Duration(milliseconds: 150)
          : target;
      await _player.seek(seekTarget);
      // 等待 libmpv 渲染出新帧
      await Future.delayed(const Duration(milliseconds: 450));
      final bytes = await _player.screenshot(format: 'image/png');
      if (bytes == null) {
        _toast('截图失败：未取得帧数据');
        return null;
      }
      final base = '$_dir${Platform.pathSeparator}${_stem}_$tag';
      final file = await dedupTargetFile(base);
      await file.writeAsBytes(bytes, flush: true);
      _toast('已保存：${file.path}');
      widget.onChanged?.call();
      return file.path;
    } catch (e) {
      _toast('截图失败：$e');
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _firstFrame() => _grabAndSave(Duration.zero, '首帧');
  Future<void> _lastFrame() =>
      _grabAndSave(_duration - const Duration(milliseconds: 1), '末帧');
  Future<void> _currentFrame() => _grabAndSave(_position, '帧');

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
    if (!_opened) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
      );
    }
    if (widget.isVideo && _videoController != null) {
      // 视频：media_kit 解码视频流 + 音频流同步输出
      return Video(
        controller: _videoController!,
        controls: NoVideoControls,
        fit: BoxFit.contain,
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