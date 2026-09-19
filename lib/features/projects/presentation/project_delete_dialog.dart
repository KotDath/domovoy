import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/project_workspace_controller.dart';
import '../application/project_workspace_state.dart';

Future<void> showProjectDeleteDialog({
  required BuildContext context,
  required ProjectWorkspaceController controller,
}) async {
  final group = controller.state.selectedGroup;
  if (group?.project == null) {
    return;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DomovoyDimensions.settingsDialogWidth,
        ),
        child: Padding(
          padding: DomovoyDimensions.pageInsets,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Удалить проект «${group!.title}»?',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: DomovoyDimensions.space3),
              const Text(
                'Чаты перейдут в «$unassignedProjectLabel». '
                'Доступ к каталогам будет отозван. Файлы пользователя не удаляются.',
              ),
              const SizedBox(height: DomovoyDimensions.space6),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: DomovoyDimensions.space3,
                children: [
                  TextButton(
                    key: const ValueKey('project-delete-cancel'),
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Отмена'),
                  ),
                  FilledButton(
                    key: const ValueKey('project-delete-confirm'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Удалить проект'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  if (confirmed == true) {
    await controller.deleteSelected();
  }
}
