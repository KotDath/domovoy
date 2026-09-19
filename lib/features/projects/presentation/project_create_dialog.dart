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
    return Semantics(
      namesRoute: true,
      label: 'Создание проекта',
      child: Padding(
        padding: DomovoyDimensions.pageInsets,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Новый проект', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: DomovoyDimensions.space4),
            TextField(
              key: const ValueKey('project-create-name'),
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Название'),
            ),
            if (capabilities.desktopExternalRoots) ...[
              const SizedBox(height: DomovoyDimensions.space3),
              ListTile(
                key: const ValueKey('project-root-attach'),
                selected: _mode == ProjectDesktopRootMode.attachExisting,
                title: const Text('Прикрепить существующую папку'),
                subtitle: const Text('Чтение и запись корневого каталога'),
                onTap: () => setState(
                  () => _mode = ProjectDesktopRootMode.attachExisting,
                ),
              ),
              ListTile(
                key: const ValueKey('project-root-create'),
                selected: _mode == ProjectDesktopRootMode.createExclusive,
                title: const Text('Создать новую папку проекта'),
                onTap: () => setState(
                  () => _mode = ProjectDesktopRootMode.createExclusive,
                ),
              ),
              CheckboxListTile(
                key: const ValueKey('project-add-additional'),
                value: _additional,
                onChanged: (value) =>
                    setState(() => _additional = value ?? false),
                title: const Text('Дополнительные каталоги только для чтения'),
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
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: DomovoyDimensions.minimumTarget,
                ),
                child: FilledButton(
                  key: const ValueKey('project-create-confirm'),
                  onPressed: _submit,
                  child: const Text('Создать'),
                ),
              ),
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
