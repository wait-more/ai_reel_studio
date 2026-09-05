import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 可持久化的快捷键组合（修饰键 + 主键）。
class KeyChord {
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;
  final LogicalKeyboardKey key;

  const KeyChord({
    required this.key,
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  static const defaultSendAgentRef = KeyChord(
    key: LogicalKeyboardKey.keyK,
    control: true,
    alt: true,
  );

  /// 人类可读，如 `Ctrl+Alt+K`。
  String get label {
    final parts = <String>[];
    if (control) parts.add('Ctrl');
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
    if (meta) parts.add('Meta');
    parts.add(_keyLabel(key));
    return parts.join('+');
  }

  SingleActivator toActivator() => SingleActivator(
        key,
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
        includeRepeats: false,
      );

  bool matches(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (event.logicalKey != key) return false;
    final pressed = HardwareKeyboard.instance;
    return pressed.isControlPressed == control &&
        pressed.isAltPressed == alt &&
        pressed.isShiftPressed == shift &&
        pressed.isMetaPressed == meta;
  }

  Map<String, dynamic> toJson() => {
        'control': control,
        'alt': alt,
        'shift': shift,
        'meta': meta,
        'keyId': key.keyId,
      };

  factory KeyChord.fromJson(Map<String, dynamic> json) {
    final id = json['keyId'];
    LogicalKeyboardKey key = LogicalKeyboardKey.keyK;
    if (id is int) {
      key = LogicalKeyboardKey.findKeyByKeyId(id) ?? LogicalKeyboardKey.keyK;
    }
    return KeyChord(
      key: key,
      control: json['control'] as bool? ?? false,
      alt: json['alt'] as bool? ?? false,
      shift: json['shift'] as bool? ?? false,
      meta: json['meta'] as bool? ?? false,
    );
  }

  factory KeyChord.fromKeyEvent(KeyEvent event) {
    final pressed = HardwareKeyboard.instance;
    return KeyChord(
      key: event.logicalKey,
      control: pressed.isControlPressed,
      alt: pressed.isAltPressed,
      shift: pressed.isShiftPressed,
      meta: pressed.isMetaPressed,
    );
  }

  /// 录制时忽略纯修饰键。
  static bool isModifierOnly(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.meta ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.isNotEmpty) {
      if (label.length == 1) return label.toUpperCase();
      return label;
    }
    final id = key.debugName ?? 'Key';
    return id.replaceFirst('Key ', '').replaceFirst('Digit ', '');
  }

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta &&
      other.key.keyId == key.keyId;

  @override
  int get hashCode => Object.hash(control, alt, shift, meta, key.keyId);
}
