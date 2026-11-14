import 'package:flutter/material.dart';

// --- GlobalPay's palette, taken from the live site (globalpay.web.app) and apps/web/src/theme.ts ---
// Paper: #F6F5EF, ink: #171914, yellow: #FFE600 for selection, green: #36744A for success.
// Primary actions are ink on paper, as the site's `.btn-ink`. The navy card is its `.fallback-card`.

class Gp {
  Gp._();

  /// The NEAR showcase build uses the supplied GlobalPay emerald-on-black identity. Ordinary builds
  /// retain the established paper theme, so this visual upgrade does not silently restyle the
  /// existing production wallet.
  static const dark = bool.fromEnvironment('NEAR_MVP', defaultValue: false);

  static const paper = dark ? Color(0xFF050A08) : Color(0xFFF6F5EF);
  static const surface = dark ? Color(0xFF101713) : Color(0xFFFFFEF9);
  static const ink = dark ? Color(0xFFF4F8F6) : Color(0xFF171914);
  static const inkSoft = dark ? Color(0xFF9AA7A0) : Color(0xFF62665C);
  static const line = dark ? Color(0xFF27332D) : Color(0xFFDEDFD5);
  static const action = dark ? Color(0xFF10DFA8) : Color(0xFF171914);
  static const onAction = dark ? Color(0xFF03110C) : Color(0xFFF6F5EF);
  static const yellow = dark ? Color(0xFF10DFA8) : Color(0xFFFFE600);
  static const onYellow = dark ? Color(0xFF03110C) : Color(0xFF171914);
  // Original GlobalPay colors (kept for UI compatibility)
  static const success = dark ? Color(0xFF10DFA8) : Color(0xFF36744A);
  static const green = success;
  static const greenTint = dark ? Color(0xFF12372C) : Color(0xFFE1EDE2);
  static const red = dark ? Color(0xFFFF7373) : Color(0xFFC0392B);
  // Frozen / overlay
  static const ice = dark ? Color(0xFF273A45) : Color(0xFFBFD8EE);
  static const iceInk = dark ? Color(0xFFA8E6FF) : Color(0xFF1C4F7A);
  // Card navy
  static const cardNavy = dark ? Color(0xFF0B1D17) : Color(0xFF14213D);
  static const cardNavyHi = dark ? Color(0xFF195541) : Color(0xFF314774);
  // Gold accents
  static const gold = Color(0xFFC9A14A);
  static const goldHi = Color(0xFFE8CD8A);
  static const goldDeep = Color(0xFFA9832F);
  // Error / warning
  static const warning = dark ? Color(0xFFFFBE55) : Color(0xFF8A5100);
  static const errorContainer = dark ? Color(0xFF4D1F22) : Color(0xFFFFB4AB);
}

/// Display face: headings, amounts, the brand.
TextStyle displayText(double size,
        {FontWeight weight = FontWeight.w800,
        Color color = Gp.ink,
        double? height,
        double? letterSpacing}) =>
    TextStyle(
      fontFamily: 'BricolageGrotesque',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height ?? 1.1,
      letterSpacing: letterSpacing ?? -size * 0.02,
    );

/// Text face: body copy, labels, subtitles.
TextStyle bodyText(double size,
        {FontWeight weight = FontWeight.w400,
        Color color = Gp.ink,
        double? height}) =>
    TextStyle(
      fontFamily: 'InstrumentSans',
      fontSize: size,
      fontWeight: weight,
      color: color,
      height: height ?? 1.5,
    );

// Destructive, reversible actions (freeze): outlined in red, never filled.
// "Remove wallet from this phone": `.link-btn`.
ButtonStyle linkButtonStyle() => TextButton.styleFrom(
      foregroundColor: Gp.inkSoft,
      textStyle: bodyText(14, weight: FontWeight.w500),
    );
ButtonStyle dangerOutlineStyle() => OutlinedButton.styleFrom(
      foregroundColor: Gp.red,
      side: const BorderSide(color: Gp.red, width: 1.5),
      textStyle: bodyText(14, weight: FontWeight.w600),
    );

// The whole app on one light theme, matching the web app's restyled design.
ThemeData globalPayTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF171914),
    onPrimary: Color(0xFFF6F5EF),
    primaryContainer: Color(0xFFE9EADF),
    onPrimaryContainer: Color(0xFF171914),
    secondary: Color(0xFFFFE600),
    onSecondary: Color(0xFF171914),
    secondaryContainer: Color(0xFFFFE600),
    onSecondaryContainer: Color(0xFF171914),
    tertiary: Color(0xFF36744A),
    onTertiary: Color(0xFFF6F5EF),
    tertiaryContainer: Color(0xFFE1EDE2),
    onTertiaryContainer: Color(0xFF36744A),
    error: Color(0xFFC0392B),
    onError: Colors.white,
    errorContainer: Color(0xFFFFB4AB),
    onErrorContainer: Colors.white,
    surface: Color(0xFFFFFEF9),
    onSurface: Color(0xFF171914),
    onSurfaceVariant: Color(0xFF62665C),
    surfaceDim: Color(0xFFF6F5EF),
    surfaceBright: Color(0xFFFFFEF9),
    surfaceContainerLowest: Color(0xFFFFFEF9),
    surfaceContainerLow: Color(0xFFF6F5EF),
    surfaceContainer: Color(0xFFEEEFE6),
    surfaceContainerHigh: Color(0xFFEEEFE6),
    surfaceContainerHighest: Color(0xFFE9EADF),
    outline: Color(0xFFDEDFD5),
    outlineVariant: Color(0xFFDEDFD5),
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF171914),
    onInverseSurface: Color(0xFFF6F5EF),
    inversePrimary: Color(0xFFEEEFE6),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: Gp.paper,
    textTheme: const TextTheme(
      displayLarge: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 34,
          fontWeight: FontWeight.w800,
          height: 1.08,
          letterSpacing: -0.7,
          color: Gp.ink),
      displayMedium: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 28,
          fontWeight: FontWeight.w800,
          height: 1.08,
          letterSpacing: -0.6,
          color: Gp.ink),
      displaySmall: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 24,
          fontWeight: FontWeight.w800,
          height: 1.1,
          letterSpacing: -0.5,
          color: Gp.ink),
      headlineLarge: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 26,
          fontWeight: FontWeight.w800,
          height: 1.1,
          letterSpacing: -0.5,
          color: Gp.ink),
      headlineMedium: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 22,
          fontWeight: FontWeight.w700,
          height: 1.15,
          letterSpacing: -0.4,
          color: Gp.ink),
      headlineSmall: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 20,
          fontWeight: FontWeight.w700,
          height: 1.2,
          letterSpacing: -0.3,
          color: Gp.ink),
      titleLarge: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          height: 1.3,
          letterSpacing: -0.2,
          color: Gp.ink),
      titleMedium: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.4,
          color: Gp.ink),
      titleSmall: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.4,
          color: Gp.ink),
      bodyLarge: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 17,
          fontWeight: FontWeight.w400,
          height: 1.5,
          color: Gp.ink),
      bodyMedium: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 16,
          fontWeight: FontWeight.w400,
          height: 1.5,
          color: Gp.ink),
      bodySmall: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 13,
          fontWeight: FontWeight.w400,
          height: 1.4,
          color: Gp.inkSoft),
      labelLarge: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.2,
          color: Gp.ink),
      labelMedium: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.3,
          color: Gp.ink),
      labelSmall: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          height: 1.3,
          color: Gp.inkSoft),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Gp.paper,
      foregroundColor: Gp.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: Gp.ink),
      titleTextStyle: TextStyle(
          fontFamily: 'BricolageGrotesque',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: Gp.ink),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Gp.action,
        foregroundColor: Gp.onAction,
        disabledBackgroundColor: Gp.action.withValues(alpha: 0.55),
        disabledForegroundColor: Gp.onAction,
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        textStyle: const TextStyle(
            fontFamily: 'InstrumentSans',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            height: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Gp.ink,
        backgroundColor: Gp.surface,
        disabledForegroundColor: Gp.inkSoft,
        side: const BorderSide(color: Gp.line, width: 1.5),
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        textStyle: const TextStyle(
            fontFamily: 'InstrumentSans',
            fontSize: 17,
            fontWeight: FontWeight.w600,
            height: 1.2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: linkButtonStyle()),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Gp.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      labelStyle: bodyText(15, color: Gp.inkSoft),
      floatingLabelStyle:
          bodyText(14, weight: FontWeight.w600, color: Gp.action),
      hintStyle: bodyText(15, color: Gp.inkSoft),
      prefixStyle: const TextStyle(
          fontFamily: 'InstrumentSans', fontSize: 17, color: Gp.ink),
      suffixStyle: bodyText(15, color: Gp.inkSoft),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Gp.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Gp.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Gp.action, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Gp.red),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
        borderSide: BorderSide(color: Gp.red, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Gp.ink,
      contentTextStyle: bodyText(15, color: Gp.onAction),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Gp.action,
      linearTrackColor: Gp.line,
      circularTrackColor: Gp.line,
    ),
    dividerTheme:
        const DividerThemeData(color: Gp.line, thickness: 1, space: 1),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Gp.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.zero,
      titleTextStyle: TextStyle(
          fontFamily: 'InstrumentSans',
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: Gp.ink),
      subtitleTextStyle: TextStyle(
          fontFamily: 'InstrumentSans', fontSize: 13, color: Gp.inkSoft),
      iconColor: Gp.inkSoft,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Gp.action,
      selectionHandleColor: Gp.action,
      selectionColor: Color(0x66FFE600),
    ),
    focusColor: Gp.action.withValues(alpha: 0.15),
    hoverColor: Gp.action.withValues(alpha: 0.06),
    highlightColor: Gp.ink.withValues(alpha: 0.06),
    splashColor: Gp.action.withValues(alpha: 0.12),
  );
}

/// Emerald-on-black GlobalPay wallet theme used by the integrated NEAR showcase APK.
ThemeData globalPayDarkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Gp.action,
    onPrimary: Gp.onAction,
    primaryContainer: Color(0xFF12372C),
    onPrimaryContainer: Gp.ink,
    secondary: Color(0xFF62F5CB),
    onSecondary: Color(0xFF03110C),
    secondaryContainer: Color(0xFF173E32),
    onSecondaryContainer: Gp.ink,
    tertiary: Color(0xFFA8E6D4),
    onTertiary: Color(0xFF07130F),
    tertiaryContainer: Color(0xFF203B33),
    onTertiaryContainer: Gp.ink,
    error: Gp.red,
    onError: Color(0xFF210000),
    errorContainer: Gp.errorContainer,
    onErrorContainer: Color(0xFFFFDAD8),
    surface: Gp.surface,
    onSurface: Gp.ink,
    onSurfaceVariant: Gp.inkSoft,
    surfaceDim: Gp.paper,
    surfaceBright: Color(0xFF1C2621),
    surfaceContainerLowest: Color(0xFF030705),
    surfaceContainerLow: Gp.surface,
    surfaceContainer: Color(0xFF141D18),
    surfaceContainerHigh: Color(0xFF19231E),
    surfaceContainerHighest: Color(0xFF202B25),
    outline: Gp.line,
    outlineVariant: Color(0xFF1D2923),
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: Gp.ink,
    onInverseSurface: Color(0xFF101713),
    inversePrimary: Color(0xFF007E5E),
  );
  final base = ThemeData.dark(useMaterial3: true);
  final textTheme = base.textTheme
      .apply(
        fontFamily: 'InstrumentSans',
        bodyColor: Gp.ink,
        displayColor: Gp.ink,
      )
      .copyWith(
        displayLarge: displayText(40),
        displayMedium: displayText(32),
        displaySmall: displayText(26),
        headlineLarge: displayText(28),
        headlineMedium: displayText(23, weight: FontWeight.w700),
        headlineSmall: displayText(20, weight: FontWeight.w700),
        titleLarge: displayText(19, weight: FontWeight.w700),
        titleMedium: bodyText(16, weight: FontWeight.w600),
        bodyLarge: bodyText(17),
        bodyMedium: bodyText(15),
        bodySmall: bodyText(13, color: Gp.inkSoft),
        labelLarge: bodyText(16, weight: FontWeight.w700),
        labelMedium: bodyText(14, weight: FontWeight.w600),
      );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: Gp.paper,
    canvasColor: Gp.paper,
    fontFamily: 'InstrumentSans',
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: Gp.paper,
      foregroundColor: Gp.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: Gp.ink),
      titleTextStyle: TextStyle(
        fontFamily: 'BricolageGrotesque',
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: Gp.ink,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Gp.action,
        foregroundColor: Gp.onAction,
        disabledBackgroundColor: Gp.line,
        disabledForegroundColor: Gp.inkSoft,
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        textStyle: bodyText(16, weight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Gp.ink,
        backgroundColor: const Color(0xFF121A16),
        disabledForegroundColor: Gp.inkSoft,
        side: const BorderSide(color: Gp.line, width: 1.2),
        minimumSize: const Size(0, 54),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        textStyle: bodyText(16, weight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Gp.action,
        textStyle: bodyText(14, weight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFF111914),
      contentPadding: const EdgeInsets.symmetric(horizontal: 17, vertical: 17),
      labelStyle: bodyText(14, color: Gp.inkSoft),
      floatingLabelStyle:
          bodyText(13, weight: FontWeight.w600, color: Gp.action),
      hintStyle: bodyText(14, color: Gp.inkSoft),
      helperStyle: bodyText(12, color: Gp.inkSoft),
      prefixStyle: bodyText(16),
      suffixStyle: bodyText(14, color: Gp.inkSoft),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
        borderSide: BorderSide(color: Gp.line),
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
        borderSide: BorderSide(color: Gp.line),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
        borderSide: BorderSide(color: Gp.action, width: 1.5),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(17)),
        borderSide: BorderSide(color: Gp.red),
      ),
    ),
    dividerTheme:
        const DividerThemeData(color: Gp.line, thickness: 1, space: 1),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Gp.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: Gp.line,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: Gp.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(24))),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0C120F),
      indicatorColor: Gp.greenTint,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
            color:
                states.contains(WidgetState.selected) ? Gp.action : Gp.inkSoft),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => bodyText(11,
            weight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? Gp.ink : Gp.inkSoft),
      ),
      elevation: 0,
      height: 72,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: const Color(0xFF1B2822),
      contentTextStyle: bodyText(14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Gp.action,
      linearTrackColor: Gp.line,
      circularTrackColor: Gp.line,
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: Gp.inkSoft,
      textColor: Gp.ink,
      contentPadding: EdgeInsets.zero,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Gp.action,
      selectionHandleColor: Gp.action,
      selectionColor: Color(0x5510DFA8),
    ),
  );
}
