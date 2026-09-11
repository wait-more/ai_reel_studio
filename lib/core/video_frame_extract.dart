import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path/path.dart' as p;

/// 用 OpenCV VideoCapture 抽帧。
class VideoFrameExtract {
  VideoFrameExtract._();

  /// 最近一次失败原因（供 UI 提示）。
  static String? lastError;

  /// 抽取一帧到 [outputPng]。成功返回 true。
  ///
  /// 末帧：`POS_FRAMES = count - 1`（FFmpeg 后端）；全黑则最多再往前试 8 帧。
  static Future<bool> extract({
    required String videoPath,
    required String outputPng,
    bool lastFrame = false,
    Duration? at,
  }) async {
    lastError = null;
    if (!await File(videoPath).exists()) {
      lastError = '视频文件不存在';
      return false;
    }

    final outDir = Directory(p.dirname(outputPng));
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    try {
      final err = _extractSync(
        videoPath: videoPath,
        outputPng: outputPng,
        lastFrame: lastFrame,
        at: at,
      );
      if (err == null) return true;
      lastError = _shortErr(err);
      debugPrint('VideoFrameExtract failed: $lastError');
      return false;
    } catch (e, st) {
      lastError = _shortErr('$e');
      debugPrint('VideoFrameExtract exception: $e\n$st');
      return false;
    }
  }

  static String? _extractSync({
    required String videoPath,
    required String outputPng,
    required bool lastFrame,
    Duration? at,
  }) {
    final cap = _openCapture(videoPath);
    if (cap == null) {
      return '无法打开视频（OpenCV VideoCapture）';
    }
    try {
      if (lastFrame) {
        return _readLastFrame(cap, outputPng);
      }

      if (at != null && at > Duration.zero) {
        cap.set(cv.CAP_PROP_POS_MSEC, at.inMilliseconds.toDouble());
      }
      final (ok, frame) = cap.read();
      try {
        if (!ok || frame.isEmpty) return '未能读取帧';
        return _savePng(outputPng, frame);
      } finally {
        frame.dispose();
      }
    } finally {
      _closeCap(cap);
    }
  }

  /// 定位最后一帧并写出。
  static String? _readLastFrame(cv.VideoCapture cap, String outputPng) {
    final total = cap.get(cv.CAP_PROP_FRAME_COUNT);
    if (!total.isFinite || total < 1) {
      return '视频无有效帧';
    }

    cap.set(cv.CAP_PROP_POS_FRAMES, total - 1);
    var (ok, frame) = cap.read();
    try {
      if (ok && !frame.isEmpty && !_isBlankFrame(frame)) {
        return _savePng(outputPng, frame);
      }
    } finally {
      frame.dispose();
    }

    // count-1 偶发全黑：再往前试几帧
    for (var back = 2; back <= 8; back++) {
      final idx = total - back;
      if (idx < 0) break;
      cap.set(cv.CAP_PROP_POS_FRAMES, idx);
      final read = cap.read();
      ok = read.$1;
      frame = read.$2;
      try {
        if (ok && !frame.isEmpty && !_isBlankFrame(frame)) {
          return _savePng(outputPng, frame);
        }
      } finally {
        frame.dispose();
      }
    }
    return '未能读取末帧';
  }

  /// 优先 FFmpeg 后端（与常见 opencv-python 行为一致）。
  static cv.VideoCapture? _openCapture(String videoPath) {
    for (final api in [cv.CAP_FFMPEG, cv.CAP_ANY]) {
      final cap = cv.VideoCapture.fromFile(videoPath, apiPreference: api);
      if (cap.isOpened) {
        debugPrint('VideoFrameExtract backend=$api (${cap.getBackendName()})');
        return cap;
      }
      _closeCap(cap);
    }
    return null;
  }

  static bool _isBlankFrame(cv.Mat frame) {
    if (frame.isEmpty || frame.rows < 2 || frame.cols < 2) return true;
    final m = cv.mean(frame);
    return m.val1 < 2.0 && m.val2 < 2.0 && m.val3 < 2.0;
  }

  static void _closeCap(cv.VideoCapture cap) {
    try {
      cap.release();
    } catch (_) {}
    try {
      cap.dispose();
    } catch (_) {}
  }

  /// imencode + 写文件，避免 Windows 上 OpenCV imwrite 对中文路径失败。
  static String? _savePng(String outputPng, cv.Mat frame) {
    final (ok, bytes) = cv.imencode('.png', frame);
    if (!ok || bytes.isEmpty) return 'PNG 编码失败';
    try {
      File(outputPng).writeAsBytesSync(bytes, flush: true);
    } catch (e) {
      return '写文件失败：$e';
    }
    if (!File(outputPng).existsSync() || File(outputPng).lengthSync() < 64) {
      return '写出的 PNG 无效';
    }
    return null;
  }

  static String _shortErr(String s) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (one.length <= 180) return one;
    return '${one.substring(0, 180)}…';
  }
}
