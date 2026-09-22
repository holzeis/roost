import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Color tokens pulled from the app's own mark (assets/logo/roost-logo.svg —
/// a slate-blue badge with a cream house-shaped speech bubble) rather than a
/// generic Material seed color unrelated to it, and from
/// docs/mockups/roost-mockups-utility-dense.html's warm-paper neutrals.
/// Keep these in sync if either reference changes.
class RoostColors {
  RoostColors._();

  // Light — "paper" neutrals warmed from the logo's cream, not a cold gray.
  static const lightSurface0 = Color(0xFFE7E0D0);
  static const lightSurface1 = Color(0xFFF7F2E6);
  static const lightSurface2 = Color(0xFFDCD3BE);
  static const lightTextPrimary = Color(0xFF221F1C);
  static const lightTextSecondary = Color(0xFF5B5648);
  static const lightTextMuted = Color(0xFF948E7D);
  static const lightAccent = Color(0xFF4A5C8A); // the logo's own slate blue
  static const lightAccentDeep = Color(0xFF33436B);
  static const lightOnAccent = Color(0xFFFBF3E9); // the logo's own cream
  static const lightSuccess = Color(0xFF3FA360);
  static const lightOchre = Color(0xFF8C5F22); // presence/live/highlight — the one secondary accent
  static const lightDanger = Color(0xFF9A4A3E); // muted brick, not a bright red

  // Dark — an extension of the same brand blue, not a neutral near-black.
  static const darkSurface0 = Color(0xFF14171F);
  static const darkSurface1 = Color(0xFF1C2029);
  static const darkSurface2 = Color(0xFF0F1116);
  static const darkTextPrimary = Color(0xFFECE5D7);
  static const darkTextSecondary = Color(0xFFB7AF9E);
  static const darkTextMuted = Color(0xFF78715F);
  static const darkAccent = Color(0xFF93A6DA);
  static const darkAccentDeep = Color(0xFF6E82B8);
  static const darkOnAccent = Color(0xFF12151F);
  static const darkSuccess = Color(0xFF4BBF78);
  static const darkOchre = Color(0xFFD9A75C);
  static const darkDanger = Color(0xFFCF8A7D);

  // A touch darker/warmer than the scaffold background — the chat screen's
  // wallpaper behind the message bubbles, the same trick WhatsApp uses to
  // give the conversation area its own depth instead of blending into the
  // app chrome above it.
  static const lightChatWallpaper = Color(0xFFDCD3BE);
  static const darkChatWallpaper = Color(0xFF0F1116);
}

/// Chat-bubble constants shared by the message list — kept here rather than
/// hardcoded in chat_screen.dart since the reaction-badge overlay math
/// (media_message.dart, chat_screen.dart) needs to agree with the bubble's
/// own corner radius.
class ChatBubbleStyle {
  ChatBubbleStyle._();

  static const radius = Radius.circular(15);
  static const tailRadius = Radius.circular(5);

  /// The cap a long text bubble's content sizes against.
  static double maxWidth(BuildContext context) =>
      MediaQuery.of(context).size.width * 0.74;

  /// The (wider) cap a photo/video/location-share preview sizes against —
  /// media reads better filling more of the available row than a long
  /// text bubble does, so it gets its own, larger cap rather than sharing
  /// [maxWidth]. A portrait photo never actually reaches this cap (its own
  /// aspect ratio keeps it narrower once [maxHeight] limits it) — this only
  /// widens square/landscape photos, video (always square), and the
  /// location preview (fixed aspect), which otherwise fill the cap exactly.
  static double mediaMaxWidth(BuildContext context) =>
      MediaQuery.of(context).size.width * 0.78;

  static List<BoxShadow> shadow(Brightness brightness) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: brightness == Brightness.dark ? 0.28 : 0.06),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];
}

Color chatWallpaperColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkChatWallpaper
      : RoostColors.lightChatWallpaper;
}

/// The chat screen's tiled doodle wallpaper (assets/wallpaper/) — its own
/// base color already matches [chatWallpaperColor] in each theme, drawn
/// once and repeated behind the message list. Only 2.0x/3.0x variants
/// exist (no 1x file); Flutter's asset resolution finds those from this
/// same base path regardless.
AssetImage chatWallpaperImage(BuildContext context) {
  return AssetImage(Theme.of(context).brightness == Brightness.dark
      ? 'assets/wallpaper/chat_doodle_dark.png'
      : 'assets/wallpaper/chat_doodle_light.png');
}

Color ochreColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkOchre
      : RoostColors.lightOchre;
}

/// The app's "system chrome" typographic register — timestamps, member
/// counts, the tailnet identity string — set apart from ordinary
/// human-written copy the same way a label on a device is set apart from
/// handwriting. Uppercase callers should transform the text themselves;
/// this only sets the type treatment.
TextStyle roostMono(
  BuildContext context, {
  double fontSize = 10.5,
  Color? color,
  FontWeight weight = FontWeight.w500,
  double letterSpacing = 0.3,
}) {
  return GoogleFonts.ibmPlexMono(
    fontSize: fontSize,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color ?? Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
  );
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
    final textTheme = GoogleFonts.hankenGroteskTextTheme(
      Typography.material2021().black.apply(bodyColor: colorScheme.onSurface, displayColor: colorScheme.onSurface),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBg,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffoldBg,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        // The one display face, used sparingly (screen titles only) — see
        // docs/mockups' warm-but-plainspoken direction: a slab serif nods to
        // "roost" as shelter without tipping into precious.
        titleTextStyle: GoogleFonts.zillaSlab(
          color: colorScheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      dividerTheme: DividerThemeData(color: colorScheme.onSurface.withValues(alpha: 0.1)),
      textTheme: textTheme,
      listTileTheme: const ListTileThemeData(minVerticalPadding: 10),
      splashFactory: InkSparkle.splashFactory,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.12)),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
  }
}
