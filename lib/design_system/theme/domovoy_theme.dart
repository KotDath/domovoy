import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';
import '../foundations/primitive_tokens.dart';
import 'domovoy_theme_extension.dart';

abstract final class DomovoyTheme {
  static ThemeData dark() => _build(brightness: Brightness.dark);

  static ThemeData light() => _build(brightness: Brightness.light);

  static ThemeData _build({required Brightness brightness}) {
    final dark = brightness == Brightness.dark;
    final tokens = dark ? _darkTokens : _lightTokens;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: tokens.accent,
      onPrimary: tokens.accentInk,
      secondary: tokens.textSecondary,
      onSecondary: tokens.canvas,
      error: tokens.danger,
      onError: tokens.canvas,
      surface: tokens.surface,
      onSurface: tokens.textPrimary,
    );
    final textTheme = TextTheme(
      headlineSmall: TextStyle(
        fontSize: 26,
        height: 1.3,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.7,
        color: tokens.textPrimary,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        height: 1.35,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.4,
        color: tokens.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: DomovoyDimensions.brandSize,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: tokens.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: DomovoyDimensions.bodySize,
        height: 1.4,
        fontWeight: FontWeight.w600,
        color: tokens.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: DomovoyDimensions.bodySize,
        height: DomovoyDimensions.bodyHeight,
        fontWeight: FontWeight.w400,
        color: tokens.textPrimary,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        height: 1.45,
        color: tokens.textSecondary,
      ),
      labelLarge: TextStyle(
        fontSize: DomovoyDimensions.chatRowSize,
        height: 1.5,
        fontWeight: FontWeight.w500,
        color: tokens.textPrimary,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: tokens.textSecondary,
      ),
      labelSmall: TextStyle(
        fontSize: DomovoyDimensions.sectionLabelSize,
        height: 1.4,
        letterSpacing: 0.3,
        color: tokens.textMuted,
      ),
    );
    final base = ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.canvas,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      splashFactory: NoSplash.splashFactory,
      textTheme: textTheme,
    );
    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[tokens],
      dividerColor: tokens.divider,
      focusColor: tokens.accent,
      hoverColor: tokens.hover,
      splashColor: DomovoyPrimitiveTokens.transparent,
      highlightColor: DomovoyPrimitiveTokens.transparent,
      iconTheme: IconThemeData(
        color: tokens.textSecondary,
        size: DomovoyDimensions.iconSmall,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.elevatedSurface,
        surfaceTintColor: DomovoyPrimitiveTokens.transparent,
        elevation: tokens.floatingElevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
          side: BorderSide(color: tokens.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.surface,
        hintStyle: textTheme.bodyMedium?.copyWith(color: tokens.textMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusSmall),
          borderSide: BorderSide(color: tokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusSmall),
          borderSide: BorderSide(color: tokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusSmall),
          borderSide: BorderSide(
            color: tokens.accent,
            width: tokens.focusStrokeWidth,
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(DomovoyDimensions.minimumTarget),
          foregroundColor: tokens.textSecondary,
          focusColor: tokens.hover,
          hoverColor: tokens.hover,
          highlightColor: DomovoyPrimitiveTokens.transparent,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            DomovoyDimensions.minimumTarget,
            DomovoyDimensions.minimumTarget,
          ),
          backgroundColor: tokens.accentMuted,
          foregroundColor: tokens.accent,
          elevation: DomovoyDimensions.zero,
          shadowColor: DomovoyPrimitiveTokens.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              DomovoyDimensions.radiusControl,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(
            DomovoyDimensions.minimumTarget,
            DomovoyDimensions.minimumTarget,
          ),
          foregroundColor: tokens.textPrimary,
          overlayColor: tokens.hover,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              DomovoyDimensions.radiusControl,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(
            DomovoyDimensions.minimumTarget,
            DomovoyDimensions.minimumTarget,
          ),
          foregroundColor: tokens.textPrimary,
          overlayColor: tokens.hover,
          side: BorderSide(color: tokens.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(
              DomovoyDimensions.radiusControl,
            ),
          ),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: tokens.sidebar,
        surfaceTintColor: DomovoyPrimitiveTokens.transparent,
        shape: const RoundedRectangleBorder(),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: tokens.accent),
    );
  }

  static const _darkTokens = DomovoyThemeTokens(
    canvas: DomovoyPrimitiveTokens.darkCanvas,
    sidebar: DomovoyPrimitiveTokens.darkSidebar,
    surface: DomovoyPrimitiveTokens.darkSurface,
    elevatedSurface: DomovoyPrimitiveTokens.darkElevated,
    selectedSurface: DomovoyPrimitiveTokens.darkHover,
    hover: DomovoyPrimitiveTokens.darkHover,
    border: DomovoyPrimitiveTokens.darkBorder,
    divider: DomovoyPrimitiveTokens.darkBorder,
    textPrimary: DomovoyPrimitiveTokens.darkText,
    textSecondary: DomovoyPrimitiveTokens.darkTextSecondary,
    textMuted: DomovoyPrimitiveTokens.darkTextMuted,
    accent: DomovoyPrimitiveTokens.darkAccent,
    accentMuted: DomovoyPrimitiveTokens.darkAccentMuted,
    accentInk: DomovoyPrimitiveTokens.darkAccentInk,
    userMessage: DomovoyPrimitiveTokens.darkUserMessage,
    reasoning: DomovoyPrimitiveTokens.darkReasoning,
    tool: DomovoyPrimitiveTokens.darkTool,
    success: DomovoyPrimitiveTokens.darkSuccess,
    danger: DomovoyPrimitiveTokens.darkDanger,
    dangerSurface: DomovoyPrimitiveTokens.darkDangerSurface,
    warning: DomovoyPrimitiveTokens.darkWarning,
    shadow: DomovoyPrimitiveTokens.darkShadow,
    lowElevation: DomovoyDimensions.elevationLow,
    floatingElevation: DomovoyDimensions.elevationFloating,
    focusStrokeWidth: DomovoyDimensions.focusStroke,
    fastMotion: Duration(milliseconds: 120),
    normalMotion: Duration(milliseconds: 220),
  );

  static const _lightTokens = DomovoyThemeTokens(
    canvas: DomovoyPrimitiveTokens.lightCanvas,
    sidebar: DomovoyPrimitiveTokens.lightSidebar,
    surface: DomovoyPrimitiveTokens.lightSurface,
    elevatedSurface: DomovoyPrimitiveTokens.lightElevated,
    selectedSurface: DomovoyPrimitiveTokens.lightHover,
    hover: DomovoyPrimitiveTokens.lightHover,
    border: DomovoyPrimitiveTokens.lightBorder,
    divider: DomovoyPrimitiveTokens.lightBorder,
    textPrimary: DomovoyPrimitiveTokens.lightText,
    textSecondary: DomovoyPrimitiveTokens.lightTextSecondary,
    textMuted: DomovoyPrimitiveTokens.lightTextMuted,
    accent: DomovoyPrimitiveTokens.lightAccent,
    accentMuted: DomovoyPrimitiveTokens.lightAccentMuted,
    accentInk: DomovoyPrimitiveTokens.lightAccentInk,
    userMessage: DomovoyPrimitiveTokens.lightUserMessage,
    reasoning: DomovoyPrimitiveTokens.lightReasoning,
    tool: DomovoyPrimitiveTokens.lightTool,
    success: DomovoyPrimitiveTokens.lightSuccess,
    danger: DomovoyPrimitiveTokens.lightDanger,
    dangerSurface: DomovoyPrimitiveTokens.lightDangerSurface,
    warning: DomovoyPrimitiveTokens.lightWarning,
    shadow: DomovoyPrimitiveTokens.lightShadow,
    lowElevation: DomovoyDimensions.elevationLow,
    floatingElevation: DomovoyDimensions.elevationFloating,
    focusStrokeWidth: DomovoyDimensions.focusStroke,
    fastMotion: Duration(milliseconds: 120),
    normalMotion: Duration(milliseconds: 220),
  );
}
