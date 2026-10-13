import 'dart:convert';
import 'dart:io';

import '../opencode_sessions.dart';
import 'opencode_gateway.dart';

/// V2：CLI 自管 service；启动 `opencode` / `-s`；会话 CRUD 走 CLI/`opencode api`。
class OpenCodeGatewayV2 implements OpenCodeGateway {
  OpenCodeGatewayV2(this.version);

  @override
  final OpenCodeCliVersion version;

  @override
  Future<OpenCodeTuiLaunch> prepareTuiLaunch({
    String command = 'opencode',
    String? sessionId,
  }) async {
    var core = stripOpenCodeServerBind(
      normalizeOpenCodeCoreCommand(command),
    ).trim();
    if (core.isEmpty) core = 'opencode';

    var resolvedSessionId = sessionId?.trim();
    if (resolvedSessionId != null && resolvedSessionId.isNotEmpty) {
      core = withOpenCodeSessionId(core, resolvedSessionId);
    } else {
      resolvedSessionId = parseOpenCodeSessionFlag(core);
    }

    return OpenCodeTuiLaunch(
      command: core,
      port: 0,
      sessionId: resolvedSessionId,
    );
  }

  @override
  Future<List<OpenCodeSessionInfo>> listSessions({
    required String cwd,
    int maxCount = 80,
    bool forceRefresh = false,
  }) async {
    final dir = cwd.trim();
    if (dir.isEmpty) return const [];

    if (!forceRefresh) {
      final cached = takeFreshOpenCodeSessionCache(dir);
      if (cached != null) return cached;
    }

    // V2：`session list` 按「当前项目」作用域，必须在目标 cwd 下执行；
    // 不能依赖宿主 exe 的 cwd（Debug 包常在 build\...\runner\Debug）。
    final rows = await _runSessionListJson(maxCount, workingDirectory: dir);
    final matched = <OpenCodeSessionInfo>[];
    for (final row in rows) {
      final info = OpenCodeSessionInfo.fromJson(row);
      if (info.id.isEmpty) continue;
      matched.add(info);
      if (matched.length >= maxCount) break;
    }

    putOpenCodeSessionCache(dir, matched);
    return matched;
  }

  @override
  Future<void> deleteSession({
    required String sessionId,
    int? port,
  }) async {
    final id = sessionId.trim();
    if (id.isEmpty) throw StateError('会话 ID 为空');
    final result = await Process.run(
      'opencode',
      ['session', 'delete', id],
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      final err = '${result.stderr}${result.stdout}'.trim();
      throw StateError(err.isEmpty ? '删除失败 (${result.exitCode})' : err);
    }
    invalidateOpenCodeSessionCache();
  }

  @override
  Future<OpenCodeSessionInfo> renameSession({
    required String sessionId,
    required String title,
    int? port,
  }) async {
    final id = sessionId.trim();
    final trimmed = title.trim();
    if (id.isEmpty) throw StateError('会话 ID 为空');
    if (trimmed.isEmpty) throw StateError('标题不能为空');

    final body = jsonEncode({'title': trimmed});
    final result = await Process.run(
      'opencode',
      [
        'api',
        'session.update',
        '--param',
        'sessionID=$id',
        '-d',
        body,
      ],
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    final text = '${result.stdout}${result.stderr}'.trim();
    if (result.exitCode != 0) {
      throw StateError(text.isEmpty ? '重命名失败 (${result.exitCode})' : text);
    }
    if (text.contains('InvalidRequestError') ||
        text.contains('HTTP 4') ||
        text.contains('HTTP 5')) {
      throw StateError(text);
    }

    invalidateOpenCodeSessionCache();

    OpenCodeSessionInfo? parsed;
    if (text.isNotEmpty) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          parsed = OpenCodeSessionInfo.fromJson(
            decoded.map((k, v) => MapEntry(k.toString(), v)),
          );
        }
      } catch (_) {}
    }
    return parsed ?? OpenCodeSessionInfo(id: id, title: trimmed);
  }

  @override
  Future<OpenCodeNavResult> selectSession({
    required String sessionId,
    int? port,
    String? directory,
  }) async {
    final id = sessionId.trim();
    if (id.isEmpty) {
      return OpenCodeNavResult.failed('会话 ID 为空');
    }
    // V2 尚无稳定的 live TUI 切会话 API：统一走重启 `-s`。
    return OpenCodeNavResult.needsRestart('V2 需重启 TUI 切换会话');
  }

  @override
  Future<OpenCodeNavResult> startNewSession({int? port}) async {
    // 无 `-s` 重启即可新建。
    return OpenCodeNavResult.needsRestart('V2 需重启 TUI 新建会话');
  }

  @override
  Future<String?> fetchActiveSessionId({
    int? port,
    String? directory,
  }) async {
    // V2 无可靠的 active-session 查询；UI 用 Tab 记忆的 `-s` / knownSessionId。
    return null;
  }

  @override
  bool isSessionUiAvailable(OpenCodeTabContext tab) {
    if (!_hintIsOpenCode(tab)) return false;
    return tab.launchedAgentHint != null && tab.launchedAgentHint!.isNotEmpty;
  }

  @override
  bool get preferForceRefreshOnSessionMenuOpen => true;

  @override
  bool isAgentLive(OpenCodeTabContext tab) {
    if (!_hintIsOpenCode(tab)) return false;
    // V2 无端口；以 launchedAgentHint 为准（退回 Shell 时会清空）。
    return tab.launchedAgentHint != null && tab.launchedAgentHint!.isNotEmpty;
  }

  @override
  Future<bool> killAgentProcess(OpenCodeTabContext tab) async {
    // 只结束该 Tab 相关的 TUI（按 `-s` / 命令行匹配），绝不 `service stop`。
    final sessionId = tab.currentSessionId ??
        parseOpenCodeSessionFlag(tab.launchCommand);
    return killOpenCodeTuiProcess(sessionId: sessionId);
  }

  @override
  String commandWithSession({
    required String baseCommand,
    required String sessionId,
    int? port,
  }) {
    return withOpenCodeSessionId(
      stripOpenCodeServerBind(normalizeOpenCodeCoreCommand(baseCommand)),
      sessionId,
    );
  }

  @override
  String forgetSessionCommand(String? launchCommand, {int? port}) {
    if (launchCommand == null || launchCommand.isEmpty) return 'opencode';
    return stripOpenCodeServerBind(
      normalizeOpenCodeCoreCommand(
        launchCommand.replaceAll(
          RegExp(r'\s*(?:-s|--session)(?:\s+|=)\S+'),
          '',
        ),
      ),
    );
  }

  bool _hintIsOpenCode(OpenCodeTabContext tab) {
    final hint = tab.launchedAgentHint?.toLowerCase() ?? '';
    if (hint.contains('opencode')) return true;
    final launch = tab.launchCommand ?? '';
    return launch.toLowerCase().contains('opencode');
  }

  static Future<List<Map<String, dynamic>>> _runSessionListJson(
    int maxCount, {
    required String workingDirectory,
  }) async {
    final result = await Process.run(
      'opencode',
      ['session', 'list', '-n', '$maxCount', '--format', 'json'],
      workingDirectory: workingDirectory,
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError(
        'opencode session list 失败 (${result.exitCode}): ${result.stderr}'
            .trim(),
      );
    }
    final text = (result.stdout as String).trim();
    if (text.isEmpty) return const [];
    final decoded = jsonDecode(text);
    if (decoded is! List) return const [];
    return [
      for (final item in decoded)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  }
}

/// 去掉 `--hostname/--port`（V2 顶层不支持，且勿仿 V1 绑端口）。
String stripOpenCodeServerBind(String command) {
  var cmd = command.trim();
  if (cmd.isEmpty) return cmd;
  cmd = cmd
      .replaceAll(RegExp(r'\s*--port(?:\s+|=)\d+'), '')
      .replaceAll(RegExp(r'\s*--hostname(?:\s+|=)\S+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cmd.isEmpty ? 'opencode' : cmd;
}

/// 结束本机 OpenCode TUI 进程（按会话 id / 非 service 命令行），不 stop 全局 service。
Future<bool> killOpenCodeTuiProcess({String? sessionId}) async {
  if (!Platform.isWindows) return false;
  final id = sessionId?.trim() ?? '';
  final idLiteral = id.replaceAll("'", "''");
  final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
\$killed = \$false
\$sessionId = '$idLiteral'
Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" | ForEach-Object {
  \$cmd = [string]\$_.CommandLine
  if ([string]::IsNullOrWhiteSpace(\$cmd)) { return }
  if (\$cmd -match '(?i)(\\sservice\\s|\\sserve\\b)') { return }
  \$match = \$false
  if (-not [string]::IsNullOrWhiteSpace(\$sessionId)) {
    if (\$cmd -match [regex]::Escape(\$sessionId)) { \$match = \$true }
  } else {
    # 无会话 id：仅杀「看起来像 TUI」的进程（带 -s / 无子命令的 opencode）
    if (\$cmd -match '(?i)(-s|--session)\\b' -or \$cmd -match '(?i)opencode(\\.exe)?\\s*\$') {
      \$match = \$true
    }
  }
  if (\$match) {
    Stop-Process -Id \$_.ProcessId -Force
    \$killed = \$true
  }
}
if (\$killed) { 'KILLED' } else { 'MISS' }
''';
  try {
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-NoLogo', '-Command', script],
      runInShell: false,
    );
    return '${result.stdout}'.trim().contains('KILLED');
  } catch (_) {
    return false;
  }
}
