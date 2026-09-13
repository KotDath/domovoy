import 'package:flutter/widgets.dart';

abstract final class DomovoyDimensions {
  static const zero = 0.0;
  static const hairline = 1.0;
  static const focusStroke = 2.0;

  static const space1 = 2.0;
  static const space2 = 4.0;
  static const space3 = 8.0;
  static const space4 = 12.0;
  static const space5 = 16.0;
  static const space6 = 20.0;
  static const space7 = 24.0;
  static const space8 = 32.0;
  static const space9 = 40.0;
  static const space10 = 48.0;

  static const radiusSmall = 8.0;
  static const radiusMedium = 12.0;
  static const radiusLarge = 16.0;
  static const radiusMessage = 18.0;
  static const radiusComposer = 25.0;
  static const radiusPill = 999.0;

  static const minimumTarget = 44.0;
  static const iconSmall = 18.0;
  static const iconMedium = 20.0;
  static const iconLarge = 24.0;
  static const progressSmall = 18.0;
  static const progressStroke = 2.0;

  static const sidebarWidth = 276.0;
  static const headerHeight = 56.0;
  static const timelineMaxWidth = 720.0;
  static const composerMaxWidth = 760.0;
  static const composerMinHeight = 132.0;
  static const settingsDialogWidth = 520.0;
  static const messageMaxWidth = 620.0;
  static const composerFieldMinHeight = 48.0;
  static const timelineScrollThreshold = 80.0;
  static const desktopBreakpoint = 960.0;
  static const highTextScale = 1.6;
  static const compactWidth = 600.0;

  static const elevationLow = 1.0;
  static const elevationFloating = 12.0;

  static const pageInsets = EdgeInsets.all(space7);
  static const compactPageInsets = EdgeInsets.all(space5);
  static const controlInsets = EdgeInsets.symmetric(
    horizontal: space4,
    vertical: space3,
  );
  static const panelInsets = EdgeInsets.all(space5);
  static const composerInsets = EdgeInsets.all(space6);
  static const listInsets = EdgeInsets.symmetric(
    horizontal: space4,
    vertical: space2,
  );
}
