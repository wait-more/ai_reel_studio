import 'dart:io';

/// 本机 `opencode` CLI 主版本族。
enum OpenCodeCliMajor {
  v1,
  v2,
  unknown,
}

class OpenCodeCliVersion {
  final OpenCodeCliMajor major;
  final String raw;
  final int? majorNumber;
  final int? minorNumber;
  final int? patchNumber;

  const OpenCodeCliVersion({
    required this.major,
    required this.raw,
    this.majorNumber,
    this.minorNumber,
    this.patchNumber,
  });

  bool get isV1 => major == OpenCodeCliMajor.v1;
  bool get isV2 => major == OpenCodeCliMajor.v2;

  /// 解析 `opencode -v` / `--version` 输出，如 `opencode v2.0.26`。
  static OpenCodeCliVersion parse(String stdout) {
    final raw = stdout.trim();
    final m = RegExp(
      r'v?(\d+)\.(\d+)\.(\d+)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (m == null) {
      return OpenCodeCliVersion(major: OpenCodeCliMajor.unknown, raw: raw);
    }
    final majorNum = int.tryParse(m.group(1)!);
    final minorNum = int.tryParse(m.group(2)!);
    final patchNum = int.tryParse(m.group(3)!);
    final family = switch (majorNum) {
      null => OpenCodeCliMajor.unknown,
      <= 1 => OpenCodeCliMajor.v1,
      _ => OpenCodeCliMajor.v2,
    };
    return OpenCodeCliVersion(
      major: family,
      raw: raw,
      majorNumber: majorNum,
      minorNumber: minorNum,
      patchNumber: patchNum,
    );
  }
}

OpenCodeCliVersion? _cachedVersion;
Future<OpenCodeCliVersion>? _detecting;

/// 探测本机 opencode 版本（进程内缓存）。
Future<OpenCodeCliVersion> detectOpenCodeVersion({bool force = false}) {
  if (!force && _cachedVersion != null) {
    return Future.value(_cachedVersion!);
  }
  if (!force && _detecting != null) return _detecting!;
  _detecting = _detectOpenCodeVersionUncached().whenComplete(() {
    _detecting = null;
  });
  return _detecting!;
}

Future<OpenCodeCliVersion> _detectOpenCodeVersionUncached() async {
  try {
    final result = await Process.run(
      'opencode',
      ['-v'],
      runInShell: true,
    );
    final text = '${result.stdout}${result.stderr}'.trim();
    if (text.isEmpty) {
      _cachedVersion = const OpenCodeCliVersion(
        major: OpenCodeCliMajor.unknown,
        raw: '',
      );
      return _cachedVersion!;
    }
    _cachedVersion = OpenCodeCliVersion.parse(text);
    return _cachedVersion!;
  } catch (_) {
    _cachedVersion = const OpenCodeCliVersion(
      major: OpenCodeCliMajor.unknown,
      raw: '',
    );
    return _cachedVersion!;
  }
}

/// 测试用：注入/清空缓存。
void debugResetOpenCodeVersionCache([OpenCodeCliVersion? value]) {
  _cachedVersion = value;
  _detecting = null;
}
