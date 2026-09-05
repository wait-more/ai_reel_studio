import 'dart:io';
import 'package:ai_reel_studio/core/directory_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DirectoryParser 结构识别', () {
    test('识别扁平单集剧本 (001_悬疑)', () async {
      // 用临时目录模拟单集剧本结构
      final temp = Directory.systemTemp.createTempSync('ars_test_flat');
      final script = Directory('${temp.path}/001_悬疑_最后一次通话')..createSync();
      Directory('${script.path}/场景素材').createSync();
      Directory('${script.path}/角色定妆照').createSync();
      File('${script.path}/剧本.md').createSync();
      File('${script.path}/分镜.md').createSync();

      final tree = await DirectoryParser.parseRootAsync(temp.path);
      expect(tree.children.length, 1);
      final s = tree.children.first;
      expect(s.type, ScriptNodeType.script);
      expect(s.name, '001_悬疑_最后一次通话');
      expect(s.children.length, greaterThanOrEqualTo(3));

      // cleanup
      temp.deleteSync(recursive: true);
    });

    test('识别多季多集剧本 (003_穿书)', () async {
      final temp = Directory.systemTemp.createTempSync('ars_test_nested');
      final script = Directory('${temp.path}/003_穿书_我穿进了自己写的剧本')
        ..createSync();
      final seasons = Directory('${script.path}/剧集')..createSync();
      final season1 = Directory('${seasons.path}/1_觉醒')..createSync();
      final ep1 = Directory('${season1.path}/01_猝死穿书')..createSync();
      Directory('${ep1.path}/场景素材').createSync();
      File('${ep1.path}/剧本.md').createSync();

      final tree = await DirectoryParser.parseRootAsync(temp.path);
      expect(tree.children.length, 1);
      final s = tree.children.first;
      expect(s.type, ScriptNodeType.script);

      // cleanup
      temp.deleteSync(recursive: true);
    });

    test('深层物料文件夹按需热加载', () async {
      final temp = Directory.systemTemp.createTempSync('ars_test_lazy');
      final script = Directory('${temp.path}/004_测试剧本')..createSync();
      final asset = Directory('${script.path}/场景素材')..createSync();
      final sub = Directory('${asset.path}/音频')..createSync();
      File('${sub.path}/bgm.wav').createSync();
      File('${sub.path}/旁白.mp3').createSync();
      File('${asset.path}/参考图.png').createSync();

      final tree = await DirectoryParser.parseRootAsync(temp.path);
      final s = tree.children.single;
      expect(s.type, ScriptNodeType.script);

      // 场景素材 (folder) 已列出直接子项
      final assetNode = s.children.singleWhere(
        (c) => c.name == '场景素材' && c.type == ScriptNodeType.folder,
      );
      expect(assetNode.isLoaded, isTrue);
      expect(assetNode.children.map((c) => c.name), contains('参考图.png'));

      // 其子目录 '音频' 是懒加载壳：尚未加载更深内容
      final audio = assetNode.children.singleWhere((c) => c.name == '音频');
      expect(audio.isLoaded, isFalse);
      expect(audio.children, isEmpty);

      // 热加载后深层文件可见
      await DirectoryParser.loadChildrenAsync(audio);
      expect(audio.isLoaded, isTrue);
      expect(audio.children.map((c) => c.name), containsAll(['bgm.wav', '旁白.mp3']));

      // cleanup
      temp.deleteSync(recursive: true);
    });
  });
}
