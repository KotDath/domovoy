import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';
import '../theme/domovoy_theme_extension.dart';

enum DomovoyStatusTone { neutral, success, warning, danger }

class DomovoyStatusChip extends StatelessWidget {
  const DomovoyStatusChip({
    required this.label,
    this.tone = DomovoyStatusTone.neutral,
    this.icon,
    super.key,
  });

  final String label;
  final DomovoyStatusTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final foreground = switch (tone) {
      DomovoyStatusTone.neutral => tokens.textSecondary,
      DomovoyStatusTone.success => tokens.success,
      DomovoyStatusTone.warning => tokens.warning,
      DomovoyStatusTone.danger => tokens.danger,
    };
    return Semantics(
      label: label,
      child: Container(
        padding: DomovoyDimensions.controlInsets,
        decoration: BoxDecoration(
          color: tokens.surface,
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusPill),
          border: Border.all(color: tokens.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: DomovoyDimensions.iconSmall, color: foreground),
              const SizedBox(width: DomovoyDimensions.space2),
            ],
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
