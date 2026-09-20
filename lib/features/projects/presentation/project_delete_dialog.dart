import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/project_workspace_controller.dart';

Future<void> showProjectDeleteDialog({
  required BuildContext context,
  required ProjectWorkspaceController controller,
}) async {
  final group = controller.state.selectedGroup;
  if (group?.project == null) {
    return;
  }
  final media = MediaQuery.of(context);
  final layout = resolveWorkspaceLayout(media.size, media.textScaler.scale(1));
  final confirmation = _ProjectDeleteConfirmation(title: group!.title);
  final Future<bool?> pending;
  if (layout.isDesktop) {
    pending = showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DomovoyDimensions.settingsDialogWidth,
          ),
          child: confirmation,
        ),
      ),
    );
  } else {
    pending = showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => confirmation,
    );
  }
  final confirmed = await pending;
  if (confirmed == true) {
    await controller.deleteSelected();
  }
}

class _ProjectDeleteConfirmation extends StatelessWidget {
  const _ProjectDeleteConfirmation({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Semantics(
      namesRoute: true,
      label: 'Подтверждение удаления проекта $title',
      child: DomovoySurface(
        key: const ValueKey('project-delete-dialog'),
        role: DomovoySurfaceRole.elevated,
        padding: DomovoyDimensions.pageInsets,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Удалить проект «$title»?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: DomovoyDimensions.space3),
            const Text(
              'Проект будет удалён из Domovoy, а его чаты перейдут в общий '
              'раздел «Чаты». Созданные и прикреплённые файлы, а также сам '
              'каталог проекта удалены не будут. Доступ Domovoy к каталогу '
              'будет отозван.',
            ),
            const SizedBox(height: DomovoyDimensions.space6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: DomovoyDimensions.space3,
              runSpacing: DomovoyDimensions.space2,
              children: [
                TextButton(
                  key: const ValueKey('project-delete-cancel'),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton.icon(
                  key: const ValueKey('project-delete-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.danger,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Удалить проект'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
