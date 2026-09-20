import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
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
    this.selectedChatId,
    this.onSelectChat,
    this.onNewChat,
    super.key,
  });

  final ProjectWorkspaceController controller;
  final ProjectWorkspaceState state;
  final AgentSessionId? selectedChatId;
  final ValueChanged<AgentSessionId>? onSelectChat;
  final VoidCallback? onNewChat;

  @override
  Widget build(BuildContext context) {
    final projects = state.groups
        .where(
          (group) =>
              group.kind == ProjectSelectionKind.project &&
              !(group.project?.isDefaultProject ?? false),
        )
        .toList(growable: false);
    final unassigned = state.groups.cast<ProjectChatGroup?>().firstWhere(
      (group) => group?.kind == ProjectSelectionKind.unassigned,
      orElse: () => null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionLabel(
          label: 'Проекты',
          actionKey: 'project-create',
          onAction: !state.canCreateProject || state.busy
              ? null
              : () => unawaited(unawaitedCreate(context)),
          actionLabel: 'Новый проект',
        ),
        if (!state.canCreateProject)
          Semantics(
            label: 'Создание проектов недоступно на этой платформе',
            child: Padding(
              padding: const EdgeInsets.only(bottom: DomovoyDimensions.space2),
              child: Text(
                key: const ValueKey('project-unsupported'),
                'Создание проектов в браузере недоступно. Чаты без проекта остаются доступны.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        for (final group in projects) _projectBlock(context, group),
        _SectionLabel(
          label: 'Чаты',
          actionKey: 'section-new-chat',
          onAction: onNewChat,
          actionLabel: 'Новый чат в текущем проекте',
        ),
        if (unassigned != null) _unassigned(context, unassigned),
        if (state.mutationError != null)
          Padding(
            padding: const EdgeInsets.only(top: DomovoyDimensions.space2),
            child: DomovoyStatusChip(
              key: const ValueKey('project-error'),
              label: state.mutationError!.message,
              tone: DomovoyStatusTone.warning,
            ),
          ),
        if (state.cleanupWarning)
          const Padding(
            padding: EdgeInsets.only(top: DomovoyDimensions.space2),
            child: DomovoyStatusChip(
              key: ValueKey('project-cleanup-warning'),
              label: 'Каталог не был удалён при отмене',
              tone: DomovoyStatusTone.warning,
            ),
          ),
      ],
    );
  }

  Widget _projectBlock(BuildContext context, ProjectChatGroup group) {
    final tokens = context.domovoyTheme;
    final selected = state.selectedProjectId == group.projectId;
    final accessLabel = _accessLabel(group);
    return Padding(
      padding: const EdgeInsets.only(bottom: DomovoyDimensions.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Semantics(
                  selected: selected,
                  button: true,
                  label:
                      '${group.title}${accessLabel == null ? '' : ', $accessLabel'}',
                  child: DomovoyQuietButton(
                    key: ValueKey('project-row:${group.projectId?.value}'),
                    onPressed: () {
                      if (group.projectId != null) {
                        unawaited(controller.selectProject(group.projectId!));
                      }
                    },
                    child: Row(
                      children: [
                        DomovoyIcon(
                          DomovoyIconKind.folder,
                          color: tokens.textSecondary,
                        ),
                        const SizedBox(width: DomovoyDimensions.space3),
                        Expanded(
                          child: Text(
                            group.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (selected &&
                  !group.deleting &&
                  !(group.project?.isDefaultProject ?? false))
                DomovoyQuietButton(
                  key: const ValueKey('project-delete'),
                  minSize: const Size.square(DomovoyDimensions.minimumTarget),
                  alignment: Alignment.center,
                  onPressed: () => unawaited(unawaitedDelete(context)),
                  tooltip: 'Удалить проект',
                  child: Icon(
                    Icons.delete_outline_rounded,
                    size: DomovoyDimensions.iconMedium,
                    color: tokens.danger,
                  ),
                ),
            ],
          ),
          if (accessLabel != null)
            Padding(
              padding: const EdgeInsets.only(left: DomovoyDimensions.space8),
              child: Text(
                accessLabel,
                key: const ValueKey('project-access-status'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (group.unresolvedWarning)
            Padding(
              padding: const EdgeInsets.only(left: DomovoyDimensions.space8),
              child: Text(
                'Есть чаты с неразрешённым проектом',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (selected && state.showRegrant)
            DomovoyQuietButton(
              key: const ValueKey('project-regrant'),
              onPressed: () => unawaited(controller.regrantSelected()),
              child: const Text('Повторить доступ'),
            ),
          for (final chat in group.chats) _chatRow(context, chat, indent: true),
        ],
      ),
    );
  }

  Widget _unassigned(BuildContext context, ProjectChatGroup group) {
    return Column(
      key: const ValueKey('project-unassigned'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          key: const ValueKey('chat-list'),
          height: group.chats.isEmpty ? DomovoyDimensions.zero : null,
          child: Column(
            children: [
              for (final chat in group.chats)
                _chatRow(context, chat, showIcon: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chatRow(
    BuildContext context,
    AgentSessionSummary chat, {
    bool indent = false,
    bool showIcon = false,
  }) {
    final selected = chat.id == selectedChatId;
    final tokens = context.domovoyTheme;
    return Padding(
      padding: EdgeInsets.only(
        left: indent ? DomovoyDimensions.space8 : DomovoyDimensions.zero,
        bottom: DomovoyDimensions.space1,
      ),
      child: Semantics(
        selected: selected,
        button: true,
        label: chat.title ?? 'Новый чат',
        child: DomovoyQuietButton(
          key: ValueKey('chat-row:${chat.id.value}'),
          expand: true,
          tone: selected ? DomovoyButtonTone.selected : DomovoyButtonTone.quiet,
          onPressed: onSelectChat == null ? null : () => onSelectChat!(chat.id),
          padding: indent
              ? DomovoyDimensions.chatRowInsets
              : DomovoyDimensions.controlInsets,
          child: Row(
            children: [
              if (showIcon) ...[
                DomovoyIcon(
                  DomovoyIconKind.chat,
                  color: selected ? tokens.textPrimary : tokens.textMuted,
                ),
                const SizedBox(width: DomovoyDimensions.space3),
              ],
              Expanded(
                child: Text(
                  chat.title ?? 'Новый чат',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: DomovoyDimensions.chatRowSize,
                    color: selected ? tokens.textPrimary : tokens.textSecondary,
                  ),
                ),
              ),
            ],
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
      ProjectAccessStatus.active => null,
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

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    required this.actionKey,
    required this.actionLabel,
    this.onAction,
  });

  final String label;
  final String actionKey;
  final String actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        DomovoyDimensions.space3,
        DomovoyDimensions.space4,
        DomovoyDimensions.space2,
        DomovoyDimensions.space2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: Theme.of(context).textTheme.labelSmall),
          ),
          DomovoyQuietButton(
            key: ValueKey(actionKey),
            minSize: const Size.square(DomovoyDimensions.minimumTarget),
            alignment: Alignment.center,
            onPressed: onAction,
            tooltip: actionLabel,
            child: const Text('＋'),
          ),
        ],
      ),
    );
  }
}
