import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config.dart';

/// 已知智能体 / Agent CLI 关键字（命令或终端近期输出命中即视为智能体会话）。
const kKnownAgentTokens = <String>[
  'opencode',
  'dsh-tui',
  'dsh_tui',
  'aider',
  'claude',
  'codex',
  'crush',
  'goose',
  'amp ',
  'cursor-agent',
  'openinterpreter',
  'continue',
];

/// 判断一段命令文本是否像在启动智能体。
bool commandLooksLikeAgent(String command) {
  final lower = command.toLowerCase();
  for (final token in kKnownAgentTokens) {
    if (lower.contains(token.trim())) return true;
  }
  // 用户配置的快捷启动命令也算候选
  for (final cmd in AppConfig.instance.startCmds) {
    final tip = cmd.command.trim().toLowerCase();
    if (tip.isEmpty) continue;
    final first = tip.split(RegExp(r'\s+')).first;
    if (first.length >= 2 && lower.contains(first)) return true;
  }
  return false;
}

/// 从终端近期文本判断是否处于智能体会话。
bool terminalTextLooksLikeAgent(String recentText) {
  final lower = recentText.toLowerCase();
  if (lower.trim().isEmpty) return false;
  for (final token in kKnownAgentTokens) {
    if (lower.contains(token.trim())) return true;
  }
  for (final cmd in AppConfig.instance.startCmds) {
    final tip = cmd.command.trim().toLowerCase();
    if (tip.isEmpty) continue;
    final first = tip.split(RegExp(r'\s+')).first;
    if (first.length >= 2 && lower.contains(first)) return true;
  }
  return false;
}

/// 把绝对路径转为相对项目根的 POSIX 风格路径。
String relativeProjectPath(String absolutePath) {
  final root = AppConfig.instance.projectRoot;
  var rel = absolutePath;
  if (root.isNotEmpty) {
    final normRoot = root.replaceAll('/', Platform.pathSeparator);
    final normPath = absolutePath.replaceAll('/', Platform.pathSeparator);
    if (normPath.toLowerCase().startsWith(normRoot.toLowerCase())) {
      rel = normPath.substring(normRoot.length);
    }
  }
  while (rel.startsWith(r'\') || rel.startsWith('/')) {
    rel = rel.substring(1);
  }
  return rel.replaceAll(r'\', '/');
}

/// 由文件路径 + 编辑器选区生成智能体引用字符串（不附正文）。
///
/// - 无选区：`@rel/path.md`
/// - 单行：`@rel/path.md#L12`
/// - 多行：`@rel/path.md#L12-L34`
///
/// [selectionEnd] 按 Flutter [TextSelection] 约定为**开区间末端**（不包含）。
String? buildAgentReference({
  required String filePath,
  required String text,
  required int selectionStart,
  required int selectionEnd,
}) {
  if (filePath.isEmpty) return null;
  final rel = relativeProjectPath(filePath);
  if (rel.isEmpty) return null;

  final start = selectionStart.clamp(0, text.length);
  final end = selectionEnd.clamp(0, text.length);
  final a = math.min(start, end);
  final b = math.max(start, end);

  if (a == b) {
    return '@$rel';
  }

  // end 为开区间，最后纳入的字符下标是 b-1。
  // 行号与编辑器行号栏一致：按 \\n 计的逻辑行，1-based。
  final startLine = lineNumberAt(text, a);
  final endLine = lineNumberAt(text, b - 1);
  if (startLine == endLine) {
    return '@$rel#L$startLine';
  }
  return '@$rel#L$startLine-L$endLine';
}

/// 1-based 逻辑行号（与行号栏 `i + 1` 同一规则：只认 `\\n`）。
int lineNumberAt(String text, int offset) {
  var line = 1;
  final o = offset.clamp(0, text.length);
  for (var i = 0; i < o; i++) {
    if (text.codeUnitAt(i) == 0x0A) line++;
  }
  return line;
}

/// 编辑器侧：生成当前应填入的引用；无可用文档时返回 null。
typedef AgentRefBuilder = String? Function();

/// Shell 侧：检测智能体 + 向活跃终端填入文本（不回车）。
class ShellAgentHost {
  final bool Function() isAgentActive;
  final String? Function() agentHint;
  final bool Function(String text) inject;
  final void Function() focusInput;

  const ShellAgentHost({
    required this.isAgentActive,
    required this.agentHint,
    required this.inject,
    required this.focusInput,
  });
}

final agentRefBuilderProvider = StateProvider<AgentRefBuilder?>((ref) => null);
/// 引用填入后由编辑器恢复选区（避免快捷键/失焦把选区冲掉）。
final agentRefPreserveSelectionProvider =
    StateProvider<VoidCallback?>((ref) => null);
final shellAgentHostProvider = StateProvider<ShellAgentHost?>((ref) => null);
