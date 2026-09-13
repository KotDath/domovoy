import 'package:flutter/widgets.dart';

import 'dimensions.dart';

enum WorkspaceLayoutKind { narrow, desktop }

@immutable
final class WorkspaceLayoutSpec {
  const WorkspaceLayoutSpec({
    required this.kind,
    required this.contentInsets,
    required this.sidebarWidth,
    required this.timelineMaxWidth,
    required this.composerMaxWidth,
    required this.useSheets,
  });

  final WorkspaceLayoutKind kind;
  final EdgeInsets contentInsets;
  final double sidebarWidth;
  final double timelineMaxWidth;
  final double composerMaxWidth;
  final bool useSheets;

  bool get isDesktop => kind == WorkspaceLayoutKind.desktop;
}

WorkspaceLayoutSpec resolveWorkspaceLayout(Size size, double textScale) {
  final safeScale = textScale.isFinite && textScale > 0 ? textScale : 1.0;
  final desktop =
      size.width >= DomovoyDimensions.desktopBreakpoint &&
      safeScale < DomovoyDimensions.highTextScale;
  final compact =
      size.width < DomovoyDimensions.compactWidth ||
      safeScale >= DomovoyDimensions.highTextScale;
  return WorkspaceLayoutSpec(
    kind: desktop ? WorkspaceLayoutKind.desktop : WorkspaceLayoutKind.narrow,
    contentInsets: compact
        ? DomovoyDimensions.compactPageInsets
        : DomovoyDimensions.pageInsets,
    sidebarWidth: desktop ? DomovoyDimensions.sidebarWidth : 0,
    timelineMaxWidth: DomovoyDimensions.timelineMaxWidth,
    composerMaxWidth: DomovoyDimensions.composerMaxWidth,
    useSheets: !desktop,
  );
}
