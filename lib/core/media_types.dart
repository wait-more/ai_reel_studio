/// 媒体类型分类（树/网格共用），保持两处打开行为一致。
enum MediaKind { markdown, image, video, audio, other }

/// 按扩展名分类文件（大小写不敏感）。
MediaKind classifyMedia(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.md')) return MediaKind.markdown;
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.gif') ||
      lower.endsWith('.webp')) {
    return MediaKind.image;
  }
  if (lower.endsWith('.mp4') ||
      lower.endsWith('.mov') ||
      lower.endsWith('.mkv') ||
      lower.endsWith('.avi') ||
      lower.endsWith('.webm')) {
    return MediaKind.video;
  }
  if (lower.endsWith('.wav') ||
      lower.endsWith('.mp3') ||
      lower.endsWith('.flac') ||
      lower.endsWith('.ogg') ||
      lower.endsWith('.m4a')) {
    return MediaKind.audio;
  }
  return MediaKind.other;
}