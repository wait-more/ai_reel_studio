import 'dart:convert';
import 'dart:io';

/// OpenCode 会话摘要。
class OpenCodeSessionInfo {
  final String id;
  final String title;
  final DateTime? updated;
  final DateTime? created;
  final String? directory;
  final String? projectId;

  const OpenCodeSessionInfo({
    required this.id,
    required this.title,
    this.updated,
    this.created,
    this.directory,
    this.projectId,
  });

  factory OpenCodeSessionInfo.fromJson(Map<String, dynamic> json) {
    final title = (json['title'] as String?)?.trim();
    return OpenCodeSessionInfo(
      id: (json['id'] as String?)?.trim() ?? '',
      title: (title == null || title.isEmpty) ? '未命名会话' : title,
      updated: _parseTime(json['updated'] ?? json['time_updated']),
      created: _parseTime(json['created'] ?? json['time_created']),
      directory: json['directory'] as String?,
      projectId: (json['projectId'] ?? json['project_id']) as String?,
    );
  }

  OpenCodeSessionInfo copyWith({
    String? id,
    String? title,
    DateTime? updated,
    DateTime? created,
    String? directory,
    String? projectId,
  }) {
    return OpenCodeSessionInfo(
      id: id ?? this.id,
      title: title ?? this.title,
      updated: updated ?? this.updated,
      created: created ?? this.created,
      directory: directory ?? this.directory,
      projectId: projectId ?? this.projectId,
    );
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw == null) return null;
    if (raw is int) {
      final ms = raw < 100000000000 ? raw * 1000 : raw;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is num) {
      final v = raw.toInt();
      final ms = v < 100000000000 ? v * 1000 : v;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (raw is String) {
      final asInt = int.tryParse(raw);
      if (asInt != null) return _parseTime(asInt);
      return DateTime.tryParse(raw);
    }
    return null;
  }
}

String? _cachedDbPath;
DateTime? _cachedDbPathAt;
List<OpenCodeSessionInfo>? _cachedSessions;
String? _cachedSessionsKey;
DateTime? _cachedSessionsAt;

/// 统一路径形态，便于 Windows / UNC 比对。
String normalizeOpenCodePath(String path) {
  var p = path.trim().replaceAll('\\', '/');
  if (p.isEmpty) return '';
  // 保留 UNC 前缀 //host/...，其余压缩重复斜杠。
  if (p.startsWith('//')) {
    p = '//${p.substring(2).replaceAll(RegExp(r'/+'), '/')}';
  } else {
    p = p.replaceAll(RegExp(r'/+'), '/');
  }
  if (p.length > 3 && p.endsWith('/')) {
    p = p.substring(0, p.length - 1);
  }
  return p.toLowerCase();
}

bool openCodePathsEqual(String? a, String? b) {
  if (a == null || b == null) return false;
  final na = normalizeOpenCodePath(a);
  final nb = normalizeOpenCodePath(b);
  if (na.isEmpty || nb.isEmpty) return false;
  return na == nb;
}

Future<String> _openCodeDbPath() async {
  final now = DateTime.now();
  if (_cachedDbPath != null &&
      _cachedDbPathAt != null &&
      now.difference(_cachedDbPathAt!) < const Duration(minutes: 10)) {
    return _cachedDbPath!;
  }
  final result = await Process.run(
    'opencode',
    ['db', 'path'],
    runInShell: true,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'opencode db path 失败 (${result.exitCode}): ${result.stderr}'.trim(),
    );
  }
  final path = (result.stdout as String).trim();
  if (path.isEmpty) {
    throw StateError('opencode db path 为空');
  }
  _cachedDbPath = path;
  _cachedDbPathAt = now;
  return path;
}

Future<List<Map<String, dynamic>>> _runOpenCodeDbJson(String sql) async {
  // 先确保 db 可解析（顺带暖缓存）；查询仍走官方 CLI，避免自己链 SQLite。
  await _openCodeDbPath();
  final result = await Process.run(
    'opencode',
    ['db', sql, '--format', 'json'],
    runInShell: true,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'opencode db 查询失败 (${result.exitCode}): ${result.stderr}'.trim(),
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

/// 列出 [cwd] 对应项目目录下的根会话（按更新时间倒序）。
///
/// 走 `opencode db` 直查，比 `session list` 启动整套运行时快很多；
/// 并在客户端按目录归一化过滤（global 项目下 CLI 常会混进其它目录）。
Future<List<OpenCodeSessionInfo>> listOpenCodeSessions({
  required String cwd,
  int maxCount = 80,
  bool forceRefresh = false,
}) async {
  final dir = cwd.trim();
  if (dir.isEmpty) return const [];

  final cacheKey = normalizeOpenCodePath(dir);
  final now = DateTime.now();
  if (!forceRefresh &&
      _cachedSessions != null &&
      _cachedSessionsKey == cacheKey &&
      _cachedSessionsAt != null &&
      now.difference(_cachedSessionsAt!) < const Duration(seconds: 20)) {
    return _cachedSessions!;
  }

  // 多取一些再本地过滤，避免 SQL 路径形态不一致漏数。
  final fetchLimit = (maxCount * 6).clamp(80, 400);
  final rows = await _runOpenCodeDbJson(
    'SELECT id, title, directory, project_id, time_updated, time_created '
    'FROM session '
    'WHERE parent_id IS NULL AND time_archived IS NULL '
    'ORDER BY time_updated DESC '
    'LIMIT $fetchLimit',
  );

  final matched = <OpenCodeSessionInfo>[];
  for (final row in rows) {
    final info = OpenCodeSessionInfo.fromJson(row);
    if (info.id.isEmpty) continue;
    if (!openCodePathsEqual(info.directory, dir)) continue;
    matched.add(info);
    if (matched.length >= maxCount) break;
  }

  _cachedSessions = matched;
  _cachedSessionsKey = cacheKey;
  _cachedSessionsAt = now;
  return matched;
}

void invalidateOpenCodeSessionCache() {
  _cachedSessions = null;
  _cachedSessionsKey = null;
  _cachedSessionsAt = null;
}

/// 相对时间文案（会话列表副标题）。
String formatOpenCodeSessionTime(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final n = now ?? DateTime.now();
  var diff = n.difference(time);
  if (diff.isNegative) diff = Duration.zero;
  if (diff.inSeconds < 60) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final y = time.year.toString().padLeft(4, '0');
  final m = time.month.toString().padLeft(2, '0');
  final d = time.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// 去掉历史包装，归一成以 `opencode` 开头的核心命令。
String normalizeOpenCodeCoreCommand(String command) {
  var cmd = command.trim();
  if (cmd.isEmpty) return cmd;

  // 旧版：cmd /d /c "..."
  final wrapped = RegExp(
    r'^cmd(?:\.exe)?\s+/d\s+/c\s+"(.*)\s*&\s*exit\s+/b\s+%ERRORLEVEL%"\s*$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(cmd);
  if (wrapped != null) {
    cmd = wrapped.group(1)!.replaceAll('""', '"').trim();
  }

  // 旧版 UNC：pushd ... && ... & popd
  final pushd = RegExp(
    r'^pushd\s+(?:"[^"]+"|\S+)\s*&&\s*(.*?)\s*&\s*popd\s*$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(cmd);
  if (pushd != null) {
    cmd = pushd.group(1)!.trim();
  }

  // 历史实验包装（持久化残留）
  cmd = cmd.replaceFirst(
    RegExp(
      r'^\[Console\]::TreatControlCAsInput\s*=\s*\$?true\s*;\s*',
      caseSensitive: false,
    ),
    '',
  );
  cmd = cmd.replaceAll(
    RegExp(
      r'try\s*\{[^}]*\}\s*catch\s*\{[^}]*\}\s*;?',
      caseSensitive: false,
    ),
    ' ',
  );
  cmd = cmd.replaceAll(RegExp(r'\s+'), ' ').trim();

  final sp = RegExp(
    r"""Start-Process\s+-FilePath\s+(['"])(.+?[\\/]opencode(?:\.exe)?)\1(?:\s+-ArgumentList\s+@\(([^)]*)\))?""",
    caseSensitive: false,
  ).firstMatch(cmd);
  if (sp != null) {
    final rawArgs = (sp.group(3) ?? '')
        .split(',')
        .map((e) => e.trim().replaceAll(RegExp(r"^'|'$"), ''))
        .where((e) => e.isNotEmpty)
        .join(' ');
    return _opencodeCoreFromFlags(rawArgs);
  }

  final amps = RegExp(
    r"""&\s*(['"])(.+?[\\/]opencode(?:\.exe)?)\1\s*([^&]*)""",
    caseSensitive: false,
  ).allMatches(cmd).toList();
  if (amps.isNotEmpty) {
    return _opencodeCoreFromFlags(amps.last.group(3) ?? '');
  }

  final oc = RegExp(
    r'(?:^|\s)(opencode(?:\.cmd)?)\b(.*)$',
    caseSensitive: false,
  ).firstMatch(cmd);
  if (oc != null) {
    return _opencodeCoreFromFlags(oc.group(2) ?? '');
  }

  if (cmd.toLowerCase().contains('opencode') ||
      cmd.contains('--port') ||
      cmd.contains('-s')) {
    return _opencodeCoreFromFlags(cmd);
  }

  return cmd.trim();
}

String _opencodeCoreFromFlags(String raw) {
  final rest = raw.trim();
  final host = RegExp(r'--hostname(?:\s+|=)(\S+)')
      .firstMatch(rest)
      ?.group(1)
      ?.replaceAll(RegExp(r'[;]+$'), '');
  final port = RegExp(r'--port(?:\s+|=)(\d+)').firstMatch(rest)?.group(1);
  final session = RegExp(r'(?:^|\s)(?:-s|--session)(?:\s+|=)(\S+)')
      .firstMatch(rest)
      ?.group(1)
      ?.replaceAll(RegExp(r'[;]+$'), '');

  if (host != null || port != null || session != null) {
    final parts = <String>['opencode'];
    if (host != null) parts.addAll(['--hostname', host]);
    if (port != null) parts.addAll(['--port', port]);
    if (session != null) parts.addAll(['-s', session]);
    return parts.join(' ');
  }

  final cleaned = rest
      .replaceAll(
        RegExp(
          r"""&\s*['"].+?[\\/]opencode(?:\.exe)?['"]""",
          caseSensitive: false,
        ),
        '',
      )
      .replaceAll(RegExp(r'\bopencode(?:\.cmd)?\b', caseSensitive: false), '')
      .trim();
  return cleaned.isEmpty ? 'opencode' : 'opencode $cleaned';
}

/// PowerShell 宿主启动参数。
List<String> powerShellHostLaunchArguments() {
  return const ['-NoLogo'];
}

/// PowerShell 安全 `Set-Location`（单引号字面量，避免 UNC/中文在双引号里被吃掉 `\`）。
String powershellSetLocationCommand(String directory) {
  final literal = "'${directory.replaceAll("'", "''")}'";
  return 'Set-Location -LiteralPath $literal';
}

/// `Set-Location` + 启动命令（同一行，供快捷启动 / Plan B）。
String powershellCdAndCommand(String directory, String command) {
  return '${powershellSetLocationCommand(directory)}; $command';
}

/// 结束监听 [port] 的 opencode 进程（不碰宿主 PowerShell）。
Future<bool> killOpenCodeListeningOnPort(int port) async {
  if (!Platform.isWindows || port <= 0) return false;
  final script = '''
\$ErrorActionPreference = 'SilentlyContinue'
\$conns = @(Get-NetTCPConnection -LocalPort $port -State Listen)
if (-not \$conns -or \$conns.Count -eq 0) {
  \$conns = @(Get-NetTCPConnection -LocalPort $port)
}
\$killed = \$false
foreach (\$c in \$conns) {
  \$proc = Get-Process -Id \$c.OwningProcess
  if (\$null -eq \$proc) { continue }
  \$name = [string]\$proc.ProcessName
  if (\$name -match '(?i)opencode') {
    Stop-Process -Id \$proc.Id -Force
    \$killed = \$true
  }
}
if (-not \$killed) {
  Get-CimInstance Win32_Process -Filter "Name='opencode.exe'" | ForEach-Object {
    if (\$_.CommandLine -match ('--port(?:\\s+|=)$port(?:\\s|\$)')) {
      Stop-Process -Id \$_.ProcessId -Force
      \$killed = \$true
    }
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
    final out = '${result.stdout}'.trim();
    return out.contains('KILLED');
  } catch (_) {
    return false;
  }
}

/// 占一个本机空闲端口（绑定后立刻释放），供 `opencode --port` 使用。
Future<int> allocateLocalTcpPort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

/// 从启动命令中解析 `--port`。
int? parseOpenCodeServerPort(String? command) {
  if (command == null || command.isEmpty) return null;
  final m = RegExp(r'--port(?:\s+|=)(\d+)').firstMatch(command);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 在普通 TUI 命令上注入 `--hostname/--port`（不是 `opencode serve`）。
///
/// OpenCode 文档：跑 `opencode` 时本身就会起内嵌 HTTP；固定端口后即可
/// `POST /tui/select-session` 驱动同进程 TUI 切会话。
String withOpenCodeServerBind(String command, int port) {
  var cmd = normalizeOpenCodeCoreCommand(command).trim();
  if (cmd.isEmpty) cmd = 'opencode';
  cmd = cmd
      .replaceAll(RegExp(r'\s*--port(?:\s+|=)\d+'), '')
      .replaceAll(RegExp(r'\s*--hostname(?:\s+|=)\S+'), '')
      .trim();
  final parts = cmd.split(RegExp(r'\s+'));
  var idx = 0;
  while (idx < parts.length &&
      !parts[idx].toLowerCase().contains('opencode')) {
    idx++;
  }
  if (idx >= parts.length) {
    return 'opencode --hostname 127.0.0.1 --port $port $cmd'.trim();
  }
  final head = parts.sublist(0, idx + 1);
  final tail = parts.sublist(idx + 1);
  return [
    ...head,
    '--hostname',
    '127.0.0.1',
    '--port',
    '$port',
    ...tail,
  ].join(' ');
}

/// 从启动命令解析 `-s` / `--session`。
String? parseOpenCodeSessionFlag(String? command) {
  if (command == null || command.isEmpty) return null;
  final core = normalizeOpenCodeCoreCommand(command);
  final m =
      RegExp(r'(?:^|\s)(?:-s|--session)(?:\s+|=)(\S+)').firstMatch(core);
  final id = m?.group(1)?.trim();
  if (id == null || id.isEmpty) return null;
  return id;
}

/// 准备可跳转的 TUI 启动命令：固定本机端口 +（可选）`-s`。
///
/// 返回的 [command] 就是直接发给 PowerShell 的 `opencode …`。
/// OpenCode 退出若带走宿主，由终端会话静默软恢复。
Future<({String command, int port, String? sessionId})> prepareOpenCodeTuiLaunch(
  String command, {
  String? sessionId,
}) async {
  var core = normalizeOpenCodeCoreCommand(command).trim();
  if (core.isEmpty) core = 'opencode';

  var resolvedSessionId = sessionId?.trim();
  if (resolvedSessionId != null && resolvedSessionId.isNotEmpty) {
    if (RegExp(r'(^|\s)(-s|--session)(\s+|=)').hasMatch(core)) {
      core = core.replaceFirstMapped(
        RegExp(r'(-s|--session)(?:\s+|=)\S+'),
        (m) => '${m[1]} $resolvedSessionId',
      );
    } else {
      core = '$core -s $resolvedSessionId';
    }
  } else {
    resolvedSessionId = parseOpenCodeSessionFlag(core);
  }

  final port = await allocateLocalTcpPort();
  core = withOpenCodeServerBind(core, port);
  return (
    command: core,
    port: port,
    sessionId: resolvedSessionId,
  );
}

Future<String?> _readHttpJsonBody(HttpClientResponse res) async {
  final text = await res.transform(utf8.decoder).join();
  if (text.trim().isEmpty) return null;
  return text;
}

String? _sessionIdFromJson(Object? raw) {
  if (raw == null) return null;
  if (raw is String) {
    final s = raw.trim();
    return s.isEmpty || s == 'null' ? null : s;
  }
  if (raw is Map) {
    final id = raw['id'] ?? raw['sessionID'] ?? raw['sessionId'];
    if (id is String && id.trim().isNotEmpty) return id.trim();
  }
  return null;
}

/// 查询 TUI 当前正在看的会话。
///
/// 优先 `GET /tui/active-session`（新版本）；否则 `GET /api/session/active`
///（本机 1.18.x 已有：进程内前景 session）。
///
/// 注意：不要带 `?directory=`，OpenCode 会切实例且在 UNC 路径上极易超时。
Future<String?> fetchOpenCodeActiveSessionId({
  required int port,
  String? directory,
}) async {
  if (port <= 0) return null;

  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 800);
  try {
    Future<HttpClientResponse?> get(String path) async {
      final uri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: port,
        path: path,
      );
      final req = await client.getUrl(uri);
      // 仅用 header，避免 ?directory= 触发慢路径。
      if (directory != null && directory.isNotEmpty) {
        req.headers.set('x-opencode-directory', directory);
      }
      final res = await req.close().timeout(const Duration(milliseconds: 900));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        await res.drain<void>();
        return null;
      }
      return res;
    }

    // 1) 专用 TUI 当前会话（若已合入）
    final activeTui = await get('/tui/active-session');
    if (activeTui != null) {
      final text = await _readHttpJsonBody(activeTui);
      if (text != null) {
        try {
          final decoded = jsonDecode(text);
          final id = _sessionIdFromJson(decoded) ??
              (decoded is Map ? _sessionIdFromJson(decoded['data']) : null);
          if (id != null) return id;
        } catch (_) {}
      }
    }

    // 2) 进程前景 active map
    for (final path in const ['/api/session/active', '/session/active']) {
      final res = await get(path);
      if (res == null) continue;
      final text = await _readHttpJsonBody(res);
      if (text == null) continue;
      try {
        final decoded = jsonDecode(text);
        Object? map = decoded;
        if (decoded is Map && decoded['data'] is Map) {
          map = decoded['data'];
        }
        if (map is Map && map.isNotEmpty) {
          final key = map.keys.first.toString().trim();
          if (key.isNotEmpty) return key;
        }
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 方案 A 调用结果（便于降级时提示原因）。
class OpenCodeSelectSessionResult {
  final bool ok;
  final String reason;
  final int? statusCode;

  const OpenCodeSelectSessionResult._({
    required this.ok,
    required this.reason,
    this.statusCode,
  });

  factory OpenCodeSelectSessionResult.success() =>
      const OpenCodeSelectSessionResult._(ok: true, reason: 'ok');

  factory OpenCodeSelectSessionResult.fail(String reason, {int? statusCode}) =>
      OpenCodeSelectSessionResult._(
        ok: false,
        reason: reason,
        statusCode: statusCode,
      );
}

/// 方案 A：向正在跑的 TUI 内嵌 HTTP 发 `POST /tui/select-session`。
///
/// 不需要 `opencode serve`。实测带 `?directory=` 会在 UNC 工作区上卡住，
/// 因此默认不带 query；TUI 进程 cwd 已是正确实例。
Future<OpenCodeSelectSessionResult> trySelectOpenCodeTuiSession({
  required int port,
  required String sessionId,
  String? directory,
}) async {
  if (port <= 0) {
    return OpenCodeSelectSessionResult.fail('无有效端口');
  }
  if (sessionId.isEmpty) {
    return OpenCodeSelectSessionResult.fail('会话 ID 为空');
  }
  if (!sessionId.startsWith('ses')) {
    return OpenCodeSelectSessionResult.fail('会话 ID 格式无效');
  }

  final healthUri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/global/health',
  );
  final selectUri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/tui/select-session',
  );
  final publishUri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    path: '/tui/publish',
  );

  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 800);
  try {
    try {
      final healthReq = await client.getUrl(healthUri);
      final healthRes =
          await healthReq.close().timeout(const Duration(milliseconds: 800));
      await healthRes.drain<void>();
      if (healthRes.statusCode < 200 || healthRes.statusCode >= 300) {
        return OpenCodeSelectSessionResult.fail(
          '健康检查失败',
          statusCode: healthRes.statusCode,
        );
      }
    } catch (e) {
      return OpenCodeSelectSessionResult.fail('无法连接 :$port（$e）');
    }

    Future<OpenCodeSelectSessionResult> postJson(
      Uri uri,
      Map<String, dynamic> body, {
      bool withDirectoryHeader = false,
    }) async {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (withDirectoryHeader &&
          directory != null &&
          directory.isNotEmpty) {
        req.headers.set('x-opencode-directory', directory);
      }
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 2));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return OpenCodeSelectSessionResult.success();
      }
      return OpenCodeSelectSessionResult.fail(
        text.trim().isEmpty ? 'HTTP ${res.statusCode}' : text.trim(),
        statusCode: res.statusCode,
      );
    }

    // 1) 裸 POST（实测最稳，不触发 directory 切实例）
    final plain = await postJson(selectUri, {'sessionID': sessionId});
    if (plain.ok) return plain;

    // 2) 仅 header 带 directory（仍无 query）
    if (directory != null && directory.isNotEmpty) {
      final withHdr = await postJson(
        selectUri,
        {'sessionID': sessionId},
        withDirectoryHeader: true,
      );
      if (withHdr.ok) return withHdr;
    }

    // 3) publish 事件兜底
    final published = await postJson(publishUri, {
      'type': 'tui.session.select',
      'properties': {'sessionID': sessionId},
    });
    if (published.ok) return published;

    return OpenCodeSelectSessionResult.fail(
      plain.reason,
      statusCode: plain.statusCode,
    );
  } catch (e) {
    return OpenCodeSelectSessionResult.fail('请求异常：$e');
  } finally {
    client.close(force: true);
  }
}

Future<bool> _waitOpenCodeHealth(int port, {int attempts = 40}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 400);
  try {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: '/global/health',
    );
    for (var i = 0; i < attempts; i++) {
      try {
        final req = await client.getUrl(uri);
        final res =
            await req.close().timeout(const Duration(milliseconds: 400));
        await res.drain<void>();
        if (res.statusCode >= 200 && res.statusCode < 300) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<OpenCodeSessionInfo> _patchOpenCodeSessionTitle({
  required int port,
  required String sessionId,
  required String title,
}) async {
  final uri = Uri(
    scheme: 'http',
    host: '127.0.0.1',
    port: port,
    pathSegments: ['session', sessionId],
  );
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client.patchUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final bytes = utf8.encode(jsonEncode({'title': title}));
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        text.trim().isEmpty ? '重命名失败 HTTP ${res.statusCode}' : text.trim(),
      );
    }
    if (text.trim().isEmpty) {
      return OpenCodeSessionInfo(id: sessionId, title: title);
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return OpenCodeSessionInfo.fromJson(decoded);
      }
      if (decoded is Map) {
        return OpenCodeSessionInfo.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        );
      }
    } catch (_) {}
    return OpenCodeSessionInfo(id: sessionId, title: title);
  } finally {
    client.close(force: true);
  }
}

/// 重命名会话：优先打当前 TUI 端口；否则临时起 `opencode serve` 再 PATCH。
Future<OpenCodeSessionInfo> renameOpenCodeSession({
  required String sessionId,
  required String title,
  int? port,
}) async {
  final trimmed = title.trim();
  if (sessionId.isEmpty) {
    throw StateError('会话 ID 为空');
  }
  if (trimmed.isEmpty) {
    throw StateError('标题不能为空');
  }

  if (port != null && port > 0) {
    final healthy = await _waitOpenCodeHealth(port, attempts: 8);
    if (healthy) {
      final updated = await _patchOpenCodeSessionTitle(
        port: port,
        sessionId: sessionId,
        title: trimmed,
      );
      invalidateOpenCodeSessionCache();
      return updated;
    }
  }

  final servePort = await allocateLocalTcpPort();
  final proc = await Process.start(
    'opencode',
    ['serve', '--hostname', '127.0.0.1', '--port', '$servePort'],
    runInShell: true,
  );
  try {
    final ready = await _waitOpenCodeHealth(servePort);
    if (!ready) {
      throw StateError('临时 OpenCode 服务未就绪');
    }
    final updated = await _patchOpenCodeSessionTitle(
      port: servePort,
      sessionId: sessionId,
      title: trimmed,
    );
    invalidateOpenCodeSessionCache();
    return updated;
  } finally {
    proc.kill();
  }
}
