/// 文件系统「隐藏」判定（跨平台约定 + Windows 常见系统文件）。
///
/// - 以 `.` 开头的名称（含 `.git`、`.DS_Store` 等）
/// - Windows 常见隐藏/系统垃圾：`desktop.ini`、`Thumbs.db`
bool isHiddenFsName(String name) {
  final n = name.trim();
  if (n.isEmpty || n == '.' || n == '..') return true;
  if (n.startsWith('.')) return true;
  final lower = n.toLowerCase();
  return lower == 'desktop.ini' || lower == 'thumbs.db';
}
