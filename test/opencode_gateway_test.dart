import 'package:ai_reel_studio/core/opencode/opencode_gateway.dart';
import 'package:ai_reel_studio/core/opencode/opencode_gateway_v1.dart';
import 'package:ai_reel_studio/core/opencode/opencode_gateway_v2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    OpenCodeGateway.debugSetInstance(null);
    debugResetOpenCodeVersionCache();
  });

  group('OpenCodeCliVersion.parse', () {
    test('parses v1', () {
      final v = OpenCodeCliVersion.parse('opencode 1.2.3');
      expect(v.isV1, isTrue);
      expect(v.majorNumber, 1);
      expect(v.minorNumber, 2);
      expect(v.patchNumber, 3);
    });

    test('parses v2 with prefix', () {
      final v = OpenCodeCliVersion.parse('opencode v2.0.26');
      expect(v.isV2, isTrue);
      expect(v.majorNumber, 2);
    });

    test('unknown when no semver', () {
      final v = OpenCodeCliVersion.parse('not-a-version');
      expect(v.major, OpenCodeCliMajor.unknown);
    });
  });

  group('factory', () {
    test('selects V1 for major 1', () async {
      OpenCodeGateway.debugSetInstance(null);
      debugResetOpenCodeVersionCache(
        const OpenCodeCliVersion(
          major: OpenCodeCliMajor.v1,
          raw: '1.0.0',
          majorNumber: 1,
        ),
      );
      // 不用 forceReload：那会忽略注入缓存、再跑真实 CLI。
      final gw = await OpenCodeGateway.obtain();
      expect(gw, isA<OpenCodeGatewayV1>());
    });

    test('selects V2 for major >= 2', () async {
      OpenCodeGateway.debugSetInstance(null);
      debugResetOpenCodeVersionCache(
        const OpenCodeCliVersion(
          major: OpenCodeCliMajor.v2,
          raw: '2.0.26',
          majorNumber: 2,
        ),
      );
      final gw = await OpenCodeGateway.obtain();
      expect(gw, isA<OpenCodeGatewayV2>());
    });
  });

  group('V2 command assembly', () {
    late OpenCodeGatewayV2 gw;

    setUp(() {
      gw = OpenCodeGatewayV2(
        const OpenCodeCliVersion(
          major: OpenCodeCliMajor.v2,
          raw: '2.0.0',
          majorNumber: 2,
        ),
      );
    });

    test('prepareTuiLaunch strips hostname/port and keeps -s', () async {
      final prepared = await gw.prepareTuiLaunch(
        command: 'opencode --hostname 127.0.0.1 --port 4096 -s ses_abc',
      );
      expect(prepared.port, 0);
      expect(prepared.command, isNot(contains('--port')));
      expect(prepared.command, isNot(contains('--hostname')));
      expect(prepared.command, contains('-s ses_abc'));
      expect(prepared.sessionId, 'ses_abc');
    });

    test('prepareTuiLaunch injects sessionId', () async {
      final prepared = await gw.prepareTuiLaunch(
        command: 'opencode',
        sessionId: 'ses_new',
      );
      expect(prepared.command, 'opencode -s ses_new');
      expect(prepared.port, 0);
    });

    test('stripOpenCodeServerBind', () {
      expect(
        stripOpenCodeServerBind('opencode --hostname 127.0.0.1 --port 12 -s x'),
        'opencode -s x',
      );
    });

    test('commandWithSession / forgetSessionCommand', () {
      final withSes = gw.commandWithSession(
        baseCommand: 'opencode --port 9',
        sessionId: 'ses_1',
      );
      expect(withSes, 'opencode -s ses_1');
      expect(gw.forgetSessionCommand(withSes), 'opencode');
    });

    test('select/start return needsRestart', () async {
      final sel = await gw.selectSession(sessionId: 'ses_x');
      expect(sel.shouldRestart, isTrue);
      final neu = await gw.startNewSession();
      expect(neu.shouldRestart, isTrue);
    });

    test('session UI available without port', () {
      expect(
        gw.isSessionUiAvailable(
          const OpenCodeTabContext(
            launchedAgentHint: 'opencode',
            launchCommand: 'opencode -s ses_1',
          ),
        ),
        isTrue,
      );
      expect(
        gw.isAgentLive(
          const OpenCodeTabContext(launchedAgentHint: 'opencode'),
        ),
        isTrue,
      );
      expect(
        gw.isSessionUiAvailable(const OpenCodeTabContext()),
        isFalse,
      );
    });

    test('listSessions requires non-empty cwd (no silent host-cwd probe)',
        () async {
      final empty = await gw.listSessions(cwd: '  ', forceRefresh: true);
      expect(empty, isEmpty);
    });
  });

  group('V1 session UI still requires port', () {
    test('isSessionUiAvailable needs port', () {
      final gw = OpenCodeGatewayV1(
        const OpenCodeCliVersion(
          major: OpenCodeCliMajor.v1,
          raw: '1.0.0',
          majorNumber: 1,
        ),
      );
      expect(
        gw.isSessionUiAvailable(
          const OpenCodeTabContext(
            launchedAgentHint: 'opencode',
            serverPort: 4096,
          ),
        ),
        isTrue,
      );
      expect(
        gw.isSessionUiAvailable(
          const OpenCodeTabContext(launchedAgentHint: 'opencode'),
        ),
        isFalse,
      );
      expect(gw.preferForceRefreshOnSessionMenuOpen, isFalse);
    });
  });

  test('V2 prefers force refresh on session menu open', () {
    final gw = OpenCodeGatewayV2(
      const OpenCodeCliVersion(
        major: OpenCodeCliMajor.v2,
        raw: '2.0.0',
        majorNumber: 2,
      ),
    );
    expect(gw.preferForceRefreshOnSessionMenuOpen, isTrue);
  });

  group('OpenCodeSessionInfo.fromJson', () {
    test('maps flat V2 session list fields', () {
      final info = OpenCodeSessionInfo.fromJson({
        'id': 'ses_1',
        'title': 'Hello',
        'updated': 1700000000000,
        'created': 1600000000000,
        'projectId': 'p1',
        'directory': r'E:\proj',
      });
      expect(info.id, 'ses_1');
      expect(info.title, 'Hello');
      expect(info.directory, r'E:\proj');
      expect(info.projectId, 'p1');
      expect(info.updated, isNotNull);
    });

    test('maps nested time/location from api session.list', () {
      final info = OpenCodeSessionInfo.fromJson({
        'id': 'ses_2',
        'title': 'Nested',
        'projectID': 'p2',
        'time': {'created': 1600000000000, 'updated': 1700000000000},
        'location': {'directory': r'E:\other'},
      });
      expect(info.directory, r'E:\other');
      expect(info.projectId, 'p2');
      expect(info.updated, isNotNull);
      expect(info.created, isNotNull);
    });
  });
}
