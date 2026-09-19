import 'package:flutter/material.dart';

import '../../chat/presentation/chat_workspace_page.dart';
import '../application/project_workspace_controller.dart';

class ProjectWorkspacePage extends StatelessWidget {
  const ProjectWorkspacePage({required this.controller, super.key});

  final ProjectWorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    return ChatWorkspacePage(controller: controller.chat, projects: controller);
  }
}
