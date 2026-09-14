import 'package:flutter/material.dart';

/// Color tokens lifted from docs/mockups/roost-mockups-utility-dense.html so
/// the running app matches the reference mockups rather than drifting to
/// Material defaults. Keep these in sync if the mockup's tokens change.
class RoostColors {
  RoostColors._();

  // Light
  static const lightSurface0 = Color(0xFFF3F2EE);
  static const lightSurface1 = Color(0xFFF8F7F4);
  static const lightSurface2 = Color(0xFFFFFFFF);
  static const lightTextPrimary = Color(0xFF1F1E1C);
  static const lightTextSecondary = Color(0xFF6B6B63);
  static const lightTextMuted = Color(0xFF9C9B93);
  static const lightAccent = Color(0xFF2F6FED);
  static const lightOnAccent = Color(0xFFFFFFFF);
  static const lightSuccess = Color(0xFF3FA360);
  static const lightDanger = Color(0xFFE5484D);

  // Dark
  static const darkSurface0 = Color(0xFF141413);
  static const darkSurface1 = Color(0xFF1C1C1A);
  static const darkSurface2 = Color(0xFF232320);
  static const darkTextPrimary = Color(0xFFF2F1EE);
  static const darkTextSecondary = Color(0xFFA8A79F);
  static const darkTextMuted = Color(0xFF75746C);
  static const darkAccent = Color(0xFF5B8CF5);
  static const darkOnAccent = Color(0xFF0B1220);
  static const darkSuccess = Color(0xFF4BBF78);
  static const darkDanger = Color(0xFFEF5A5F);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: RoostColors.lightAccent,
      brightness: Brightness.light,
      primary: RoostColors.lightAccent,
      onPrimary: RoostColors.lightOnAccent,
      surface: RoostColors.lightSurface1,
      error: RoostColors.lightDanger,
    );
    return _base(colorScheme, RoostColors.lightSurface0, RoostColors.lightTextSecondary);
  }

  static ThemeData dark() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: RoostColors.darkAccent,
      brightness: Brightness.dark,
      primary: RoostColors.darkAccent,
      onPrimary: RoostColors.darkOnAccent,
      surface: RoostColors.darkSurface1,
      error: RoostColors.darkDanger,
    );
    return _base(colorScheme, RoostColors.darkSurface0, RoostColors.darkTextSecondary);
  }

  static ThemeData _base(ColorScheme colorScheme, Color scaffoldBg, Color secondaryText) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBg,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: false,
      ),
      dividerTheme: DividerThemeData(color: colorScheme.onSurface.withOpacity(0.12)),
      textTheme: Typography.material2021().black.apply(bodyColor: colorScheme.onSurface),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: colorScheme.onSurface.withOpacity(0.12)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
    );
  }
}
