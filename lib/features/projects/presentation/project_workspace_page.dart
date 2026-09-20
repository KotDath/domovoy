import 'package:flutter/material.dart';

import '../../chat/presentation/chat_workspace_page.dart';
import '../application/project_workspace_controller.dart';

class ProjectWorkspacePage extends StatelessWidget {
  const ProjectWorkspacePage({
    required this.controller,
    this.themeMode,
    this.onThemeModeChanged,
    this.providersView,
    super.key,
  });

  final ProjectWorkspaceController controller;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final Widget? providersView;

  @override
  Widget build(BuildContext context) {
    return ChatWorkspacePage(
      controller: controller.chat,
      projects: controller,
      themeMode: themeMode,
      onThemeModeChanged: onThemeModeChanged,
      providersView: providersView,
    );
  }
}
