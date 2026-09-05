import 'package:ai_reel_studio/core/agent_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAgentReference', () {
    test('no selection → file only', () {
      const text = 'hello\nworld\n';
      final r = buildAgentReference(
        filePath: r'E:\scripts\a\剧本.md',
        text: text,
        selectionStart: 0,
        selectionEnd: 0,
      );
      expect(r, isNotNull);
      expect(r!.startsWith('@'), isTrue);
      expect(r.contains('#L'), isFalse);
      expect(r.endsWith('剧本.md'), isTrue);
    });

    test('single line selection → #L2', () {
      const text = 'l1\nl2\nl3\n';
      final r = buildAgentReference(
        filePath: r'C:\proj\doc.md',
        text: text,
        selectionStart: 3,
        selectionEnd: 5,
      );
      expect(r, endsWith('#L2'));
    });

    test('multi-line selection → #L1-L3', () {
      const text = 'a\nb\nc\n';
      final r = buildAgentReference(
        filePath: r'C:\x\f.md',
        text: text,
        selectionStart: 0,
        selectionEnd: text.length,
      );
      expect(r, endsWith('#L1-L3'));
    });

    test('exclusive end at next line start → still multi-line', () {
      // "l1\nl2\n" 选中两行，end 落在第三行行首（开区间）
      const text = 'l1\nl2\nl3\n';
      final endAtL3 = text.indexOf('l3');
      final r = buildAgentReference(
        filePath: r'C:\x\f.md',
        text: text,
        selectionStart: 0,
        selectionEnd: endAtL3,
      );
      expect(r, endsWith('#L1-L2'));
    });
  });

  group('commandLooksLikeAgent', () {
    test('detects opencode', () {
      expect(commandLooksLikeAgent('opencode'), isTrue);
      expect(commandLooksLikeAgent('Set-Location x; opencode'), isTrue);
    });

    test('Get-ChildItem is not an agent', () {
      expect(commandLooksLikeAgent('Get-ChildItem'), isFalse);
    });
  });
}
