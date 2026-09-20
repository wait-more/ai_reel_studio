import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 按路径 + 修改时间 + 大小区分缓存。
///
/// Flutter 自带的 [FileImage] 只按路径缓存。同名文件删了再生成时，
/// 磁盘内容已变，界面仍会画出旧图。本 provider 把 mtime/size 算进 key。
@immutable
class FreshFileImage extends ImageProvider<FreshFileImage> {
  FreshFileImage(this.file, {this.scale = 1.0})
      : mtimeMs = _statMtimeMs(file),
        length = _statLength(file);

  final File file;
  final double scale;
  final int mtimeMs;
  final int length;

  static int _statMtimeMs(File file) {
    try {
      return file.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      return 0;
    }
  }

  static int _statLength(File file) {
    try {
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  @override
  Future<FreshFileImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<FreshFileImage>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    FreshFileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: key.scale,
      debugLabel: key.file.path,
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Path: ${file.path}'),
      ],
    );
  }

  Future<ui.Codec> _loadAsync(
    FreshFileImage key,
    ImageDecoderCallback decode,
  ) async {
    assert(key == this);
    final bytes = await file.length();
    if (bytes == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('$file is empty and cannot be loaded as an image.');
    }
    return decode(await ui.ImmutableBuffer.fromFilePath(file.path));
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    return other is FreshFileImage &&
        other.file.path == file.path &&
        other.scale == scale &&
        other.mtimeMs == mtimeMs &&
        other.length == length;
  }

  @override
  int get hashCode => Object.hash(file.path, scale, mtimeMs, length);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'FreshFileImage')}("${file.path}", '
      'mtime: $mtimeMs, length: $length, scale: ${scale.toStringAsFixed(1)})';
}

/// 清掉该路径相关的图片缓存（含旧 [FileImage] 与当前 [FreshFileImage]）。
void evictProjectFileImage(String path) {
  final file = File(path);
  final cache = PaintingBinding.instance.imageCache;
  cache.evict(FileImage(file));
  cache.evict(FreshFileImage(file));
}

/// 项目内本地图片：自动按文件变更失效缓存。
class ProjectFileImage extends StatelessWidget {
  const ProjectFileImage(
    this.path, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.errorBuilder,
  });

  final String path;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: FreshFileImage(File(path)),
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: true,
      errorBuilder: errorBuilder,
    );
  }
}
