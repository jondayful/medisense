import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

/// MediSense organic design system.
///
/// The palette is intentionally quiet and material: rice paper, moss, clay,
/// sand and bark. Components use these tokens instead of inventing local
/// colours, so a dose, a button and navigation all feel like the same app.
class AppTheme {
  static const double cardRadius = 16;

  // ── Organic light tokens ──────────────────────────────────────────────────
  static const Color ink = Color(0xFF5D7052); // moss green
  static const Color foil = Color(0xFFC18C5D); // clay / secondary
  static const Color mint = ink; // shared completed state
  static const Color paper = Color(0xFFFDFCF8); // rice paper
  static const Color card = Colors.white;
  static const Color inkText = Color(0xFF2C2C24); // deep loam
  static const Color mutedText = Color(0xFF747468); // dried grass, AA on paper
  static const Color errorColor = Color(0xFFA85448); // burnt sienna
  static const Color successColor = ink;
  static const Color warningColor = Color(0xFFC18C5D);
  static const Color accent = Color(0xFFE6DCCD); // sand
  static const Color muted = Color(0xFFF0EBE5); // stone
  static const Color timber = Color(0xFFDED8CF); // raw timber
  static const Color primaryForeground = Color(0xFFF3F4F1);
  static const Color secondaryForeground = Colors.white;
  static const Color accentForeground = Color(0xFF4A4A40);

  // ── Aliases kept for compatibility across the app ────────────────────────
  static const Color primaryDark = ink;
  static const Color primaryAccent = accent;
  static const Color accentGreen = mint;
  static const Color background = paper;
  static const Color surface = card;
  static const Color textPrimary = inkText;
  static const Color textSecondary = mutedText;
  static const Color error = errorColor;
  static const Color success = successColor;
  static const Color warning = warningColor;

  // ── Dark tokens ──────────────────────────────────────────────────────────
  static const Color darkBackground = Color(0xFF1C1D17); // night peat
  static const Color darkSurface = Color(0xFF1C1D17);
  static const Color darkCardSurface = Color(0xFF272922); // dark bark
  static const Color darkBorder = Color(0xFF3E4037); // aged timber
  static const Color darkMuted = Color(0xFF2F312A); // dusk stone
  static const Color darkAccent = Color(0xFF383A31); // muted peat
  static const Color darkSegmentTrack = Color(0xFF22241E);
  static const Color darkTextPrimary = Color(0xFFF3F4F1); // pale mist
  static const Color darkTextSecondary = Color(0xFFA8A79B); // sage mist
  static const Color darkAccentGreen = Color(0xFF7D966F);
  static const Color darkFoil = Color(0xFFD49D6A); // warm amber clay
  // 4.74:1 against dark cards, so error labels remain AA-readable rather
  // than relying on color and large type alone.
  static const Color darkError = Color(0xFFDD7465); // coral ember
  static const Color darkSuccess = Color(0xFF7D966F);
  static const Color darkWarning = Color(0xFFD49D6A);
  static const Color darkPrimaryForeground = Color(0xFF1A2016);
  static const Color darkSecondaryForeground = Color(0xFF1C1D17);
  static const Color darkAccentForeground = Color(0xFFE6DCCD);

  // ── Elder tokens — Tarsi palette, purpose-built, high contrast ────────────
  // Emerald is the shared completed-dose accent (never red); it is reused for
  // taken badges, checkmarks, progress states and completed summaries. Coral
  // is reserved for negative states such as overdue or missed doses.
  static const Color elderAction = ink;
  static const Color elderDone = successColor;
  static const Color elderOverdue = errorColor;
  static const Color elderPaper = paper;
  static const Color elderCard = Colors.white;
  static const Color elderInk = inkText;
  static const Color elderMuted = mutedText;
  static const Color elderDarkAction = Color(0xFF7D966F);
  static const Color elderDarkDone = darkSuccess;
  static const Color elderDarkOverdue = darkError;
  static const Color elderDarkPaper = Color(0xFF1C1D17); // night peat
  static const Color elderDarkCard = Color(0xFF272922); // dark bark
  static const Color elderDarkInk = Color(0xFFF3F4F1); // pale mist
  static const Color elderDarkMuted = Color(0xFFA8A79B); // sage mist
  // Dark-mode content tokens are intentionally bright enough for older users.
  static const Color darkAccessibleText = Color(0xFFF3F4F1);
  static const Color darkAccessibleSecondary = Color(0xFFA8A79B);
  static const Color darkInputSurface = Color(0xFF272922);
  static const Color darkInputBorder = Color(0xFF3E4037);

  static const _fontFamily = 'PlusJakartaSans';

  /// Palette used for assigning a per-medication pill colour.
  static const List<Color> medicationColors = [
    Color(0xFF2E7D8E), // teal
    Color(0xFFB8543C), // terracotta
    Color(0xFF3F7C4F), // leaf
    Color(0xFF8E6B2F), // ochre
    Color(0xFF6E5BA8), // violet
    Color(0xFF2E6B6B), // deep teal
    Color(0xFFA84B7A), // plum
    Color(0xFF5A6B61), // sage
  ];

  static TextStyle textStyle({
    double? fontSize,
    FontWeight? fontWeight = FontWeight.w500,
    Color? color,
    double? letterSpacing,
    double? height,
    TextDecoration? decoration,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      letterSpacing: letterSpacing,
      height: height,
      decoration: decoration,
    );
  }

  /// All-caps micro label, the voice of a prescription leaflet: wide tracking,
  /// medium size, always a quiet guide above a headline or a stat.
  static TextStyle microLabel({
    Color? color,
    double fontSize = 11,
    double letterSpacing = 1.2,
    FontWeight fontWeight = FontWeight.w700,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? mutedText,
      letterSpacing: letterSpacing,
      height: 1.2,
    );
  }

  /// Large display figure with tabular digits so numbers never jitter.
  static TextStyle bigNumber({
    double fontSize = 40,
    Color? color,
    FontWeight fontWeight = FontWeight.w800,
    double letterSpacing = -1,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? textPrimary,
      letterSpacing: letterSpacing,
      height: 1,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  /// Dose times and counts rendered in tabular figures — calm, chart-like.
  static TextStyle tabular({
    double fontSize = 15,
    Color? color,
    FontWeight fontWeight = FontWeight.w700,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: _fontFamily,
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color ?? textPrimary,
      letterSpacing: letterSpacing,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  static Color surfaceColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkCardSurface
        : Colors.white;
  }

  static Color borderColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkBorder
        : timber;
  }

  static Color subtleTextColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkTextSecondary
        : mutedText;
  }

  static Color mutedIconColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkTextSecondary
        : timber;
  }

  static Color dividerColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkBorder
        : timber;
  }

  static Color primaryTextColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkTextPrimary
        : textPrimary;
  }

  static Color secondaryTextColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkTextSecondary
        : textSecondary;
  }

  static Color actionColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkAccentGreen
        : ink;
  }

  static Color actionForegroundColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkPrimaryForeground
        : primaryForeground;
  }

  static Color pageColor(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? darkBackground
        : paper;
  }

  // ── Component themes ─────────────────────────────────────────────────────

  static const _buttonShape = StadiumBorder();

  static final _cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(16),
  );

  static InputDecorationTheme _inputTheme({
    required Color fill,
    required Color border,
    required Color focus,
    required Color hint,
  }) {
    return InputDecorationTheme(
      filled: true,
      fillColor: fill,
      hintStyle: AppTheme.textStyle(color: hint),
      labelStyle: AppTheme.textStyle(color: hint),
      floatingLabelStyle: AppTheme.textStyle(
        color: focus,
        fontWeight: FontWeight.w700,
      ),
      prefixIconColor: hint,
      suffixIconColor: hint,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: focus, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
  }

  // ── Themes ───────────────────────────────────────────────────────────────

  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      fontFamily: _fontFamily,
      scaffoldBackgroundColor: paper,
      colorScheme: const ColorScheme.light(
        primary: ink,
        onPrimary: primaryForeground,
        secondary: foil,
        onSecondary: secondaryForeground,
        tertiary: accent,
        surface: card,
        onSurface: inkText,
        error: errorColor,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: ink,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: inkText,
        ),
        iconTheme: IconThemeData(color: inkText, size: 26),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      textTheme: TextTheme(
        headlineLarge: AppTheme.textStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: inkText,
          letterSpacing: -0.5,
          height: 1.1,
        ),
        headlineMedium: AppTheme.textStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: inkText,
          letterSpacing: -0.3,
        ),
        titleLarge: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: inkText,
        ),
        bodyLarge: AppTheme.textStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: inkText,
        ),
        bodyMedium: AppTheme.textStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: mutedText,
        ),
        labelLarge: AppTheme.textStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: primaryForeground,
          elevation: 0,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ink,
          foregroundColor: primaryForeground,
          elevation: 0,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          side: const BorderSide(color: timber),
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          textStyle: AppTheme.textStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: _cardShape.copyWith(side: BorderSide(color: timber, width: 1)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        shape: const StadiumBorder(),
        side: const BorderSide(color: timber),
        labelStyle: AppTheme.textStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: inkText,
        ),
      ),
      inputDecorationTheme: _inputTheme(
        fill: Colors.white,
        border: timber,
        focus: ink,
        hint: mutedText,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) return ink;
          return Colors.black.withValues(alpha: 0.12);
        }),
        thumbColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) return Colors.white;
          return Colors.white;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        // Clear the floating capsule navigation bar, including the large
        // elderly bar, its safe-area spacing, and a 16dp breathing gap.
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 124),
        backgroundColor: inkText,
        contentTextStyle: AppTheme.textStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: inkText,
        ),
        contentTextStyle: AppTheme.textStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: mutedText,
          height: 1.4,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: ink,
        unselectedItemColor: mutedText,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    );
  }

  static ThemeData get darkTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: _fontFamily,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: darkAccentGreen,
        onPrimary: darkPrimaryForeground,
        secondary: darkAccentGreen,
        onSecondary: darkSecondaryForeground,
        surface: darkCardSurface,
        onSurface: darkTextPrimary,
        error: darkError,
        onError: darkSecondaryForeground,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: darkBackground,
        foregroundColor: darkTextPrimary,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: AppTheme.textStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
          color: darkTextPrimary,
        ),
        iconTheme: const IconThemeData(color: darkTextPrimary, size: 26),
      ),
      drawerTheme: const DrawerThemeData(
        backgroundColor: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      textTheme: TextTheme(
        headlineLarge: AppTheme.textStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: darkTextPrimary,
          letterSpacing: -0.5,
          height: 1.1,
        ),
        headlineMedium: AppTheme.textStyle(
          fontSize: 24,
          fontWeight: FontWeight.w800,
          color: darkTextPrimary,
          letterSpacing: -0.3,
        ),
        titleLarge: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: darkTextPrimary,
        ),
        bodyLarge: AppTheme.textStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: darkTextPrimary,
        ),
        bodyMedium: AppTheme.textStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: darkTextSecondary,
        ),
        labelLarge: AppTheme.textStyle(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkAccentGreen,
          foregroundColor: darkPrimaryForeground,
          elevation: 0,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: darkAccentGreen,
          foregroundColor: darkPrimaryForeground,
          elevation: 0,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkTextPrimary,
          minimumSize: const Size(64, 54),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: _buttonShape,
          side: BorderSide(color: Colors.white.withValues(alpha: 0.14)),
          textStyle: AppTheme.textStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: darkAccentGreen,
          textStyle: AppTheme.textStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: darkCardSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: _cardShape.copyWith(
          side: const BorderSide(color: darkBorder, width: 1),
        ),
      ),
      inputDecorationTheme: _inputTheme(
        fill: darkCardSurface,
        border: darkBorder,
        focus: darkAccentGreen,
        hint: darkTextSecondary,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) return darkAccentGreen;
          return Colors.white.withValues(alpha: 0.2);
        }),
        thumbColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) {
            return darkPrimaryForeground;
          }
          return Colors.white;
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 124),
        backgroundColor: darkTextPrimary,
        contentTextStyle: AppTheme.textStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: darkSurface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: darkTextPrimary,
        ),
        contentTextStyle: AppTheme.textStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: darkTextSecondary,
          height: 1.4,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: darkSurface,
        selectedItemColor: darkAccentGreen,
        unselectedItemColor: darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    );
  }

  static ThemeData get elderLightTheme {
    final base = lightTheme;
    return base.copyWith(
      colorScheme: const ColorScheme.light(
        primary: elderInk,
        onPrimary: Colors.white,
        secondary: elderAction,
        onSecondary: Colors.white,
        surface: elderCard,
        onSurface: elderInk,
        error: elderOverdue,
        onError: Colors.white,
      ),
      scaffoldBackgroundColor: elderPaper,
      appBarTheme: const AppBarTheme(
        backgroundColor: elderPaper,
        foregroundColor: elderInk,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 76,
        titleTextStyle: TextStyle(
          fontFamily: _fontFamily,
          fontSize: 28,
          fontWeight: FontWeight.w800,
          color: elderInk,
        ),
        iconTheme: IconThemeData(color: elderInk, size: 30),
      ),
      textTheme: TextTheme(
        headlineLarge: AppTheme.textStyle(
          fontSize: 40,
          fontWeight: FontWeight.w800,
          color: elderInk,
          height: 1.08,
        ),
        headlineMedium: AppTheme.textStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: elderInk,
          height: 1.1,
        ),
        titleLarge: AppTheme.textStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: elderInk,
        ),
        bodyLarge: AppTheme.textStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: elderInk,
          height: 1.3,
        ),
        bodyMedium: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: elderMuted,
          height: 1.3,
        ),
        labelLarge: AppTheme.textStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: elderInk,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: elderInk,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: elderInk,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          side: BorderSide(color: elderInk.withValues(alpha: 0.3)),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: elderCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: BorderSide(color: elderInk, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: elderCard,
        shape: const StadiumBorder(),
        side: BorderSide(color: elderInk.withValues(alpha: 0.14)),
        labelStyle: AppTheme.textStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: elderInk,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: elderCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: AppTheme.textStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: elderInk,
        ),
        contentTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: elderMuted,
          height: 1.4,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 124),
        backgroundColor: elderInk,
        contentTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: elderCard,
        selectedItemColor: elderAction,
        unselectedItemColor: elderMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) return elderDone;
          return Colors.black.withValues(alpha: 0.15);
        }),
        thumbColor: WidgetStateProperty.resolveWith((_) => Colors.white),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      inputDecorationTheme: _inputTheme(
        fill: elderCard,
        border: elderInk.withValues(alpha: 0.15),
        focus: elderAction,
        hint: elderMuted,
      ),
    );
  }

  static ThemeData get elderDarkTheme {
    final base = darkTheme;
    return base.copyWith(
      colorScheme: const ColorScheme.dark(
        primary: elderDarkInk,
        onPrimary: elderDarkPaper,
        secondary: elderDarkAction,
        onSecondary: elderDarkPaper,
        surface: elderDarkCard,
        onSurface: elderDarkInk,
        error: elderDarkOverdue,
        onError: elderDarkPaper,
      ),
      scaffoldBackgroundColor: elderDarkPaper,
      appBarTheme: AppBarTheme(
        backgroundColor: elderDarkPaper,
        foregroundColor: elderDarkInk,
        elevation: 0,
        centerTitle: true,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 76,
        titleTextStyle: AppTheme.textStyle(
          fontSize: 28,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
        ),
        iconTheme: const IconThemeData(color: elderDarkInk, size: 30),
      ),
      textTheme: TextTheme(
        headlineLarge: AppTheme.textStyle(
          fontSize: 40,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
          height: 1.08,
        ),
        headlineMedium: AppTheme.textStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
          height: 1.1,
        ),
        titleLarge: AppTheme.textStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
        ),
        bodyLarge: AppTheme.textStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: elderDarkInk,
          height: 1.3,
        ),
        bodyMedium: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: elderDarkMuted,
          height: 1.3,
        ),
        labelLarge: AppTheme.textStyle(
          fontSize: 22,
          fontWeight: FontWeight.w800,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: elderDarkInk,
          foregroundColor: elderDarkPaper,
          elevation: 0,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: elderDarkInk,
          foregroundColor: elderDarkPaper,
          elevation: 0,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: elderDarkInk,
          minimumSize: const Size(96, 76),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.22)),
          textStyle: AppTheme.textStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: elderDarkCard,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
          side: const BorderSide(color: darkTextPrimary, width: 2),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: elderDarkCard,
        shape: const StadiumBorder(),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
        labelStyle: AppTheme.textStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: elderDarkCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        titleTextStyle: AppTheme.textStyle(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: elderDarkInk,
        ),
        contentTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: elderDarkMuted,
          height: 1.4,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 124),
        backgroundColor: elderDarkInk,
        contentTextStyle: AppTheme.textStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: elderDarkPaper,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: elderDarkCard,
        selectedItemColor: elderDarkAction,
        unselectedItemColor: elderDarkMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      switchTheme: SwitchThemeData(
        trackColor: WidgetStateProperty.resolveWith((state) {
          if (state.contains(WidgetState.selected)) return elderDarkDone;
          return Colors.white.withValues(alpha: 0.18);
        }),
        thumbColor: WidgetStateProperty.resolveWith((_) => Colors.white),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      inputDecorationTheme: _inputTheme(
        fill: darkInputSurface,
        border: darkInputBorder,
        focus: elderDarkAction,
        hint: elderDarkMuted,
      ),
    );
  }
}
