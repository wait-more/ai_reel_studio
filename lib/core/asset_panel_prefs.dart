import 'dart:convert';

/// 素材栏 UI 偏好（视图模式 / 列宽 / 排序），统一一份快照持久化。
class AssetPanelPrefs {
  static const prefsKey = 'asset_panel_prefs_v1';

  /// 旧版分散 key，仅用于迁移。
  static const legacyViewModeKey = 'assetViewMode';
  static const legacyColWidthsKey = 'assetListColWidths';
  static const legacySortKey = 'assetListSort';

  static const defaultColWidths = <String, double>{
    'name': 280,
    'modified': 148,
    'type': 110,
    'size': 88,
  };

  static const defaultSortColumn = 'name';
  static const defaultSortAsc = true;

  /// `grid` | `list`
  final String viewMode;
  final Map<String, double> colWidths;
  /// `name` | `modified` | `type` | `size`
  final String sortColumn;
  final bool sortAsc;

  const AssetPanelPrefs({
    required this.viewMode,
    required this.colWidths,
    required this.sortColumn,
    required this.sortAsc,
  });

  factory AssetPanelPrefs.defaults() => AssetPanelPrefs(
        viewMode: 'grid',
        colWidths: Map<String, double>.of(defaultColWidths),
        sortColumn: defaultSortColumn,
        sortAsc: defaultSortAsc,
      );

  AssetPanelPrefs copyWith({
    String? viewMode,
    Map<String, double>? colWidths,
    String? sortColumn,
    bool? sortAsc,
  }) {
    return AssetPanelPrefs(
      viewMode: viewMode ?? this.viewMode,
      colWidths: colWidths ?? Map<String, double>.of(this.colWidths),
      sortColumn: sortColumn ?? this.sortColumn,
      sortAsc: sortAsc ?? this.sortAsc,
    ).sanitized();
  }

  AssetPanelPrefs sanitized() {
    final widths = Map<String, double>.of(defaultColWidths);
    for (final key in defaultColWidths.keys) {
      final v = colWidths[key];
      if (v != null) widths[key] = v.clamp(64, 640);
    }
    const allowedSort = {'name', 'modified', 'type', 'size'};
    return AssetPanelPrefs(
      viewMode: viewMode == 'list' ? 'list' : 'grid',
      colWidths: widths,
      sortColumn:
          allowedSort.contains(sortColumn) ? sortColumn : defaultSortColumn,
      sortAsc: sortAsc,
    );
  }

  Map<String, dynamic> toJson() => {
        'viewMode': viewMode,
        'colWidths': colWidths,
        'sortColumn': sortColumn,
        'sortAsc': sortAsc,
      };

  factory AssetPanelPrefs.fromJson(Map<String, dynamic> json) {
    final rawWidths = json['colWidths'];
    final widths = Map<String, double>.of(defaultColWidths);
    if (rawWidths is Map) {
      for (final key in defaultColWidths.keys) {
        final v = rawWidths[key];
        if (v is num) widths[key] = v.toDouble();
      }
    }
    return AssetPanelPrefs(
      viewMode: json['viewMode'] as String? ?? 'grid',
      colWidths: widths,
      sortColumn: json['sortColumn'] as String? ?? defaultSortColumn,
      sortAsc: json['sortAsc'] as bool? ?? defaultSortAsc,
    ).sanitized();
  }

  static AssetPanelPrefs? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return AssetPanelPrefs.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  /// 从旧版三个分散 key 拼出一份偏好。
  static AssetPanelPrefs fromLegacy({
    String? viewModeRaw,
    String? colWidthsRaw,
    String? sortRaw,
  }) {
    var prefs = AssetPanelPrefs.defaults();
    if (viewModeRaw == 'list' || viewModeRaw == 'grid') {
      prefs = prefs.copyWith(viewMode: viewModeRaw);
    }
    if (colWidthsRaw != null && colWidthsRaw.isNotEmpty) {
      try {
        final map = jsonDecode(colWidthsRaw) as Map<String, dynamic>;
        final widths = Map<String, double>.of(defaultColWidths);
        for (final key in defaultColWidths.keys) {
          final v = map[key];
          if (v is num) widths[key] = v.toDouble();
        }
        prefs = prefs.copyWith(colWidths: widths);
      } catch (_) {}
    }
    if (sortRaw != null && sortRaw.isNotEmpty) {
      try {
        final map = jsonDecode(sortRaw) as Map<String, dynamic>;
        prefs = prefs.copyWith(
          sortColumn: map['column'] as String? ?? defaultSortColumn,
          sortAsc: map['asc'] as bool? ?? defaultSortAsc,
        );
      } catch (_) {}
    }
    return prefs.sanitized();
  }
}
