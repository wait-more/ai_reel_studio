import '../opencode_sessions.dart';
import 'opencode_gateway_v1.dart';
import 'opencode_gateway_v2.dart';
import 'opencode_version.dart';

export '../opencode_sessions.dart'
    show
        OpenCodeSessionInfo,
        formatOpenCodeSessionTime,
        invalidateOpenCodeSessionCache,
        peekOpenCodeSessionCache,
        normalizeOpenCodePath,
        openCodePathAliases,
        powershellCdAndCommand,
        parseOpenCodeSessionFlag,
        parseOpenCodeServerPort,
        normalizeOpenCodeCoreCommand,
        withOpenCodeSessionId;
export 'opencode_version.dart';
export 'opencode_gateway_v2.dart' show stripOpenCodeServerBind;

/// TUI 启动准备结果。
class OpenCodeTuiLaunch {
  final String command;
  /// V1：内嵌 HTTP 端口；V2：固定为 0。
  final int port;
  final String? sessionId;

  const OpenCodeTuiLaunch({
    required this.command,
    required this.port,
    this.sessionId,
  });
}

/// 切会话 / 新建会话的结果（UI 只认 outcome，不认版本）。
enum OpenCodeNavOutcome {
  /// 已在当前 TUI 内完成。
  ok,

  /// 需结束 TUI 后用 prepareTuiLaunch 再启。
  needsRestart,

  /// 失败且不宜自动重启。
  failed,
}

class OpenCodeNavResult {
  final OpenCodeNavOutcome outcome;
  final String reason;

  const OpenCodeNavResult._(this.outcome, this.reason);

  factory OpenCodeNavResult.ok([String reason = 'ok']) =>
      OpenCodeNavResult._(OpenCodeNavOutcome.ok, reason);

  factory OpenCodeNavResult.needsRestart(String reason) =>
      OpenCodeNavResult._(OpenCodeNavOutcome.needsRestart, reason);

  factory OpenCodeNavResult.failed(String reason) =>
      OpenCodeNavResult._(OpenCodeNavOutcome.failed, reason);

  bool get isOk => outcome == OpenCodeNavOutcome.ok;
  bool get shouldRestart => outcome == OpenCodeNavOutcome.needsRestart;
}

/// 调用方传入的 Tab 上下文（不必自判版本）。
class OpenCodeTabContext {
  final int? serverPort;
  final String? launchCommand;
  final String? launchedAgentHint;
  final String? currentSessionId;

  const OpenCodeTabContext({
    this.serverPort,
    this.launchCommand,
    this.launchedAgentHint,
    this.currentSessionId,
  });
}

/// OpenCode 统一门面：版本分支仅在实现内部。
abstract class OpenCodeGateway {
  OpenCodeCliVersion get version;

  /// 准备发给 PTY 的启动命令。
  Future<OpenCodeTuiLaunch> prepareTuiLaunch({
    String command = 'opencode',
    String? sessionId,
  });

  Future<List<OpenCodeSessionInfo>> listSessions({
    required String cwd,
    int maxCount = 80,
    bool forceRefresh = false,
  });

  Future<void> deleteSession({
    required String sessionId,
    int? port,
  });

  Future<OpenCodeSessionInfo> renameSession({
    required String sessionId,
    required String title,
    int? port,
  });

  Future<OpenCodeNavResult> selectSession({
    required String sessionId,
    int? port,
    String? directory,
  });

  Future<OpenCodeNavResult> startNewSession({int? port});

  Future<String?> fetchActiveSessionId({
    int? port,
    String? directory,
  });

  /// 「会话」入口是否可点。
  bool isSessionUiAvailable(OpenCodeTabContext tab);

  /// 打开会话菜单时是否跳过列表 TTL。
  ///
  /// V2 为 true（避免错误空缓存）；V1 为 false（继续吃 20s 缓存）。
  bool get preferForceRefreshOnSessionMenuOpen;

  /// 该 Tab 是否仍视为 OpenCode 智能体存活（标签样式等）。
  bool isAgentLive(OpenCodeTabContext tab);

  /// 结束该 Tab 的 OpenCode 进程；不得 stop 全局 V2 service。
  Future<bool> killAgentProcess(OpenCodeTabContext tab);

  /// 记住会话后写回 launchCommand（内部处理是否绑 port）。
  String commandWithSession({
    required String baseCommand,
    required String sessionId,
    int? port,
  });

  /// 清除 `-s` 后的核心命令（V2 去掉无效 hostname/port）。
  String forgetSessionCommand(String? launchCommand, {int? port});

  static OpenCodeGateway? _instance;
  static Future<OpenCodeGateway>? _obtaining;

  /// 取得与本机 CLI 版本匹配的 Gateway（缓存）。
  static Future<OpenCodeGateway> obtain({bool forceReload = false}) {
    if (!forceReload && _instance != null) {
      return Future.value(_instance!);
    }
    if (!forceReload && _obtaining != null) return _obtaining!;
    _obtaining = _obtainUncached(forceReload: forceReload).whenComplete(() {
      _obtaining = null;
    });
    return _obtaining!;
  }

  static Future<OpenCodeGateway> _obtainUncached({
    required bool forceReload,
  }) async {
    final ver = await detectOpenCodeVersion(force: forceReload);
    final gw = switch (ver.major) {
      OpenCodeCliMajor.v1 => OpenCodeGatewayV1(ver),
      OpenCodeCliMajor.v2 => OpenCodeGatewayV2(ver),
      OpenCodeCliMajor.unknown => OpenCodeGatewayV2(ver),
    };
    _instance = gw;
    return gw;
  }

  /// 测试用。
  static void debugSetInstance(OpenCodeGateway? gw) {
    _instance = gw;
    _obtaining = null;
  }
}
