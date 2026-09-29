import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Color tokens for the WhatsApp-style palette (chosen 2026-09-29 from the
/// palette proposals): a teal-green accent, beige chat wallpaper, and
/// sent bubbles in their own pale/dark green rather than the accent — so
/// sent bubbles have dedicated tokens ([lightSentBubble] etc.) instead of
/// reusing the accent/onAccent pair the way the previous palette did.
class RoostColors {
  RoostColors._();

  // Light. lightSurface0 is the one exception, and is deliberately NOT trying to
  // match iOS's own QuickType predictive-text-bar gray (that's a fixed
  // native strip this app's theme can't recolor anyway). It's this value
  // that has to match instead: at the bar's rounded top corners, the
  // curved cutout reveals whatever sits behind it, which is the native
  // root view's own background — see the LaunchBackground.colorset comment
  // in chat_screen.dart for why that's a second, native source of truth
  // that must be hand-kept equal to this one. This exact value (0xD7D7DC)
  // is the user's own color-picked value off a real device. See
  // darkSurface0 below for the same fix in dark mode.
  static const lightSurface0 = Color(0xFFD7D7DC);
  static const lightSurface1 = Color(0xFFFFFFFF);
  static const lightSurface2 = Color(0xFFEFEAE2);
  static const lightTextPrimary = Color(0xFF111B21);
  static const lightTextSecondary = Color(0xFF54656F);
  static const lightTextMuted = Color(0xFF8696A0);
  static const lightAccent = Color(0xFF008069); // teal green
  static const lightAccentDeep = Color(0xFF00735E);
  static const lightOnAccent = Color(0xFFFFFFFF);
  static const lightSuccess = Color(0xFF1FA855);
  static const lightSecondaryAccent = Color(0xFF027EB5); // presence/live/highlight — the one secondary accent
  static const lightDanger = Color(0xFFEA0038);
  static const lightSentBubble = Color(0xFFD9FDD3);
  static const lightOnSentBubble = Color(0xFF111B21);
  static const lightReadTick = Color(0xFF53BDEB);

  // Dark. darkSurface0 is the same exception as lightSurface0 above, matched to
  // LaunchBackground.colorset's dark variant for the same reason. This
  // exact value (0x18191C) is the user's own color-picked value off a real
  // device.
  static const darkSurface0 = Color(0xFF18191C);
  static const darkSurface1 = Color(0xFF202C33);
  static const darkSurface2 = Color(0xFF0B141A);
  static const darkTextPrimary = Color(0xFFE9EDEF);
  static const darkTextSecondary = Color(0xFFAEBAC1);
  static const darkTextMuted = Color(0xFF8696A0);
  static const darkAccent = Color(0xFF00A884);
  static const darkAccentDeep = Color(0xFF00A884);
  static const darkOnAccent = Color(0xFF111B21);
  static const darkSuccess = Color(0xFF25D366);
  static const darkSecondaryAccent = Color(0xFF53BDEB);
  static const darkDanger = Color(0xFFF15C6D);
  static const darkSentBubble = Color(0xFF005C4B);
  static const darkOnSentBubble = Color(0xFFE9EDEF);
  static const darkReadTick = Color(0xFF53BDEB);

  // A touch darker/warmer than the scaffold background — the chat screen's
  // wallpaper behind the message bubbles, the same trick WhatsApp uses to
  // give the conversation area its own depth instead of blending into the
  // app chrome above it.
  static const lightChatWallpaper = Color(0xFFEFEAE2);
  static const darkChatWallpaper = Color(0xFF0B141A);
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

Color secondaryAccentColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkSecondaryAccent
      : RoostColors.lightSecondaryAccent;
}

/// The viewer's own message bubbles — deliberately not the accent (see
/// [RoostColors]).
Color sentBubbleColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkSentBubble
      : RoostColors.lightSentBubble;
}

/// Text and icons on [sentBubbleColor].
Color onSentBubbleColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkOnSentBubble
      : RoostColors.lightOnSentBubble;
}

/// The seen (read) double-check on the viewer's own messages (FR1.6).
Color readTickColor(BuildContext context) {
  return Theme.of(context).brightness == Brightness.dark
      ? RoostColors.darkReadTick
      : RoostColors.lightReadTick;
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
