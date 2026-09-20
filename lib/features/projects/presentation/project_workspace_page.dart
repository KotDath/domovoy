import 'package:flutter/material.dart';

import '../../chat/presentation/chat_workspace_page.dart';
import '../../memory/application/memory_inspector_controller.dart';
import '../application/project_workspace_controller.dart';

class ProjectWorkspacePage extends StatelessWidget {
  const ProjectWorkspacePage({
    required this.controller,
    this.memory,
    this.themeMode,
    this.onThemeModeChanged,
    this.providersView,
    super.key,
  });

  final ProjectWorkspaceController controller;
  final MemoryInspectorController? memory;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final Widget? providersView;

  @override
  Widget build(BuildContext context) {
    return ChatWorkspacePage(
      controller: controller.chat,
      projects: controller,
      memory: memory,
      themeMode: themeMode,
      onThemeModeChanged: onThemeModeChanged,
      providersView: providersView,
    );
  }
}
