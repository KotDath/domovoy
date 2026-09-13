import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';

class DomovoyIconAction extends StatelessWidget {
  const DomovoyIconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    child: IconButton(
      constraints: const BoxConstraints.tightFor(
        width: DomovoyDimensions.minimumTarget,
        height: DomovoyDimensions.minimumTarget,
      ),
      iconSize: DomovoyDimensions.iconMedium,
      tooltip: tooltip ?? label,
      focusNode: focusNode,
      onPressed: onPressed,
      icon: Icon(icon),
    ),
  );
}
