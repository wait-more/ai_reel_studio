import 'package:shared_preferences/shared_preferences.dart';

/// 创作进度状态。
class EpisodeStatus {
  static const notStarted = '未开始';
  static const outlining = '大纲';
  static const writing = '剧本中';
  static const producing = '拍摄/制作中';
  static const post = '后期/配音';
  static const done = '已完成';

  static const all = [
    notStarted,
    outlining,
    writing,
    producing,
    post,
    done,
  ];

  /// 中文颜色标识（供徽章取色）。
  static const colors = {
    notStarted: 0xFF9E9E9E, // 灰
    outlining: 0xFF7986CB, // 靛
    writing: 0xFF42A5F5, // 蓝
    producing: 0xFFEF6C00, // 橙
    post: 0xFFEC407A, // 粉
    done: 0xFF66BB6A, // 绿
  };

  static const labelIcons = {
    notStarted: '○',
    outlining: '大纲',
    writing: '剧本',
    producing: '制作',
    post: '后期',
    done: '✓',
  };
}

/// 读取某目录（剧本/季/集）的已保存进度状态；无记录返回“未开始”。
Future<String> loadEpisodeStatus(String path) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('episode_status:$path') ?? EpisodeStatus.notStarted;
}

/// 保存某目录的进度状态。
Future<void> saveEpisodeStatus(String path, String status) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('episode_status:$path', status);
}

/// 批量载入全部已保存的进度状态（key: episode_status:<path>）。
Future<Map<String, String>> loadAllStatuses() async {
  final prefs = await SharedPreferences.getInstance();
  const prefix = 'episode_status:';
  final result = <String, String>{};
  for (final k in prefs.getKeys()) {
    if (!k.startsWith(prefix)) continue;
    final v = prefs.getString(k);
    if (v != null && EpisodeStatus.all.contains(v)) {
      result[k.substring(prefix.length)] = v;
    }
  }
  return result;
}