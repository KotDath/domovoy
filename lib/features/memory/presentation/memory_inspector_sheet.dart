import 'package:flutter/material.dart';

import '../application/memory_inspector_controller.dart';
import 'memory_inspector_panel.dart';

/// Phone presentation: a safe, touch-friendly bottom sheet with system Back
/// support. The sheet closes on Back, drag, or the panel close button.
Future<void> showMemoryInspectorSheet(
  BuildContext context,
  MemoryInspectorController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: media.size.height * 0.88,
            minHeight: media.size.height * 0.4,
          ),
          child: SafeArea(
            top: false,
            child: MemoryInspectorPanel(
              controller: controller,
              onClose: () => Navigator.of(sheetContext).maybePop(),
            ),
          ),
        ),
      );
    },
  );
}
