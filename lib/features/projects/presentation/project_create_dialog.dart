import 'package:flutter/material.dart';

import '../../../core/projects/enums.dart';
import '../../../design_system/design_system.dart';
import '../application/project_workspace_controller.dart';
import '../application/project_workspace_state.dart';

Future<void> showProjectCreateDialog({
  required BuildContext context,
  required ProjectWorkspaceController controller,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DomovoyDimensions.settingsDialogWidth,
        ),
        child: _ProjectCreateForm(controller: controller),
      ),
    ),
  );
}

class _ProjectCreateForm extends StatefulWidget {
  const _ProjectCreateForm({required this.controller});

  final ProjectWorkspaceController controller;

  @override
  State<_ProjectCreateForm> createState() => _ProjectCreateFormState();
}

class _ProjectCreateFormState extends State<_ProjectCreateForm> {
  final _name = TextEditingController();
  var _mode = ProjectDesktopRootMode.attachExisting;
  var _additional = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = widget.controller.capabilities;
    final tokens = context.domovoyTheme;
    return Semantics(
      namesRoute: true,
      label: 'Создание проекта',
      child: Padding(
        padding: DomovoyDimensions.pageInsets,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Новый проект',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                DomovoyQuietButton(
                  minSize: const Size.square(DomovoyDimensions.minimumTarget),
                  alignment: Alignment.center,
                  onPressed: () => Navigator.pop(context),
                  child: const Text('×'),
                ),
              ],
            ),
            const SizedBox(height: DomovoyDimensions.space3),
            Text(
              'Одна корневая папка, несколько чатов и общий контекст.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
            ),
            const SizedBox(height: DomovoyDimensions.space5),
            TextField(
              key: const ValueKey('project-create-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Название проекта'),
            ),
            if (capabilities.desktopExternalRoots) ...[
              const SizedBox(height: DomovoyDimensions.space5),
              Text(
                'Корневая папка',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              const SizedBox(height: DomovoyDimensions.space2),
              DomovoyQuietButton(
                key: const ValueKey('project-root-attach'),
                expand: true,
                tone: _mode == ProjectDesktopRootMode.attachExisting
                    ? DomovoyButtonTone.selected
                    : DomovoyButtonTone.quiet,
                onPressed: () => setState(
                  () => _mode = ProjectDesktopRootMode.attachExisting,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Прикрепить существующую папку'),
                    Text('Чтение и запись корневого каталога'),
                  ],
                ),
              ),
              DomovoyQuietButton(
                key: const ValueKey('project-root-create'),
                expand: true,
                tone: _mode == ProjectDesktopRootMode.createExclusive
                    ? DomovoyButtonTone.selected
                    : DomovoyButtonTone.quiet,
                onPressed: () => setState(
                  () => _mode = ProjectDesktopRootMode.createExclusive,
                ),
                child: const Text('Создать новую папку проекта'),
              ),
              const SizedBox(height: DomovoyDimensions.space3),
              DomovoyQuietButton(
                key: const ValueKey('project-add-additional'),
                expand: true,
                onPressed: () => setState(() => _additional = !_additional),
                child: Text(
                  _additional
                      ? 'Дополнительные каталоги: да, только чтение'
                      : '＋ Добавить дополнительные папки',
                ),
              ),
            ],
            if (capabilities.mobileSandboxRoots)
              const Padding(
                padding: EdgeInsets.only(top: DomovoyDimensions.space3),
                child: Text(
                  key: ValueKey('project-sandbox-copy'),
                  'Корневой каталог будет создан внутри песочницы приложения. '
                  'Внешние папки в этой версии недоступны.',
                ),
              ),
            const SizedBox(height: DomovoyDimensions.space6),
            Row(
              children: [
                DomovoyQuietButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Отмена'),
                ),
                const Spacer(),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: DomovoyDimensions.minimumTarget,
                  ),
                  child: DomovoyQuietButton(
                    key: const ValueKey('project-create-confirm'),
                    tone: DomovoyButtonTone.accent,
                    onPressed: _submit,
                    child: const Text('Создать'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _name.text;
    Navigator.pop(context);
    await widget.controller.createProject(
      ProjectCreateDraft(
        name: name,
        mode: widget.controller.capabilities.desktopExternalRoots
            ? _mode
            : null,
        additionalCount: _additional ? 1 : 0,
      ),
    );
  }
}
