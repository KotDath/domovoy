import 'package:flutter/material.dart';

@immutable
final class DomovoyThemeTokens extends ThemeExtension<DomovoyThemeTokens> {
  const DomovoyThemeTokens({
    required this.canvas,
    required this.sidebar,
    required this.surface,
    required this.elevatedSurface,
    required this.selectedSurface,
    required this.border,
    required this.divider,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentInk,
    required this.userMessage,
    required this.reasoning,
    required this.tool,
    required this.success,
    required this.danger,
    required this.dangerSurface,
    required this.warning,
    required this.shadow,
    required this.lowElevation,
    required this.floatingElevation,
    required this.focusStrokeWidth,
    required this.fastMotion,
    required this.normalMotion,
  });

  final Color canvas;
  final Color sidebar;
  final Color surface;
  final Color elevatedSurface;
  final Color selectedSurface;
  final Color border;
  final Color divider;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentInk;
  final Color userMessage;
  final Color reasoning;
  final Color tool;
  final Color success;
  final Color danger;
  final Color dangerSurface;
  final Color warning;
  final Color shadow;
  final double lowElevation;
  final double floatingElevation;
  final double focusStrokeWidth;
  final Duration fastMotion;
  final Duration normalMotion;

  @override
  DomovoyThemeTokens copyWith({
    Color? canvas,
    Color? sidebar,
    Color? surface,
    Color? elevatedSurface,
    Color? selectedSurface,
    Color? border,
    Color? divider,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? accentInk,
    Color? userMessage,
    Color? reasoning,
    Color? tool,
    Color? success,
    Color? danger,
    Color? dangerSurface,
    Color? warning,
    Color? shadow,
    double? lowElevation,
    double? floatingElevation,
    double? focusStrokeWidth,
    Duration? fastMotion,
    Duration? normalMotion,
  }) => DomovoyThemeTokens(
    canvas: canvas ?? this.canvas,
    sidebar: sidebar ?? this.sidebar,
    surface: surface ?? this.surface,
    elevatedSurface: elevatedSurface ?? this.elevatedSurface,
    selectedSurface: selectedSurface ?? this.selectedSurface,
    border: border ?? this.border,
    divider: divider ?? this.divider,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    accent: accent ?? this.accent,
    accentInk: accentInk ?? this.accentInk,
    userMessage: userMessage ?? this.userMessage,
    reasoning: reasoning ?? this.reasoning,
    tool: tool ?? this.tool,
    success: success ?? this.success,
    danger: danger ?? this.danger,
    dangerSurface: dangerSurface ?? this.dangerSurface,
    warning: warning ?? this.warning,
    shadow: shadow ?? this.shadow,
    lowElevation: lowElevation ?? this.lowElevation,
    floatingElevation: floatingElevation ?? this.floatingElevation,
    focusStrokeWidth: focusStrokeWidth ?? this.focusStrokeWidth,
    fastMotion: fastMotion ?? this.fastMotion,
    normalMotion: normalMotion ?? this.normalMotion,
  );

  @override
  DomovoyThemeTokens lerp(covariant DomovoyThemeTokens? other, double t) {
    if (other == null) return this;
    return DomovoyThemeTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      elevatedSurface: Color.lerp(elevatedSurface, other.elevatedSurface, t)!,
      selectedSurface: Color.lerp(selectedSurface, other.selectedSurface, t)!,
      border: Color.lerp(border, other.border, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      userMessage: Color.lerp(userMessage, other.userMessage, t)!,
      reasoning: Color.lerp(reasoning, other.reasoning, t)!,
      tool: Color.lerp(tool, other.tool, t)!,
      success: Color.lerp(success, other.success, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerSurface: Color.lerp(dangerSurface, other.dangerSurface, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      shadow: Color.lerp(shadow, other.shadow, t)!,
      lowElevation: _lerpDouble(lowElevation, other.lowElevation, t),
      floatingElevation: _lerpDouble(
        floatingElevation,
        other.floatingElevation,
        t,
      ),
      focusStrokeWidth: _lerpDouble(
        focusStrokeWidth,
        other.focusStrokeWidth,
        t,
      ),
      fastMotion: _lerpDuration(fastMotion, other.fastMotion, t),
      normalMotion: _lerpDuration(normalMotion, other.normalMotion, t),
    );
  }

  static double _lerpDouble(double a, double b, double t) => a + (b - a) * t;

  static Duration _lerpDuration(Duration a, Duration b, double t) => Duration(
    microseconds: _lerpDouble(
      a.inMicroseconds.toDouble(),
      b.inMicroseconds.toDouble(),
      t,
    ).round(),
  );
}

extension DomovoyThemeContext on BuildContext {
  DomovoyThemeTokens get domovoyTheme =>
      Theme.of(this).extension<DomovoyThemeTokens>()!;

  Duration domovoyMotion(Duration duration) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : duration;
}
