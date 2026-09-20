import 'package:flutter/material.dart';

import '../../chat/presentation/chat_workspace_page.dart';
import '../../memory/application/memory_inspector_controller.dart';
import '../../profile/application/profile_controller.dart';
import '../../profile/application/profile_interview.dart';
import '../application/project_workspace_controller.dart';

class ProjectWorkspacePage extends StatelessWidget {
  const ProjectWorkspacePage({
    required this.controller,
    this.memory,
    this.profiles,
    this.profileInterviewLlm,
    this.themeMode,
    this.onThemeModeChanged,
    this.providersView,
    super.key,
  });

  final ProjectWorkspaceController controller;
  final MemoryInspectorController? memory;
  final ProfileController? profiles;
  final ProfileInterviewLlm? profileInterviewLlm;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final Widget? providersView;

  @override
  Widget build(BuildContext context) {
    return ChatWorkspacePage(
      controller: controller.chat,
      projects: controller,
      memory: memory,
      profiles: profiles,
      profileInterviewLlm: profileInterviewLlm,
      themeMode: themeMode,
      onThemeModeChanged: onThemeModeChanged,
      providersView: providersView,
    );
  }
}
