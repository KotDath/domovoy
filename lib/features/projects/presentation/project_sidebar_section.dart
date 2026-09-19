import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/projects/enums.dart';
import '../../../design_system/design_system.dart';
import '../application/project_workspace_controller.dart';
import '../application/project_workspace_state.dart';
import 'project_create_dialog.dart';
import 'project_delete_dialog.dart';

class ProjectSidebarSection extends StatelessWidget {
  const ProjectSidebarSection({
    required this.controller,
    required this.state,
    super.key,
  });

  final ProjectWorkspaceController controller;
  final ProjectWorkspaceState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: DomovoyDimensions.listInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('ПРОЕКТЫ', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: DomovoyDimensions.space2),
          if (!state.canCreateProject)
            Semantics(
              label: 'Создание проектов недоступно на этой платформе',
              child: Padding(
                padding: const EdgeInsets.only(
                  bottom: DomovoyDimensions.space2,
                ),
                child: Text(
                  key: const ValueKey('project-unsupported'),
                  'Создание проектов в браузере недоступно. Чаты без проекта остаются доступны.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: DomovoyDimensions.minimumTarget,
              ),
              child: OutlinedButton.icon(
                key: const ValueKey('project-create'),
                onPressed: state.busy
                    ? null
                    : () => unawaited(unawaitedCreate(context)),
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Новый проект'),
                ),
              ),
            ),
          const SizedBox(height: DomovoyDimensions.space2),
          for (final group in state.groups) _groupTile(context, group),
          if (state.mutationError != null)
            Padding(
              padding: const EdgeInsets.only(top: DomovoyDimensions.space2),
              child: DomovoyStatusChip(
                key: const ValueKey('project-error'),
                label: state.mutationError!.message,
                tone: DomovoyStatusTone.warning,
                icon: Icons.warning_amber_rounded,
              ),
            ),
          if (state.cleanupWarning)
            const Padding(
              padding: EdgeInsets.only(top: DomovoyDimensions.space2),
              child: DomovoyStatusChip(
                key: ValueKey('project-cleanup-warning'),
                label: 'Каталог не был удалён при отмене',
                tone: DomovoyStatusTone.warning,
                icon: Icons.folder_off_outlined,
              ),
            ),
        ],
      ),
    );
  }

  Widget _groupTile(BuildContext context, ProjectChatGroup group) {
    final selected = group.kind == ProjectSelectionKind.unassigned
        ? state.selectedKind == ProjectSelectionKind.unassigned
        : state.selectedProjectId == group.projectId;
    final accessLabel = _accessLabel(group);
    return Padding(
      padding: const EdgeInsets.only(bottom: DomovoyDimensions.space2),
      child: Semantics(
        selected: selected,
        button: true,
        label: '${group.title}${accessLabel == null ? '' : ', $accessLabel'}',
        child: Material(
          color: selected
              ? context.domovoyTheme.selectedSurface
              : context.domovoyTheme.sidebar,
          borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
          child: InkWell(
            key: ValueKey(
              group.kind == ProjectSelectionKind.unassigned
                  ? 'project-unassigned'
                  : 'project-row:${group.projectId?.value}',
            ),
            onTap: () {
              if (group.kind == ProjectSelectionKind.unassigned) {
                controller.selectUnassigned();
              } else if (group.projectId != null) {
                controller.selectProject(group.projectId!);
              }
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: DomovoyDimensions.minimumTarget,
              ),
              child: Padding(
                padding: DomovoyDimensions.controlInsets,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (accessLabel != null)
                      Text(
                        accessLabel,
                        key: const ValueKey('project-access-status'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (group.unresolvedWarning)
                      Text(
                        'Есть чаты с неразрешённым проектом',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (selected &&
                        group.kind == ProjectSelectionKind.project &&
                        !group.deleting)
                      Wrap(
                        spacing: DomovoyDimensions.space2,
                        children: [
                          if (state.showRegrant)
                            TextButton(
                              key: const ValueKey('project-regrant'),
                              onPressed: () =>
                                  unawaited(controller.regrantSelected()),
                              child: const Text('Повторить доступ'),
                            ),
                          TextButton(
                            key: const ValueKey('project-delete'),
                            onPressed: () =>
                                unawaited(unawaitedDelete(context)),
                            child: const Text('Удалить проект'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _accessLabel(ProjectChatGroup group) {
    if (group.deleting) {
      return 'Удаление…';
    }
    return switch (group.access) {
      ProjectAccessStatus.active => 'Доступ активен',
      ProjectAccessStatus.requiresRegrant => 'Нужно повторить доступ',
      ProjectAccessStatus.revoked => 'Доступ отозван',
      ProjectAccessStatus.missing => 'Каталог недоступен',
      ProjectAccessStatus.unsupported => 'Не поддерживается',
      ProjectAccessStatus.corrupt => 'Данные проекта повреждены',
      ProjectAccessStatus.unverifiable => 'Доступ не подтверждён',
      null => null,
    };
  }

  Future<void> unawaitedCreate(BuildContext context) {
    return showProjectCreateDialog(context: context, controller: controller);
  }

  Future<void> unawaitedDelete(BuildContext context) {
    return showProjectDeleteDialog(context: context, controller: controller);
  }
}
