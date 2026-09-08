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
    final base = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: _seed,
        brightness: brightness,
      ),
      useMaterial3: true,
      fontFamily: _fontFamily,
      fontFamilyFallback: _fontFallback,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(fontSizeFactor: uiScale),
      primaryTextTheme: base.primaryTextTheme.apply(fontSizeFactor: uiScale),
    );
  }
}
