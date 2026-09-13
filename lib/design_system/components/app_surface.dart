import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';
import '../theme/domovoy_theme_extension.dart';

enum DomovoySurfaceRole { canvas, sidebar, surface, elevated, selected }

class DomovoySurface extends StatelessWidget {
  const DomovoySurface({
    required this.child,
    this.role = DomovoySurfaceRole.surface,
    this.padding,
    this.borderRadius,
    this.border = false,
    this.shadow = false,
    super.key,
  });

  final Widget child;
  final DomovoySurfaceRole role;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry? borderRadius;
  final bool border;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final color = switch (role) {
      DomovoySurfaceRole.canvas => tokens.canvas,
      DomovoySurfaceRole.sidebar => tokens.sidebar,
      DomovoySurfaceRole.surface => tokens.surface,
      DomovoySurfaceRole.elevated => tokens.elevatedSurface,
      DomovoySurfaceRole.selected => tokens.selectedSurface,
    };
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        border: border
            ? Border.all(
                color: tokens.border,
                width: DomovoyDimensions.hairline,
              )
            : null,
        boxShadow: shadow
            ? <BoxShadow>[
                BoxShadow(
                  color: tokens.shadow,
                  blurRadius: tokens.floatingElevation,
                  offset: const Offset(
                    DomovoyDimensions.zero,
                    DomovoyDimensions.space2,
                  ),
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
