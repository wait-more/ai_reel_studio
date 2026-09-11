import 'package:re_editor/re_editor.dart';

import 'markdown_outline.dart';

/// 扁平字符偏移 → (行号 0-based, 列号 0-based，相对该行行首)。
(int line, int col) flatOffsetToLineCol(String text, int offset) {
  final o = offset.clamp(0, text.length);
  var line = 0;
  var lineStart = 0;
  for (var i = 0; i < o; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      lineStart = i + 1;
    }
  }
  return (line, o - lineStart);
}

/// (行号, 列号) → 扁平字符偏移。列超出该行长度时夹到行末。
int lineColToFlatOffset(String text, int line, int col) {
  if (text.isEmpty) return 0;
  if (line <= 0) {
    final end = text.indexOf('\n');
    final lineEnd = end < 0 ? text.length : end;
    return col.clamp(0, lineEnd);
  }

  var currentLine = 0;
  var i = 0;
  while (i < text.length && currentLine < line) {
    if (text.codeUnitAt(i) == 0x0A) {
      currentLine++;
    }
    i++;
  }
  if (currentLine < line) return text.length;

  final lineStart = i;
  var lineEnd = lineStart;
  while (lineEnd < text.length && text.codeUnitAt(lineEnd) != 0x0A) {
    lineEnd++;
  }
  return lineStart + col.clamp(0, lineEnd - lineStart);
}

/// 扁平 base/extent（与 [TextSelection] 同约定）→ [CodeLineSelection]。
CodeLineSelection codeSelectionFromFlat(String text, int base, int extent) {
  final b = base.clamp(0, text.length);
  final e = extent.clamp(0, text.length);
  final (baseLine, baseCol) = flatOffsetToLineCol(text, b);
  final (extentLine, extentCol) = flatOffsetToLineCol(text, e);
  return CodeLineSelection(
    baseIndex: baseLine,
    baseOffset: baseCol,
    extentIndex: extentLine,
    extentOffset: extentCol,
  );
}

/// [CodeLineSelection] → 扁平 base/extent。
({int base, int extent}) flatFromCodeSelection(
  String text,
  CodeLineSelection sel,
) {
  final base = lineColToFlatOffset(text, sel.baseIndex, sel.baseOffset);
  final extent = lineColToFlatOffset(text, sel.extentIndex, sel.extentOffset);
  return (base: base, extent: extent);
}

/// 便捷：光标所在逻辑行（0-based）。
int activeLineFromSelection(String text, CodeLineSelection sel) {
  return lineIndexOfOffset(
    text,
    lineColToFlatOffset(text, sel.baseIndex, sel.baseOffset),
  );
}
