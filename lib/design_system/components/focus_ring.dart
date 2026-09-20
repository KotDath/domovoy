import 'package:flutter/material.dart';

import '../foundations/dimensions.dart';
import '../foundations/primitive_tokens.dart';
import '../theme/domovoy_theme_extension.dart';

class DomovoyFocusRing extends StatefulWidget {
  const DomovoyFocusRing({
    required this.child,
    this.borderRadius = const BorderRadius.all(
      Radius.circular(DomovoyDimensions.radiusMedium),
    ),
    super.key,
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  State<DomovoyFocusRing> createState() => _DomovoyFocusRingState();
}

class _DomovoyFocusRingState extends State<DomovoyFocusRing> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Focus(
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: AnimatedContainer(
        duration: context.domovoyMotion(tokens.fastMotion),
        decoration: BoxDecoration(
          borderRadius: widget.borderRadius,
          border:
              _focused &&
                  FocusManager.instance.highlightMode ==
                      FocusHighlightMode.traditional
              ? Border.all(color: tokens.accent, width: tokens.focusStrokeWidth)
              : Border.all(
                  color: DomovoyPrimitiveTokens.transparent,
                  width: tokens.focusStrokeWidth,
                ),
        ),
        child: widget.child,
      ),
    );
  }
}
