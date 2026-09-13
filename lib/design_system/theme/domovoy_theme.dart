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
    final base = ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.canvas,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
    );
    final textTheme = base.textTheme
        .apply(
          bodyColor: tokens.textPrimary,
          displayColor: tokens.textPrimary,
          fontFamily: 'sans-serif',
        )
        .copyWith(
          headlineSmall: base.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: tokens.textPrimary,
          ),
          titleMedium: base.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: tokens.textPrimary,
          ),
          labelLarge: base.textTheme.labelLarge?.copyWith(
            fontWeight: FontWeight.w600,
            color: tokens.textPrimary,
          ),
          bodyMedium: base.textTheme.bodyMedium?.copyWith(
            height: 1.45,
            color: tokens.textPrimary,
          ),
          bodySmall: base.textTheme.bodySmall?.copyWith(
            color: tokens.textSecondary,
          ),
          labelSmall: base.textTheme.labelSmall?.copyWith(
            letterSpacing: 0.6,
            color: tokens.textMuted,
          ),
        );
    return base.copyWith(
      textTheme: textTheme,
      extensions: <ThemeExtension<dynamic>>[tokens],
      dividerColor: tokens.divider,
      focusColor: tokens.accent,
      hoverColor: tokens.selectedSurface,
      splashColor: DomovoyPrimitiveTokens.transparent,
      highlightColor: DomovoyPrimitiveTokens.transparent,
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
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
          borderSide: BorderSide(color: tokens.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
          borderSide: BorderSide(color: tokens.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
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
          focusColor: tokens.selectedSurface,
          hoverColor: tokens.selectedSurface,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            DomovoyDimensions.minimumTarget,
            DomovoyDimensions.minimumTarget,
          ),
          backgroundColor: tokens.accent,
          foregroundColor: tokens.accentInk,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
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
    selectedSurface: DomovoyPrimitiveTokens.darkSelected,
    border: DomovoyPrimitiveTokens.darkBorder,
    divider: DomovoyPrimitiveTokens.darkDivider,
    textPrimary: DomovoyPrimitiveTokens.darkText,
    textSecondary: DomovoyPrimitiveTokens.darkTextSecondary,
    textMuted: DomovoyPrimitiveTokens.darkTextMuted,
    accent: DomovoyPrimitiveTokens.darkAccent,
    accentInk: DomovoyPrimitiveTokens.darkAccentInk,
    userMessage: DomovoyPrimitiveTokens.darkUserMessage,
    reasoning: DomovoyPrimitiveTokens.darkReasoning,
    tool: DomovoyPrimitiveTokens.darkTool,
    success: DomovoyPrimitiveTokens.darkSuccess,
    danger: DomovoyPrimitiveTokens.darkDanger,
    dangerSurface: DomovoyPrimitiveTokens.darkDangerSurface,
    warning: DomovoyPrimitiveTokens.darkWarning,
    shadow: DomovoyPrimitiveTokens.shadow,
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
    selectedSurface: DomovoyPrimitiveTokens.lightSelected,
    border: DomovoyPrimitiveTokens.lightBorder,
    divider: DomovoyPrimitiveTokens.lightDivider,
    textPrimary: DomovoyPrimitiveTokens.lightText,
    textSecondary: DomovoyPrimitiveTokens.lightTextSecondary,
    textMuted: DomovoyPrimitiveTokens.lightTextMuted,
    accent: DomovoyPrimitiveTokens.lightAccent,
    accentInk: DomovoyPrimitiveTokens.lightAccentInk,
    userMessage: DomovoyPrimitiveTokens.lightUserMessage,
    reasoning: DomovoyPrimitiveTokens.lightReasoning,
    tool: DomovoyPrimitiveTokens.lightTool,
    success: DomovoyPrimitiveTokens.lightSuccess,
    danger: DomovoyPrimitiveTokens.lightDanger,
    dangerSurface: DomovoyPrimitiveTokens.lightDangerSurface,
    warning: DomovoyPrimitiveTokens.lightWarning,
    shadow: DomovoyPrimitiveTokens.shadow,
    lowElevation: DomovoyDimensions.elevationLow,
    floatingElevation: DomovoyDimensions.elevationFloating,
    focusStrokeWidth: DomovoyDimensions.focusStroke,
    fastMotion: Duration(milliseconds: 120),
    normalMotion: Duration(milliseconds: 220),
  );
}
