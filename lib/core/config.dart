import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'comfy/comfy_models.dart';
import 'asset_panel_prefs.dart';
import 'key_chord.dart';

/// 快捷启动工作目录策略。
enum CwdStrategy {
  /// 使用项目 scripts 根目录
  projectRoot,

  /// 使用左侧树/物料当前选中的目录（无则回退项目根）
  selectedDir,
}

/// 一条 Shell 快捷启动命令。
class StartCmd {
  final String name;
  final String command;
  final CwdStrategy cwd;

  const StartCmd({
    required this.name,
    required this.command,
    this.cwd = CwdStrategy.projectRoot,
  });

  StartCmd copyWith({String? name, String? command, CwdStrategy? cwd}) {
    return StartCmd(
      name: name ?? this.name,
      command: command ?? this.command,
      cwd: cwd ?? this.cwd,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'command': command,
        'cwd': cwd.name,
      };

  factory StartCmd.fromJson(Map<String, dynamic> json) {
    final cwdName = json['cwd'] as String? ?? CwdStrategy.projectRoot.name;
    return StartCmd(
      name: json['name'] as String? ?? '',
      command: json['command'] as String? ?? '',
      cwd: CwdStrategy.values.firstWhere(
        (e) => e.name == cwdName,
        orElse: () => CwdStrategy.projectRoot,
      ),
    );
  }
}

class AppConfig {
  AppConfig._();
  static final AppConfig instance = AppConfig._();

  static const _kProjectRoot = 'projectRoot';
  static const _kThemeMode = 'themeMode';
  static const _kUiFontScale = 'uiFontScale';
  static const _kEditorFontSize = 'editorFontSize';
  static const _kTerminalFontSize = 'terminalFontSize';
  static const _kStartCmds = 'startCmds';
  static const _kSendAgentRefChord = 'sendAgentRefChord';
  static const _kComfyBaseUrl = 'comfyBaseUrl';
  static const _kComfyApiKey = 'comfyApiKey';
  static const _kComfyServers = 'comfyServers';
  static const _kComfySelectedServerId = 'comfySelectedServerId';
  static const _kComfyDeleteRemoteAfterDownload =
      'comfyDeleteRemoteAfterDownload';

  static const defaultComfyBaseUrl = 'http://127.0.0.1:8188';

  static const defaultStartCmds = <StartCmd>[
    StartCmd(name: 'opencode', command: 'opencode'),
    StartCmd(name: 'dsh-tui', command: 'dsh-tui'),
  ];

  /// 素材栏默认列宽（兼容旧调用）。
  static Map<String, double> get defaultAssetListColWidths =>
      Map<String, double>.of(AssetPanelPrefs.defaultColWidths);
  static String get defaultAssetListSortColumn =>
      AssetPanelPrefs.defaultSortColumn;
  static bool get defaultAssetListSortAsc => AssetPanelPrefs.defaultSortAsc;

  /// 旧默认快捷项：已从默认栏移除（Comfy 走生成面板；终端本身已是 PowerShell）。
  static bool _isRetiredDefaultStartCmd(StartCmd cmd) {
    final c = cmd.command.trim().toLowerCase();
    return c == 'pow' || c == 'comfyui';
  }

  static bool _rawStartCmdsContainRetired(String raw) {
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.whereType<Map>().any((e) {
        final cmd = StartCmd.fromJson(Map<String, dynamic>.from(e));
        return _isRetiredDefaultStartCmd(cmd);
      });
    } catch (_) {
      return false;
    }
  }

  String _projectRoot = '';
  ThemeMode _themeMode = ThemeMode.dark;
  double _uiFontScale = 1.0;
  double _editorFontSize = 14;
  double _terminalFontSize = 12;
  List<StartCmd> _startCmds = List.of(defaultStartCmds);
  KeyChord _sendAgentRefChord = KeyChord.defaultSendAgentRef;
  List<ComfyServer> _comfyServers = [ComfyServer.localDefault()];
  String _comfySelectedServerId = 'local';
  bool _comfyDeleteRemoteAfterDownload = true;
  AssetPanelPrefs _assetPanelPrefs = AssetPanelPrefs.defaults();

  String get projectRoot => _projectRoot;
  ThemeMode get themeMode => _themeMode;
  double get uiFontScale => _uiFontScale;
  double get editorFontSize => _editorFontSize;
  double get terminalFontSize => _terminalFontSize;
  List<StartCmd> get startCmds => List.unmodifiable(_startCmds);
  KeyChord get sendAgentRefChord => _sendAgentRefChord;
  List<ComfyServer> get comfyServers => List.unmodifiable(_comfyServers);
  String get comfySelectedServerId => _comfySelectedServerId;
  bool get comfyDeleteRemoteAfterDownload => _comfyDeleteRemoteAfterDownload;
  /// 素材栏偏好整包（视图 / 列宽 / 排序）。
  AssetPanelPrefs get assetPanelPrefs => _assetPanelPrefs;
  /// `grid` | `list`
  String get assetViewMode => _assetPanelPrefs.viewMode;
  Map<String, double> get assetListColWidths =>
      Map.unmodifiable(_assetPanelPrefs.colWidths);
  /// `name` | `modified` | `type` | `size`
  String get assetListSortColumn => _assetPanelPrefs.sortColumn;
  bool get assetListSortAsc => _assetPanelPrefs.sortAsc;

  ComfyServer get comfySelectedServer {
    for (final s in _comfyServers) {
      if (s.id == _comfySelectedServerId) return s;
    }
    return _comfyServers.isNotEmpty
        ? _comfyServers.first
        : ComfyServer.localDefault();
  }

  /// 兼容旧代码：当前选中实例的 URL / Key。
  String get comfyBaseUrl => comfySelectedServer.baseUrl;
  String get comfyApiKey => comfySelectedServer.apiKey;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _projectRoot = prefs.getString(_kProjectRoot) ?? '';
    _themeMode = _parseThemeMode(prefs.getString(_kThemeMode));
    _uiFontScale = (prefs.getDouble(_kUiFontScale) ?? 1.0).clamp(0.85, 1.4);
    _editorFontSize =
        (prefs.getDouble(_kEditorFontSize) ?? 14).clamp(11, 24);
    _terminalFontSize =
        (prefs.getDouble(_kTerminalFontSize) ?? 12).clamp(10, 22);
    final rawStartCmds = prefs.getString(_kStartCmds);
    _startCmds = _loadStartCmds(rawStartCmds);
    if (rawStartCmds != null &&
        rawStartCmds.isNotEmpty &&
        _rawStartCmdsContainRetired(rawStartCmds)) {
      final encoded =
          jsonEncode(_startCmds.map((e) => e.toJson()).toList());
      await prefs.setString(_kStartCmds, encoded);
    }
    _sendAgentRefChord = _loadChord(prefs.getString(_kSendAgentRefChord));
    _comfyServers = _loadComfyServers(
      prefs.getString(_kComfyServers),
      legacyUrl: prefs.getString(_kComfyBaseUrl),
      legacyKey: prefs.getString(_kComfyApiKey),
    );
    final sel = prefs.getString(_kComfySelectedServerId);
    if (sel != null && _comfyServers.any((s) => s.id == sel)) {
      _comfySelectedServerId = sel;
    } else {
      _comfySelectedServerId = _comfyServers.first.id;
    }
    _comfyDeleteRemoteAfterDownload =
        prefs.getBool(_kComfyDeleteRemoteAfterDownload) ?? true;
    _assetPanelPrefs = await _loadAssetPanelPrefs(prefs);
  }

  Future<AssetPanelPrefs> _loadAssetPanelPrefs(SharedPreferences prefs) async {
    final unified = AssetPanelPrefs.tryParse(
      prefs.getString(AssetPanelPrefs.prefsKey),
    );
    if (unified != null) return unified;

    // 兼容迁移：旧版三个分散 key → 合一，并清掉旧 key。
    final migrated = AssetPanelPrefs.fromLegacy(
      viewModeRaw: prefs.getString(AssetPanelPrefs.legacyViewModeKey),
      colWidthsRaw: prefs.getString(AssetPanelPrefs.legacyColWidthsKey),
      sortRaw: prefs.getString(AssetPanelPrefs.legacySortKey),
    );
    await prefs.setString(
      AssetPanelPrefs.prefsKey,
      jsonEncode(migrated.toJson()),
    );
    await prefs.remove(AssetPanelPrefs.legacyViewModeKey);
    await prefs.remove(AssetPanelPrefs.legacyColWidthsKey);
    await prefs.remove(AssetPanelPrefs.legacySortKey);
    return migrated;
  }

  Future<void> setAssetPanelPrefs(AssetPanelPrefs prefs) async {
    _assetPanelPrefs = prefs.sanitized();
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      AssetPanelPrefs.prefsKey,
      jsonEncode(_assetPanelPrefs.toJson()),
    );
  }

  Future<void> updateAssetPanelPrefs(
    AssetPanelPrefs Function(AssetPanelPrefs current) update,
  ) async {
    await setAssetPanelPrefs(update(_assetPanelPrefs));
  }

  Future<void> setAssetViewMode(String mode) async {
    await updateAssetPanelPrefs(
      (p) => p.copyWith(viewMode: mode == 'list' ? 'list' : 'grid'),
    );
  }

  Future<void> setAssetListColWidths(Map<String, double> widths) async {
    await updateAssetPanelPrefs((p) => p.copyWith(colWidths: widths));
  }

  Future<void> resetAssetListColWidths() async {
    await updateAssetPanelPrefs(
      (p) => p.copyWith(
        colWidths: Map<String, double>.of(AssetPanelPrefs.defaultColWidths),
      ),
    );
  }

  Future<void> setAssetListSort({
    required String column,
    required bool asc,
  }) async {
    await updateAssetPanelPrefs(
      (p) => p.copyWith(sortColumn: column, sortAsc: asc),
    );
  }

  Future<void> resetAssetListSort() async {
    await updateAssetPanelPrefs(
      (p) => p.copyWith(
        sortColumn: AssetPanelPrefs.defaultSortColumn,
        sortAsc: AssetPanelPrefs.defaultSortAsc,
      ),
    );
  }

  /// 重置素材栏列表相关偏好（排序 + 列宽；保留视图模式）。
  Future<void> resetAssetListLayoutPrefs() async {
    await updateAssetPanelPrefs(
      (p) => p.copyWith(
        colWidths: Map<String, double>.of(AssetPanelPrefs.defaultColWidths),
        sortColumn: AssetPanelPrefs.defaultSortColumn,
        sortAsc: AssetPanelPrefs.defaultSortAsc,
      ),
    );
  }

  Future<void> setProjectRoot(String path) async {
    _projectRoot = path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProjectRoot, path);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeMode, mode.name);
  }

  Future<void> setUiFontScale(double scale) async {
    _uiFontScale = scale.clamp(0.85, 1.4);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kUiFontScale, _uiFontScale);
  }

  Future<void> setEditorFontSize(double size) async {
    _editorFontSize = size.clamp(11, 24);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kEditorFontSize, _editorFontSize);
  }

  Future<void> setTerminalFontSize(double size) async {
    _terminalFontSize = size.clamp(10, 22);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTerminalFontSize, _terminalFontSize);
  }

  Future<void> setStartCmds(List<StartCmd> cmds) async {
    _startCmds = List.of(cmds);
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(cmds.map((e) => e.toJson()).toList());
    await prefs.setString(_kStartCmds, encoded);
  }

  Future<void> setSendAgentRefChord(KeyChord chord) async {
    _sendAgentRefChord = chord;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSendAgentRefChord, jsonEncode(chord.toJson()));
  }

  Future<void> setComfyServers(List<ComfyServer> servers) async {
    _comfyServers = servers.isEmpty
        ? [ComfyServer.localDefault()]
        : List.of(servers);
    if (!_comfyServers.any((s) => s.id == _comfySelectedServerId)) {
      _comfySelectedServerId = _comfyServers.first.id;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kComfyServers,
      jsonEncode(_comfyServers.map((e) => e.toJson()).toList()),
    );
    await prefs.setString(_kComfySelectedServerId, _comfySelectedServerId);
  }

  Future<void> setComfySelectedServerId(String id) async {
    if (!_comfyServers.any((s) => s.id == id)) return;
    _comfySelectedServerId = id;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kComfySelectedServerId, id);
  }

  Future<void> setComfyBaseUrl(String url) async {
    // 兼容：改当前选中实例的 URL
    final cur = comfySelectedServer;
    final next = List.of(_comfyServers);
    final i = next.indexWhere((s) => s.id == cur.id);
    if (i < 0) return;
    next[i] = cur.copyWith(
      baseUrl: url.trim().isEmpty ? defaultComfyBaseUrl : url.trim(),
    );
    await setComfyServers(next);
  }

  Future<void> setComfyApiKey(String key) async {
    final cur = comfySelectedServer;
    final next = List.of(_comfyServers);
    final i = next.indexWhere((s) => s.id == cur.id);
    if (i < 0) return;
    next[i] = cur.copyWith(apiKey: key);
    await setComfyServers(next);
  }

  Future<void> setComfyDeleteRemoteAfterDownload(bool value) async {
    _comfyDeleteRemoteAfterDownload = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kComfyDeleteRemoteAfterDownload, value);
  }

  static List<ComfyServer> _loadComfyServers(
    String? raw, {
    String? legacyUrl,
    String? legacyKey,
  }) {
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        final servers = list
            .whereType<Map>()
            .map((e) => ComfyServer.fromJson(Map<String, dynamic>.from(e)))
            .where((e) => e.baseUrl.trim().isNotEmpty)
            .toList();
        if (servers.isNotEmpty) return servers;
      } catch (_) {}
    }
    final url = (legacyUrl == null || legacyUrl.trim().isEmpty)
        ? defaultComfyBaseUrl
        : legacyUrl.trim();
    return [
      ComfyServer(
        id: 'local',
        name: '本机',
        baseUrl: url,
        apiKey: legacyKey ?? '',
      ),
    ];
  }

  bool get isConfigured =>
      _projectRoot.isNotEmpty && Directory(_projectRoot).existsSync();

  static ThemeMode _parseThemeMode(String? raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'system':
        return ThemeMode.system;
      case 'dark':
      default:
        return ThemeMode.dark;
    }
  }

  static List<StartCmd> _loadStartCmds(String? raw) {
    if (raw == null || raw.isEmpty) return List.of(defaultStartCmds);
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final cmds = list
          .whereType<Map>()
          .map((e) => StartCmd.fromJson(Map<String, dynamic>.from(e)))
          .where((e) => e.name.trim().isNotEmpty && e.command.trim().isNotEmpty)
          .where((e) => !_isRetiredDefaultStartCmd(e))
          .toList();
      return cmds.isEmpty ? List.of(defaultStartCmds) : cmds;
    } catch (_) {
      return List.of(defaultStartCmds);
    }
  }

  static KeyChord _loadChord(String? raw) {
    if (raw == null || raw.isEmpty) return KeyChord.defaultSendAgentRef;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return KeyChord.fromJson(map);
    } catch (_) {
      return KeyChord.defaultSendAgentRef;
    }
  }
}
