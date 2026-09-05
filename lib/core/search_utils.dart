/// 从 [text] 中提取首个命中 [queryLower]（已小写）的上下文片段，
/// 用于搜索结果展示。无命中返回 null。
///
/// - 只扫描前 [maxBytes] 字节，避免超大文档拖慢搜索
/// - 片段截取命中位置前 [before] / 后 [after] 个字符，并把换行压成空格
String? mdSnippet(
  String text,
  String queryLower, {
  int maxBytes = 262144,
  int before = 40,
  int after = 80,
}) {
  final scan = text.length > maxBytes ? text.substring(0, maxBytes) : text;
  final lower = scan.toLowerCase();
  final idx = lower.indexOf(queryLower);
  if (idx < 0) return null;
  final start = (idx - before).clamp(0, scan.length);
  final end = (idx + queryLower.length + after).clamp(0, scan.length);
  return scan.substring(start, end).replaceAll('\n', ' ');
}