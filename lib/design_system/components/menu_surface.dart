import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';
import 'app_surface.dart';

class DomovoyMenuSurface extends StatelessWidget {
  const DomovoyMenuSurface({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => DomovoySurface(
    role: DomovoySurfaceRole.elevated,
    border: true,
    shadow: true,
    borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
    padding: DomovoyDimensions.panelInsets,
    child: child,
  );
}
