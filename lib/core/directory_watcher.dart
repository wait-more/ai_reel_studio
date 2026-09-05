import 'dart:async';
import 'dart:io';

import 'config.dart';

/// 项目目录变更监听。
///
/// NAS / SMB 网络目录下 `Directory.watch` 事件不可靠（Windows 上经常收不到），
/// 因此采用「周期扫描 + 变化去抖」策略：
/// - 每 [interval] 递归统计一次文件数量（不阻塞 UI，纯 IO 等待）
/// - 计数变化且距上次发出信号超过冷却时间 → 触发 [onChange]
/// - 项目根目录切换时自动重置基线，避免误触发
///
/// 应用内操作产生的刷新走 [treeRefreshTickProvider]（即时），
/// 监听器只补外部变化（文件管理器拷贝、脚本生成、预览截帧等）的自动刷新。
class DirectoryWatcher {
  DirectoryWatcher._();
  static final DirectoryWatcher instance = DirectoryWatcher._();

  Timer? _timer;
  String _root = '';
  int _prevCount = -1;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  bool _scanning = false;
  static const _cooldown = Duration(milliseconds: 1500);

  /// 启动监听。[onChange] 在检测到外部结构变化时被调用。
  void start({
    required void Function() onChange,
    Duration interval = const Duration(seconds: 5),
  }) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _scan(onChange));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _prevCount = -1;
    _root = '';
  }

  Future<void> _scan(void Function() onChange) async {
    if (_scanning) return;
    if (!AppConfig.instance.isConfigured) return;
    final root = AppConfig.instance.projectRoot;
    _scanning = true;
    try {
      var count = 0;
      await for (final _ in Directory(root)
          .list(recursive: true, followLinks: false)) {
        count++;
      }
      if (_root != root) {
        // 项目根切换：重置基线，不误触发
        _root = root;
        _prevCount = count;
        return;
      }
      if (_prevCount != -1 && count != _prevCount) {
        final now = DateTime.now();
        if (now.difference(_lastEmit) > _cooldown) {
          _lastEmit = now;
          onChange();
        }
      }
      _prevCount = count;
    } catch (_) {
      // 目录暂不可达（NAS 离线 / 权限），静默，下一周期自动重试
    } finally {
      _scanning = false;
    }
  }
}