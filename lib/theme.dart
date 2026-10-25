import 'package:flutter/material.dart';

import 'ui/tokens.dart';

/// SubMac brand palette: warm paper, deep ink, one signature red.
class Palette {
  final Color bg;
  final Color sidebar;
  final Color bubble;
  final Color composer;
  final Color sheet;
  final Color border;
  final Color text;
  final Color muted;
  final Color code;
  final Color accent;
  final Color accentWash;

  /// Presence only: a warm olive-sage. Never a stock green.
  final Color ok;

  /// Third level of text: timestamps, hints, labels over outputs (luxury UI).
  final Color faint;

  /// The one line weight: under a table row, around the composer.
  final Color hairline;

  /// Bot status rings (Bots workspace rail, owner 2026-10-24): working, waiting for the owner's OK, finished with
  /// results not read yet, and idle. Soft, desaturated tones that sit calmly on the sky.
  final Color statusWorking;
  final Color statusWaiting;
  final Color statusDone;
  final Color statusIdle;

  const Palette({
    required this.bg,
    required this.sidebar,
    required this.bubble,
    required this.composer,
    required this.sheet,
    required this.border,
    required this.text,
    required this.muted,
    required this.code,
    required this.accent,
    required this.accentWash,
    required this.ok,
    required this.faint,
    required this.hairline,
    required this.statusWorking,
    required this.statusWaiting,
    required this.statusDone,
    required this.statusIdle,
  });

  static const red = Color(0xFFC2361B);

  /// Paper (2026-10-20 redesign, plan 5.5): a clean, bright paper white with only a breath of warmth,
  /// pure white cards and fields, whisper-light lines and soft shadows, ink text and the one brand red.
  /// It mirrors Ink (dark): the same calm structure, just in daylight.
  static const light = Palette(
    bg: Color(0xFFFAF9F6),
    sidebar: Color(0xFFF3F1EC),
    bubble: Color(0xFFEFEDE8),
    composer: Color(0xFFFFFFFF),
    sheet: Color(0xFFFFFFFF),
    border: Color(0xFFE6E2DA),
    text: Color(0xFF121110),
    muted: Color(0xFF6F6B64),
    code: Color(0xFF121110),
    // Accent is only for warnings and destructive actions (Delete, errors). Everything else is ink.
    accent: red,
    accentWash: Color(0xFFFBEAE5),
    ok: Color(0xFF5E7A4C),
    faint: Color(0xFF9C978E),
    hairline: Color(0xFFECE9E2),
    statusWorking: Color(0xFF3F9A5B),
    statusWaiting: Color(0xFFD9A21E),
    statusDone: Color(0xFF3B78D8),
    statusIdle: Color(0xFFC9C5BD),
  );

  /// Ink: pure OLED black (#000000) with neutral greys, white text and the brand red.
  static const dark = Palette(
    bg: Color(0xFF000000),
    sidebar: Color(0xFF000000),
    bubble: Color(0xFF1A1A1A),
    composer: Color(0xFF0F0F0F),
    sheet: Color(0xFF111111),
    border: Color(0xFF262626),
    text: Color(0xFFF7F7F5),
    muted: Color(0xFF9B9B98),
    code: Color(0xFF0A0A0A),
    accent: Color(0xFFE0452A),
    accentWash: Color(0xFF2A100B),
    ok: Color(0xFF8FAE7B),
    faint: Color(0xFF6A6A67),
    hairline: Color(0xFF1C1C1C),
    statusWorking: Color(0xFF5CC27A),
    statusWaiting: Color(0xFFF2C14E),
    statusDone: Color(0xFF6AA0F0),
    statusIdle: Color(0xFF4A4A47),
  );

  static Palette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

/// Brand type (owner, 2026-10-23): one refined bold sans for display text (the SubMac wordmark,
/// titles, headings, your short messages, call names) and the Geist reading sans for everything you
/// read. No serif in the app UI any more (documents SubMac makes may still use one).
class Brand {
  static const sans = 'Geist';

  /// Display sizes were drawn for the old serif, which sets much smaller on the line; the bold sans
  /// takes [displayScale] of the size so a title keeps the same visual weight in the layout.
  static const double displayScale = 0.84;

  /// The display face: Geist semibold, tight tracking, short leading.
  static TextStyle display({double size = 32, Color? color, FontWeight weight = FontWeight.w600, double? height}) {
    final s = size * displayScale;
    return TextStyle(
        fontFamily: sans,
        fontSize: s,
        color: color,
        fontWeight: weight,
        height: height ?? 1.12,
        letterSpacing: -0.022 * s);
  }

  /// Legacy name kept so every caller moved to the bold sans at once. [style] is ignored: the display
  /// face has no italic.
  static TextStyle serif({double size = 32, Color? color, FontStyle? style, double? height}) =>
      display(size: size, color: color, height: height);

  static TextStyle mono({double size = 13, Color? color, double? height}) =>
      TextStyle(fontFamily: 'GeistMono', fontSize: size, color: color, height: height ?? 1.45);
}

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.dark ? Palette.dark : Palette.light;
  final base = ThemeData(useMaterial3: true, brightness: b, fontFamily: Brand.sans);
  // One type system: the bold display sans for titles and big moments, Geist for everything you read.
  final sans = base.textTheme.apply(bodyColor: p.text, displayColor: p.text, fontFamily: Brand.sans);
  final textTheme = sans.copyWith(
    displayLarge: Brand.serif(size: 52, color: p.text),
    displayMedium: Brand.serif(size: 44, color: p.text),
    displaySmall: Brand.serif(size: 36, color: p.text),
    headlineLarge: Brand.serif(size: 32, color: p.text),
    headlineMedium: Brand.serif(size: 28, color: p.text),
    headlineSmall: Brand.serif(size: 24, color: p.text),
    titleLarge: Brand.serif(size: 22, color: p.text),
    bodyLarge: sans.bodyLarge?.copyWith(height: 1.45),
    bodyMedium: sans.bodyMedium?.copyWith(height: 1.45),
  );
  final scheme = ColorScheme.fromSeed(seedColor: Palette.red, brightness: b).copyWith(
    primary: p.text,
    onPrimary: p.bg,
    secondary: p.accent,
    onSecondary: Colors.white,
    error: b == Brightness.dark ? const Color(0xFFF2B8B5) : const Color(0xFFB3261E),
    surface: p.bg,
    onSurface: p.text,
    surfaceContainerHighest: p.bubble,
    outline: p.border,
    outlineVariant: p.border,
  );
  return base.copyWith(
    colorScheme: scheme,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    // Daylight's sky and Ink's night sky are painted behind every screen (main.dart), so pages are see-through.
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: p.bg,
    // No lines (PLAN.md 3.1): space and soft fills do the separating. Any stray Divider renders as spacing.
    dividerColor: Colors.transparent,
    dividerTheme: const DividerThemeData(color: Colors.transparent, thickness: 0, space: Space.x3),
    splashFactory: InkRipple.splashFactory,
    highlightColor: p.text.withValues(alpha: 0.04),
    splashColor: p.text.withValues(alpha: 0.06),
    // SubMac's own screen motion (ui/motion.dart): a fade with a small rise that settles.
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: SubPageTransitions(),
      TargetPlatform.iOS: SubPageTransitions(),
    }),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      titleTextStyle: Brand.serif(size: AppText.display, color: p.text, height: 1.0),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: p.sidebar, surfaceTintColor: Colors.transparent),
    // Sheets are the paper itself rising: the page colour, no handle glyph, no shadow line.
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      modalBackgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: Radii.sheetAll),
      titleTextStyle: Brand.serif(size: AppText.display, color: p.text),
    ),
    // A note at the foot of the paper: plain words, no pill.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.bg,
      contentTextStyle: TextStyle(fontFamily: Brand.sans, color: p.text, fontSize: AppText.meta, fontWeight: FontWeight.w500),
      actionTextColor: p.text,
      elevation: 0,
      behavior: SnackBarBehavior.fixed,
    ),
    cardTheme: const CardThemeData(color: Colors.transparent, elevation: 0, margin: EdgeInsets.zero, surfaceTintColor: Colors.transparent),
    popupMenuTheme: PopupMenuThemeData(color: p.bg, elevation: 2, surfaceTintColor: Colors.transparent, shape: const RoundedRectangleBorder(borderRadius: Radii.fieldAll)),
    // UI rules: no outlines. A field is a whisper of tone on the paper, with nothing drawn around it,
    // even when focused (the cursor and the hint's tone say where you are).
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.text.withValues(alpha: 0.035),
      hintStyle: TextStyle(color: p.faint),
      border: const OutlineInputBorder(borderRadius: Radii.fieldAll, borderSide: BorderSide.none),
      enabledBorder: const OutlineInputBorder(borderRadius: Radii.fieldAll, borderSide: BorderSide.none),
      focusedBorder: const OutlineInputBorder(borderRadius: Radii.fieldAll, borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      // UI rules: no boxes. The main action is a bold word on the paper, not a filled block.
      style: FilledButton.styleFrom(
        backgroundColor: Colors.transparent,
        disabledBackgroundColor: Colors.transparent,
        foregroundColor: p.text,
        disabledForegroundColor: p.faint,
        elevation: 0,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: Radii.fieldAll),
        textStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.lead, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: Radii.fieldAll),
        // No outline (UI rules): a second action is a medium-weight word.
        side: BorderSide.none,
        textStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.lead, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.text,
        textStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.body, fontWeight: FontWeight.w600),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.text,
      textColor: p.text,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18),
      titleTextStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.lead, color: p.text, fontWeight: FontWeight.w500),
      subtitleTextStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.meta, color: p.muted, height: 1.35),
    ),
    chipTheme: ChipThemeData(
      // A chip is a word with a whisper of tone, never an outline.
      backgroundColor: p.text.withValues(alpha: 0.04),
      selectedColor: p.text,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.meta, color: p.text),
      secondaryLabelStyle: TextStyle(fontFamily: Brand.sans, fontSize: AppText.meta, color: p.bg),
      showCheckmark: false,
    ),
    sliderTheme: SliderThemeData(activeTrackColor: p.text, thumbColor: p.text, inactiveTrackColor: p.border),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.text),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : p.muted),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.accent : p.bubble),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
  );
}
