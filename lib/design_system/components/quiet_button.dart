import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../foundations/dimensions.dart';
import '../foundations/primitive_tokens.dart';
import '../theme/domovoy_theme_extension.dart';
import 'focus_ring.dart';

enum DomovoyButtonTone { quiet, selected, accent, muted }

class DomovoyQuietButton extends StatefulWidget {
  const DomovoyQuietButton({
    required this.onPressed,
    required this.child,
    this.tone = DomovoyButtonTone.quiet,
    this.expand = false,
    this.alignment = Alignment.centerLeft,
    this.padding,
    this.minSize,
    this.tooltip,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final DomovoyButtonTone tone;
  final bool expand;
  final AlignmentGeometry alignment;
  final EdgeInsetsGeometry? padding;
  final Size? minSize;
  final String? tooltip;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<DomovoyQuietButton> createState() => _DomovoyQuietButtonState();
}

class _DomovoyQuietButtonState extends State<DomovoyQuietButton> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final enabled = widget.onPressed != null;
    final background = switch (widget.tone) {
      DomovoyButtonTone.selected => tokens.hover,
      DomovoyButtonTone.accent => tokens.accentMuted,
      DomovoyButtonTone.muted => DomovoyPrimitiveTokens.transparent,
      DomovoyButtonTone.quiet =>
        _hover && enabled ? tokens.hover : DomovoyPrimitiveTokens.transparent,
    };
    final foreground = switch (widget.tone) {
      DomovoyButtonTone.accent => tokens.accent,
      DomovoyButtonTone.muted => tokens.textMuted,
      DomovoyButtonTone.selected => tokens.textPrimary,
      DomovoyButtonTone.quiet => tokens.textPrimary,
    };
    final min =
        widget.minSize ??
        const Size(
          DomovoyDimensions.minimumTarget,
          DomovoyDimensions.minimumTarget,
        );
    final button = Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onKeyEvent: (node, event) {
        if (!enabled) return KeyEventResult.ignored;
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          widget.onPressed!();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: context.domovoyMotion(tokens.fastMotion),
            alignment: widget.expand ? widget.alignment : null,
            width: widget.expand ? double.infinity : null,
            constraints: BoxConstraints(
              minWidth: min.width,
              minHeight: min.height,
            ),
            padding:
                widget.padding ??
                const EdgeInsets.symmetric(
                  horizontal: DomovoyDimensions.space3,
                  vertical: DomovoyDimensions.space2,
                ),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(
                DomovoyDimensions.radiusControl,
              ),
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: foreground),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: Opacity(
                  opacity: enabled ? 1 : 0.45,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final focused = DomovoyFocusRing(
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusControl),
      child: button,
    );
    if (widget.tooltip == null) return focused;
    return Tooltip(message: widget.tooltip!, child: focused);
  }
}
