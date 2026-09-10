import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 把 [RenderEditable] 的 caret / composing 矩形同步到 Windows 文本插件。
///
/// 计算方式对齐 [EditableText] 内部实现，避免自行猜 affinity / composing.end
/// 把候选框推到错误行首。
void syncImeGeometryToPlatform(
  RenderEditable editable,
  TextEditingValue value,
) {
  if (!editable.hasSize) return;
  final selection = value.selection;
  if (!selection.isValid) return;

  // 与 EditableText._updateCaretRectIfNeeded 一致：用 selection.start。
  final caretRect = editable.getLocalRectForCaret(
    TextPosition(offset: selection.start),
  );
  if (!caretRect.isFinite) return;

  // 与 EditableText._updateComposingRectIfNeeded 一致。
  Rect markedRect = caretRect;
  final composing = value.composing;
  if (value.isComposingRangeValid) {
    markedRect = editable.getRectForComposingRange(composing) ??
        editable.getLocalRectForCaret(
          TextPosition(offset: composing.start),
        );
    if (!markedRect.isFinite) {
      markedRect = caretRect;
    }
  }

  final size = editable.size;
  final transform = editable.getTransformTo(null);

  SystemChannels.textInput.invokeMethod<void>(
    'TextInput.setEditableSizeAndTransform',
    <String, dynamic>{
      'width': size.width,
      'height': size.height,
      'transform': transform.storage,
    },
  );
  SystemChannels.textInput.invokeMethod<void>(
    'TextInput.setCaretRect',
    <String, dynamic>{
      'width': caretRect.width,
      'height': caretRect.height,
      'x': caretRect.left,
      'y': caretRect.top,
    },
  );
  SystemChannels.textInput.invokeMethod<void>(
    'TextInput.setMarkedTextRect',
    <String, dynamic>{
      'width': markedRect.width,
      'height': markedRect.height,
      'x': markedRect.left,
      'y': markedRect.top,
    },
  );
}
