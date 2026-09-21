import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/config.dart';
import 'core/providers.dart';
import 'features/layout/main_layout.dart';
import 'features/settings/settings_page.dart';

class AIReelStudioApp extends ConsumerWidget {
  const AIReelStudioApp({super.key});

  static const _seed = Color(0xFF3B82F6);
  static const _fontFamily = 'Microsoft YaHei';
  static const _fontFallback = ['Microsoft YaHei UI', 'Segoe UI'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final uiScale = ref.watch(uiFontScaleProvider);

    return MaterialApp(
      title: 'AIReelStudio',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: themeMode,
      theme: _buildTheme(Brightness.light, uiScale),
      darkTheme: _buildTheme(Brightness.dark, uiScale),
      home: AppConfig.instance.isConfigured
          ? const MainLayout()
          : const SettingsPage(firstRun: true),
    );
  }

  ThemeData _buildTheme(Brightness brightness, double uiScale) {
    final scheme = _scheme(brightness);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallback,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          foregroundColor: scheme.onSurfaceVariant,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          visualDensity: VisualDensity.compact,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      listTileTheme: ListTileThemeData(
        dense: true,
        selectedTileColor: scheme.primary.withValues(alpha: 0.10),
        selectedColor: scheme.primary,
        iconColor: scheme.onSurfaceVariant,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: scheme.primary.withValues(alpha: 0.14),
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        titleTextStyle: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          fontFamily: _fontFamily,
        ),
        contentTextStyle: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: scheme.onSurfaceVariant,
          fontFamily: _fontFamily,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
    final text = base.textTheme.apply(fontSizeFactor: uiScale);
    return base.copyWith(
      textTheme: text.copyWith(
        titleSmall: text.titleSmall?.copyWith(
          fontSize: 13 * uiScale,
          fontWeight: FontWeight.w600,
          height: 1.25,
        ),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 13 * uiScale, height: 1.35),
        bodySmall: text.bodySmall?.copyWith(
          fontSize: 11 * uiScale,
          color: scheme.onSurfaceVariant,
          height: 1.3,
        ),
      ),
      primaryTextTheme: base.primaryTextTheme.apply(fontSizeFactor: uiScale),
    );
  }

  /// 三层表面：工作台 [ColorScheme.surface] 最干净，侧栏略沉，顶栏再沉一档。
  ColorScheme _scheme(Brightness brightness) {
    final seed = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    if (brightness == Brightness.dark) {
      return seed.copyWith(
        surface: const Color(0xFF14171C),
        surfaceContainerLowest: const Color(0xFF101216),
        surfaceContainerLow: const Color(0xFF1B1F26),
        surfaceContainer: const Color(0xFF222730),
        surfaceContainerHigh: const Color(0xFF2A303A),
        surfaceContainerHighest: const Color(0xFF343B47),
        outlineVariant: const Color(0xFF3C4452),
      );
    }
    return seed.copyWith(
      surface: const Color(0xFFF6F7F9),
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFEEF1F4),
      surfaceContainer: const Color(0xFFE6EAEF),
      surfaceContainerHigh: const Color(0xFFDEE3E9),
      surfaceContainerHighest: const Color(0xFFD3DAE2),
      outlineVariant: const Color(0xFFC9D0D8),
    );
  }
}
