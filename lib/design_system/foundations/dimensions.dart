import 'package:flutter/widgets.dart';

abstract final class DomovoyDimensions {
  static const zero = 0.0;
  static const hairline = 1.0;
  static const focusStroke = 2.0;
  static const focusOffset = 3.0;

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

  static const radiusControl = 7.0;
  static const radiusSmall = 8.0;
  static const radiusMedium = 10.0;
  static const radiusLarge = 12.0;
  static const radiusMessage = 12.0;
  static const radiusComposer = 16.0;
  static const radiusPill = 999.0;

  static const minimumTarget = 32.0;
  static const toolTarget = 32.0;
  static const iconSmall = 16.0;
  static const iconMedium = 19.0;
  static const iconLarge = 24.0;
  static const progressSmall = 15.0;
  static const progressStroke = 2.0;
  static const brandSize = 17.0;
  static const bodySize = 14.0;
  static const bodyHeight = 1.55;
  static const sectionLabelSize = 11.0;
  static const metaSize = 10.0;
  static const chatRowSize = 13.0;

  static const sidebarWidth = 270.0;
  static const headerHeight = 56.0;
  static const narrowHeaderHeight = 61.0;
  static const timelineMaxWidth = 700.0;
  static const composerMaxWidth = 764.0;
  static const composerMinHeight = 88.0;
  static const settingsDialogWidth = 520.0;
  static const messageMaxWidth = 560.0;
  static const composerFieldMinHeight = 44.0;
  static const timelineScrollThreshold = 80.0;
  static const desktopBreakpoint = 760.0;
  static const highTextScale = 1.6;
  static const compactWidth = 760.0;
  static const contextPopoverWidth = 320.0;
  static const modelsPopoverWidth = 440.0;
  static const reasoningPopoverWidth = 260.0;
  static const folderPopoverWidth = 280.0;
  static const providerMenuWidth = 190.0;

  static const elevationLow = 1.0;
  static const elevationFloating = 12.0;
  static const popoverBlur = 25.0;

  static const pageInsets = EdgeInsets.all(space7);
  static const compactPageInsets = EdgeInsets.all(space5);
  static const controlInsets = EdgeInsets.symmetric(
    horizontal: space4,
    vertical: space3,
  );
  static const panelInsets = EdgeInsets.all(space5);
  static const composerInsets = EdgeInsets.fromLTRB(
    space4,
    space4,
    space4,
    space3,
  );
  static const listInsets = EdgeInsets.symmetric(
    horizontal: space3,
    vertical: space2,
  );
  static const sidebarInsets = EdgeInsets.fromLTRB(space3, 17, space3, space4);
  static const chatRowInsets = EdgeInsets.fromLTRB(31, 6, space4, 6);
}
