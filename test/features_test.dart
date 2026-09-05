import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_reel_studio/core/config.dart';
import 'package:ai_reel_studio/core/directory_watcher.dart';
import 'package:ai_reel_studio/core/search_utils.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mdSnippet', () {
    test('命中时返回含关键词片段', () {
      final s = mdSnippet('这是悬疑剧本，结尾有反转。', '悬疑');
      expect(s, isNotNull);
      expect(s!.contains('悬疑'), isTrue);
      expect(s.length, lessThanOrEqualTo('悬疑'.length + 80 + 40));
    });

    test('无命中返回 null', () {
      expect(mdSnippet('没有任何关键词', '不存在'), isNull);
    });

    test('换行被压平成空格', () {
      final s = mdSnippet('第一行\n悬疑\n第三行', '悬疑');
      expect(s, isNotNull);
      expect(s, isNot(contains('\n')));
    });

    test('片段越界不抛异常', () {
      final s = mdSnippet('abc', 'a', before: 100, after: 100);
      expect(s, 'abc');
    });

    test('超长文本只扫前 maxBytes', () {
      final tail = 'x' * 300000;
      final text = '关键词在头部' + tail;
      final s = mdSnippet(text, '关键词');
      expect(s, isNotNull);
      expect(s, contains('关键词'));
    });
  });

  test('DirectoryWatcher：目录内容变化后触发 onChange', () async {
    final tmp = await Directory.systemTemp.createTemp('airl_watcher_test');
    addTearDown(() => tmp.delete(recursive: true));
    await AppConfig.instance.setProjectRoot(tmp.path);

    var calls = 0;
    DirectoryWatcher.instance.start(
      onChange: () => calls++,
      interval: const Duration(milliseconds: 100),
    );

    // 等前几轮扫描建立基线（空目录 count=0）
    await Future<void>.delayed(const Duration(milliseconds: 220));

    // 外部新增目录 → 文件数量变化应触发 onChange
    await Directory('${tmp.path}${Platform.pathSeparator}新集').create();
    // 去抖冷却 1.5s，等待足够时间让扫描命中并越过冷却
    await Future<void>.delayed(const Duration(milliseconds: 2200));

    DirectoryWatcher.instance.stop();
    expect(calls, greaterThanOrEqualTo(1),
        reason: '目录内容变化后应触发刷新信号');
  });

  test('DirectoryWatcher：项目根切换不误触发', () async {
    final tmp1 = await Directory.systemTemp.createTemp('airl_w1');
    addTearDown(() => tmp1.delete(recursive: true));
    final tmp2 = await Directory.systemTemp.createTemp('airl_w2');
    addTearDown(() => tmp2.delete(recursive: true));

    var calls = 0;
    DirectoryWatcher.instance.start(
      onChange: () => calls++,
      interval: const Duration(milliseconds: 100),
    );

    await AppConfig.instance.setProjectRoot(tmp1.path);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // 切换根目录：不应触发（重置基线）
    await AppConfig.instance.setProjectRoot(tmp2.path);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    DirectoryWatcher.instance.stop();
    expect(calls, 0, reason: '切换项目根不应被当成目录变化');
  });
}