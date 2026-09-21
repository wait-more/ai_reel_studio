import 'package:flutter/material.dart';

/// 文件与稿件用的低饱和色。失败、警告仍走 [ColorScheme.error]，不要用这里的色表示状态。
abstract final class UiPalette {
  static const folder = Color(0xFF8B93A1);
  static const document = Color(0xFF7E9BB8);
  static const image = Color(0xFFC4A36A);
  static const video = Color(0xFF9A86A8);
  static const audio = Color(0xFF7FA08C);

  static Color forPath(String path, {required bool isDir}) {
    if (isDir) return folder;
    final lower = path.toLowerCase();
    if (lower.endsWith('.md') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.json')) {
      return document;
    }
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.gif')) {
      return image;
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.webm')) {
      return video;
    }
    if (lower.endsWith('.wav') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.flac') ||
        lower.endsWith('.ogg')) {
      return audio;
    }
    return folder;
  }
}
