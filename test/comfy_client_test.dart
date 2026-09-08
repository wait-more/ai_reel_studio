import 'package:ai_reel_studio/core/comfy/comfy_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contentAddressedInputName', () {
    test('哈希后带本地文件名后缀', () {
      const hex =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      expect(
        ComfyClient.contentAddressedInputName(
          localPath: r'E:\assets\角色.png',
          sha256hex: hex,
        ),
        'ars_0123456789abcdef_角色.png',
      );
    });

    test('相同内容相同本地名得到同一远端名', () {
      const hex =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final a = ComfyClient.contentAddressedInputName(
        localPath: 'photo.png',
        sha256hex: hex,
      );
      final b = ComfyClient.contentAddressedInputName(
        localPath: r'C:\other\photo.png',
        sha256hex: hex,
      );
      expect(a, b);
      expect(a, 'ars_aaaaaaaaaaaaaaaa_photo.png');
    });

    test('扩展名转为小写', () {
      const hex =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      expect(
        ComfyClient.contentAddressedInputName(
          localPath: 'clip.MP4',
          sha256hex: hex,
        ),
        'ars_bbbbbbbbbbbbbbbb_clip.mp4',
      );
    });

    test('不安全字符替换为下划线', () {
      const hex =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      expect(
        ComfyClient.contentAddressedInputName(
          localPath: r'E:\assets\shot a*b?.png',
          sha256hex: hex,
        ),
        'ars_cccccccccccccccc_shot a_b_.png',
      );
    });
  });
}
