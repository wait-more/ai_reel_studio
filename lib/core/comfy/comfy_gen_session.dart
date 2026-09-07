import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 生成面板会话状态（按 URL + 模板 一份），整合排序/使能/展开/输入值。
class ComfyGenSession {
  final List<String> order;
  final Map<String, bool> enabled;
  final Map<String, bool> expanded;
  /// fieldId → 可 JSON 序列化的值（路径/文本/数字/布尔）。
  final Map<String, dynamic> values;

  const ComfyGenSession({
    this.order = const [],
    this.enabled = const {},
    this.expanded = const {},
    this.values = const {},
  });

  static const _kSessionPrefix = 'comfy_gen_session_v1:';
  static const _kLegacyExpand = 'comfy_gen_node_expanded_v1:';
  static const _kLegacyOrder = 'comfy_gen_node_order_v1:';
  static const _kLegacyEnabled = 'comfy_gen_node_enabled_v1:';

  static String key(String serverId, String templateId) =>
      '$_kSessionPrefix$serverId:$templateId';

  Map<String, dynamic> toJson() => {
        'order': order,
        'enabled': enabled,
        'expanded': expanded,
        'values': values,
      };

  factory ComfyGenSession.fromJson(Map<String, dynamic> json) {
    Map<String, bool> boolMap(dynamic raw) {
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries) e.key.toString(): e.value == true,
      };
    }

    Map<String, dynamic> valueMap(dynamic raw) {
      if (raw is! Map) return {};
      return {
        for (final e in raw.entries) e.key.toString(): e.value,
      };
    }

    List<String> strList(dynamic raw) {
      if (raw is! List) return [];
      return raw.map((e) => e.toString()).toList();
    }

    return ComfyGenSession(
      order: strList(json['order']),
      enabled: boolMap(json['enabled']),
      expanded: boolMap(json['expanded']),
      values: valueMap(json['values']),
    );
  }

  ComfyGenSession copyWith({
    List<String>? order,
    Map<String, bool>? enabled,
    Map<String, bool>? expanded,
    Map<String, dynamic>? values,
  }) {
    return ComfyGenSession(
      order: order ?? this.order,
      enabled: enabled ?? this.enabled,
      expanded: expanded ?? this.expanded,
      values: values ?? this.values,
    );
  }

  static Future<ComfyGenSession> load({
    required String serverId,
    required String templateId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key(serverId, templateId));
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return ComfyGenSession.fromJson(decoded);
        }
        if (decoded is Map) {
          return ComfyGenSession.fromJson(Map<String, dynamic>.from(decoded));
        }
      }
      return await _migrateLegacy(prefs, serverId, templateId);
    } catch (_) {
      return const ComfyGenSession();
    }
  }

  static Future<ComfyGenSession> _migrateLegacy(
    SharedPreferences prefs,
    String serverId,
    String templateId,
  ) async {
    List<String> order = const [];
    Map<String, bool> expanded = const {};
    Map<String, bool> enabled = const {};

    try {
      final orderRaw = prefs.getString('$_kLegacyOrder$templateId');
      if (orderRaw != null && orderRaw.isNotEmpty) {
        final d = jsonDecode(orderRaw);
        if (d is List) order = d.map((e) => e.toString()).toList();
      }
    } catch (_) {}

    try {
      final expRaw = prefs.getString('$_kLegacyExpand$templateId');
      if (expRaw != null && expRaw.isNotEmpty) {
        final d = jsonDecode(expRaw);
        if (d is Map) {
          expanded = {
            for (final e in d.entries) e.key.toString(): e.value == true,
          };
        }
      }
    } catch (_) {}

    try {
      final enRaw =
          prefs.getString('$_kLegacyEnabled$serverId:$templateId');
      if (enRaw != null && enRaw.isNotEmpty) {
        final d = jsonDecode(enRaw);
        if (d is Map) {
          enabled = {
            for (final e in d.entries) e.key.toString(): e.value == true,
          };
        }
      }
    } catch (_) {}

    final session = ComfyGenSession(
      order: order,
      enabled: enabled,
      expanded: expanded,
    );
    await save(
      serverId: serverId,
      templateId: templateId,
      session: session,
    );
    // 清理旧分散键，避免双写。
    await prefs.remove('$_kLegacyOrder$templateId');
    await prefs.remove('$_kLegacyExpand$templateId');
    await prefs.remove('$_kLegacyEnabled$serverId:$templateId');
    return session;
  }

  static Future<void> save({
    required String serverId,
    required String templateId,
    required ComfyGenSession session,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key(serverId, templateId),
        jsonEncode(session.toJson()),
      );
    } catch (_) {}
  }
}
