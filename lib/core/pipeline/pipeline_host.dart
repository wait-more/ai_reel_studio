import 'dart:io';

/// 多机共用 NAS 项目时的本机身份（hostname + 用户名）。
class PipelineHost {
  PipelineHost._();

  static String? _cached;

  /// 稳定短 id，用于 bridge 文件名与 Job.hostId。
  static String get id {
    _cached ??= _compute();
    return _cached!;
  }

  static String get displayName {
    final h = Platform.localHostname.trim();
    final u = Platform.environment['USERNAME'] ??
        Platform.environment['USER'] ??
        '';
    if (u.trim().isEmpty) return h.isEmpty ? id : h;
    return '$h · $u';
  }

  static String _compute() {
    final h = Platform.localHostname.trim().toLowerCase();
    final u = (Platform.environment['USERNAME'] ??
            Platform.environment['USER'] ??
            '')
        .trim()
        .toLowerCase();
    final raw = u.isEmpty ? (h.isEmpty ? 'unknown' : h) : '${h}_$u';
    final cleaned = raw.replaceAll(RegExp(r'[^a-z0-9._-]+'), '-');
    return cleaned.isEmpty ? 'unknown' : cleaned;
  }

  static bool isMine(String? hostId) {
    final h = hostId?.trim() ?? '';
    if (h.isEmpty) return true; // 旧任务无归属：本机可接管
    return h == id;
  }
}
