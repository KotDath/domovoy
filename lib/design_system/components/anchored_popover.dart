import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../foundations/dimensions.dart';
import '../foundations/primitive_tokens.dart';
import 'app_surface.dart';

Future<T?> showDomovoyAnchoredPopover<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  required double width,
  Alignment targetAnchor = Alignment.topRight,
  Alignment followerAnchor = Alignment.bottomRight,
}) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Future<T?>.value();
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
  final trigger = box.size;
  return showGeneralDialog<T>(
    context: context,
    barrierLabel: 'Dismiss',
    barrierDismissible: true,
    barrierColor: DomovoyPrimitiveTokens.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (dialogContext, animation, secondary) {
      final media = MediaQuery.sizeOf(dialogContext);
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(dialogContext),
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.maybePop(dialogContext),
              ),
            ),
            CustomSingleChildLayout(
              delegate: _AnchorLayoutDelegate(
                origin: origin,
                trigger: trigger,
                overlay: media,
                width: width,
                alignStart:
                    targetAnchor == Alignment.topLeft ||
                    targetAnchor == Alignment.bottomLeft,
              ),
              child: builder(dialogContext),
            ),
          ],
        ),
      );
    },
  );
}

class _AnchorLayoutDelegate extends SingleChildLayoutDelegate {
  _AnchorLayoutDelegate({
    required this.origin,
    required this.trigger,
    required this.overlay,
    required this.width,
    required this.alignStart,
  });

  final Offset origin;
  final Size trigger;
  final Size overlay;
  final double width;
  final bool alignStart;

  static const _gap = DomovoyDimensions.space3;
  static const _margin = DomovoyDimensions.space4;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final spaceAbove = origin.dy - _margin;
    final spaceBelow = overlay.height - origin.dy - trigger.height - _margin;
    var maxHeight = math.max(spaceAbove, spaceBelow) - _gap;
    if (maxHeight < 200) {
      maxHeight = overlay.height * 0.6;
    }
    final maxWidth = math.min(width, overlay.width - _margin * 2);
    return BoxConstraints(
      minWidth: maxWidth,
      maxWidth: maxWidth,
      maxHeight: maxHeight,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final spaceAbove = origin.dy;
    final spaceBelow = overlay.height - origin.dy - trigger.height;
    final showAbove = spaceAbove > spaceBelow && spaceAbove > childSize.height;
    var left = alignStart
        ? origin.dx
        : origin.dx + trigger.width - childSize.width;
    final maxLeft = overlay.width - childSize.width - _margin;
    left = maxLeft < _margin ? _margin : left.clamp(_margin, maxLeft);
    var top = showAbove
        ? origin.dy - childSize.height - _gap
        : origin.dy + trigger.height + _gap;
    final maxTop = overlay.height - childSize.height - _margin;
    if (maxTop < _margin || top < _margin || top > maxTop) {
      top = math.max(_margin, (overlay.height - childSize.height) / 2);
    } else {
      top = top.clamp(_margin, maxTop);
    }
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _AnchorLayoutDelegate oldDelegate) =>
      origin != oldDelegate.origin ||
      trigger != oldDelegate.trigger ||
      overlay != oldDelegate.overlay ||
      width != oldDelegate.width ||
      alignStart != oldDelegate.alignStart;
}

class DomovoyPopoverCard extends StatelessWidget {
  const DomovoyPopoverCard({required this.child, this.padding, super.key});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DomovoyPrimitiveTokens.transparent,
      child: DomovoySurface(
        role: DomovoySurfaceRole.elevated,
        border: true,
        shadow: true,
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
        padding: padding ?? DomovoyDimensions.controlInsets,
        child: child,
      ),
    );
  }
}
