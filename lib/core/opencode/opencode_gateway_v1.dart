import '../opencode_sessions.dart';
import 'opencode_gateway.dart';

/// V1：内嵌 HTTP（`--hostname/--port`）+ `opencode db` + `/tui/*`。
class OpenCodeGatewayV1 implements OpenCodeGateway {
  OpenCodeGatewayV1(this.version);

  @override
  final OpenCodeCliVersion version;

  @override
  Future<OpenCodeTuiLaunch> prepareTuiLaunch({
    String command = 'opencode',
    String? sessionId,
  }) async {
    final prepared = await prepareOpenCodeTuiLaunch(
      command,
      sessionId: sessionId,
    );
    return OpenCodeTuiLaunch(
      command: prepared.command,
      port: prepared.port,
      sessionId: prepared.sessionId,
    );
  }

  @override
  Future<List<OpenCodeSessionInfo>> listSessions({
    required String cwd,
    int maxCount = 80,
    bool forceRefresh = false,
  }) {
    return listOpenCodeSessions(
      cwd: cwd,
      maxCount: maxCount,
      forceRefresh: forceRefresh,
    );
  }

  @override
  Future<void> deleteSession({
    required String sessionId,
    int? port,
  }) {
    return deleteOpenCodeSession(sessionId: sessionId, port: port);
  }

  @override
  Future<OpenCodeSessionInfo> renameSession({
    required String sessionId,
    required String title,
    int? port,
  }) {
    return renameOpenCodeSession(
      sessionId: sessionId,
      title: title,
      port: port,
    );
  }

  @override
  Future<OpenCodeNavResult> selectSession({
    required String sessionId,
    int? port,
    String? directory,
  }) async {
    if (port == null || port <= 0) {
      return OpenCodeNavResult.needsRestart('当前 OpenCode 未绑定端口');
    }
    final result = await trySelectOpenCodeTuiSession(
      port: port,
      sessionId: sessionId,
      directory: directory,
    );
    if (result.ok) return OpenCodeNavResult.ok();
    return OpenCodeNavResult.needsRestart(result.reason);
  }

  @override
  Future<OpenCodeNavResult> startNewSession({int? port}) async {
    if (port == null || port <= 0) {
      return OpenCodeNavResult.needsRestart('当前 OpenCode 未绑定端口');
    }
    final result = await tryStartOpenCodeNewSession(port: port);
    if (result.ok) return OpenCodeNavResult.ok();
    return OpenCodeNavResult.needsRestart(result.reason);
  }

  @override
  Future<String?> fetchActiveSessionId({
    int? port,
    String? directory,
  }) async {
    if (port == null || port <= 0) return null;
    return fetchOpenCodeActiveSessionId(port: port, directory: directory);
  }

  @override
  bool isSessionUiAvailable(OpenCodeTabContext tab) {
    if (!_hintIsOpenCode(tab)) return false;
    final port = tab.serverPort ?? parseOpenCodeServerPort(tab.launchCommand);
    return port != null && port > 0 && tab.launchedAgentHint != null;
  }

  @override
  bool get preferForceRefreshOnSessionMenuOpen => false;

  @override
  bool isAgentLive(OpenCodeTabContext tab) {
    if (!_hintIsOpenCode(tab)) return false;
    final port = tab.serverPort ?? parseOpenCodeServerPort(tab.launchCommand);
    return port != null && port > 0;
  }

  @override
  Future<bool> killAgentProcess(OpenCodeTabContext tab) async {
    final port = tab.serverPort ?? parseOpenCodeServerPort(tab.launchCommand);
    if (port == null || port <= 0) return false;
    return killOpenCodeListeningOnPort(port);
  }

  @override
  String commandWithSession({
    required String baseCommand,
    required String sessionId,
    int? port,
  }) {
    final p = port ?? parseOpenCodeServerPort(baseCommand);
    var cmd = withOpenCodeSessionId(baseCommand, sessionId);
    if (p != null && p > 0) {
      cmd = withOpenCodeServerBind(cmd, p);
    }
    return cmd;
  }

  @override
  String forgetSessionCommand(String? launchCommand, {int? port}) {
    if (launchCommand == null || launchCommand.isEmpty) return 'opencode';
    var cmd = normalizeOpenCodeCoreCommand(
      launchCommand.replaceAll(
        RegExp(r'\s*(?:-s|--session)(?:\s+|=)\S+'),
        '',
      ),
    );
    final p = port ?? parseOpenCodeServerPort(launchCommand);
    if (p != null && p > 0) {
      cmd = withOpenCodeServerBind(cmd, p);
    }
    return cmd;
  }

  bool _hintIsOpenCode(OpenCodeTabContext tab) {
    final hint = tab.launchedAgentHint?.toLowerCase() ?? '';
    if (hint.contains('opencode')) return true;
    final launch = tab.launchCommand ?? '';
    return launch.toLowerCase().contains('opencode');
  }
}
