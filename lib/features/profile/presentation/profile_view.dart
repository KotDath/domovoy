import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/personalization/personalization.dart';
import '../../../design_system/design_system.dart';
import '../application/profile_controller.dart';
import '../application/profile_interview.dart';
import '../application/profile_state.dart';

class ProfileView extends StatefulWidget {
  const ProfileView({
    required this.controller,
    this.interviewLlm,
    this.lastTrace,
    this.onDirtyChanged,
    super.key,
  });

  final ProfileController controller;
  final ProfileInterviewLlm? interviewLlm;
  final ProfileContextTrace? lastTrace;
  final ValueChanged<bool>? onDirtyChanged;

  @override
  State<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends State<ProfileView> {
  final _name = TextEditingController();
  final _soul = TextEditingController();
  final _user = TextEditingController();
  ProfileId? _selectedId;
  var _document = _ProfileDocument.user;
  var _baselineName = '';
  var _baselineSoul = '';
  var _baselineUser = '';
  var _loadingEditors = false;
  var _reportedDirty = false;

  bool get _isDirty =>
      _name.text != _baselineName ||
      _soul.text != _baselineSoul ||
      _user.text != _baselineUser;

  @override
  void initState() {
    super.initState();
    _name.addListener(_editorChanged);
    _soul.addListener(_editorChanged);
    _user.addListener(_editorChanged);
    widget.controller.addListener(_controllerChanged);
    _controllerChanged();
    unawaited(widget.controller.initialize());
  }

  @override
  void didUpdateWidget(covariant ProfileView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_controllerChanged);
      widget.controller.addListener(_controllerChanged);
      _selectedId = null;
      _controllerChanged();
      unawaited(widget.controller.initialize());
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _name.removeListener(_editorChanged);
    _soul.removeListener(_editorChanged);
    _user.removeListener(_editorChanged);
    _name.dispose();
    _soul.dispose();
    _user.dispose();
    super.dispose();
  }

  void _controllerChanged() {
    if (!mounted) return;
    final state = widget.controller.state;
    AssistantProfile? selected;
    for (final profile in state.profiles) {
      if (profile.id == _selectedId) selected = profile;
    }
    selected ??=
        state.activeProfile ??
        (state.profiles.isEmpty ? null : state.profiles.first);
    if (selected != null && selected.id != _selectedId) {
      _load(selected);
    }
    setState(() {});
  }

  void _load(AssistantProfile profile) {
    _loadingEditors = true;
    _selectedId = profile.id;
    _name.text = profile.name;
    _soul.text = profile.soulMarkdown;
    _user.text = profile.userMarkdown;
    _baselineName = profile.name;
    _baselineSoul = profile.soulMarkdown;
    _baselineUser = profile.userMarkdown;
    _loadingEditors = false;
    _reportDirty(false);
  }

  void _editorChanged() {
    if (_loadingEditors || !mounted) return;
    final dirty = _isDirty;
    _reportDirty(dirty);
    setState(() {});
  }

  void _reportDirty(bool value) {
    if (_reportedDirty == value) return;
    _reportedDirty = value;
    widget.onDirtyChanged?.call(value);
  }

  AssistantProfile? _selected(ProfileState state) {
    for (final profile in state.profiles) {
      if (profile.id == _selectedId) return profile;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    if (state.status == ProfileStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProfileStatus.failed) {
      return _notice(state.error ?? 'Не удалось загрузить профили.');
    }
    final selected = _selected(state);
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 820;
        final list = _profileList(state, selected);
        final editor = _editor(state, selected);
        return Padding(
          padding: DomovoyDimensions.pageInsets,
          child: narrow
              ? Column(
                  children: [
                    SizedBox(height: 190, child: list),
                    const SizedBox(height: DomovoyDimensions.space4),
                    Expanded(child: editor),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 250, child: list),
                    const SizedBox(width: DomovoyDimensions.space5),
                    Expanded(child: editor),
                  ],
                ),
        );
      },
    );
  }

  Widget _profileList(ProfileState state, AssistantProfile? selected) {
    return DomovoySurface(
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
      padding: const EdgeInsets.all(DomovoyDimensions.space3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Профили',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                key: const ValueKey('profile-create'),
                tooltip: 'Создать профиль',
                onPressed: state.busy ? null : _create,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                for (final profile in state.profiles)
                  ListTile(
                    key: ValueKey('profile:${profile.id.value}'),
                    dense: true,
                    selected: profile.id == selected?.id,
                    leading: Icon(
                      profile.id == state.activeProfileId
                          ? Icons.check_circle_rounded
                          : Icons.person_outline_rounded,
                    ),
                    title: Text(profile.name),
                    subtitle: profile.id == state.activeProfileId
                        ? const Text('Активен')
                        : null,
                    onTap: () {
                      if (_isDirty && profile.id != selected?.id) {
                        _showError(
                          'Сохраните или отмените изменения перед переключением профиля.',
                        );
                        return;
                      }
                      setState(() => _load(profile));
                    },
                  ),
              ],
            ),
          ),
          SwitchListTile(
            key: const ValueKey('profile-interview-preference'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Интервью при создании'),
            value: state.offerInterviewOnCreate,
            onChanged: state.busy
                ? null
                : widget.controller.setOfferInterviewOnCreate,
          ),
        ],
      ),
    );
  }

  Widget _editor(ProfileState state, AssistantProfile? profile) {
    if (profile == null) return _notice('Создайте первый профиль.');
    final active = profile.id == state.activeProfileId;
    final trace = widget.lastTrace;
    return DomovoySurface(
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
      padding: DomovoyDimensions.panelInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: DomovoyDimensions.space2,
            runSpacing: DomovoyDimensions.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  key: const ValueKey('profile-name'),
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('profile-save'),
                onPressed: state.busy || !_isDirty
                    ? null
                    : () => _save(profile),
                icon: const Icon(Icons.save_outlined),
                label: const Text('Сохранить'),
              ),
              OutlinedButton(
                onPressed: active || state.busy
                    ? null
                    : () => widget.controller.activate(profile),
                child: Text(active ? 'Активен' : 'Сделать активным'),
              ),
              OutlinedButton(
                onPressed: state.busy ? null : () => _clone(profile),
                child: const Text('Клонировать'),
              ),
              OutlinedButton(
                onPressed: !active && state.profiles.length > 1 && !state.busy
                    ? () => _delete(profile)
                    : null,
                child: const Text('Удалить'),
              ),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: DomovoyDimensions.space3),
            Text(
              state.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: DomovoyDimensions.space4),
          Wrap(
            spacing: DomovoyDimensions.space2,
            runSpacing: DomovoyDimensions.space2,
            children: [
              SegmentedButton<_ProfileDocument>(
                segments: const [
                  ButtonSegment(
                    value: _ProfileDocument.soul,
                    label: Text('SOUL.md'),
                  ),
                  ButtonSegment(
                    value: _ProfileDocument.user,
                    label: Text('USER.md'),
                  ),
                ],
                selected: {_document},
                onSelectionChanged: (value) =>
                    setState(() => _document = value.single),
              ),
              OutlinedButton.icon(
                onPressed: _importDocument,
                icon: const Icon(Icons.file_open_outlined),
                label: const Text('Импорт'),
              ),
              OutlinedButton.icon(
                onPressed: _exportDocument,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Экспорт'),
              ),
              if (_document == _ProfileDocument.user &&
                  widget.interviewLlm != null)
                OutlinedButton.icon(
                  key: const ValueKey('profile-interview'),
                  onPressed: () => _interviewExisting(profile),
                  icon: const Icon(Icons.question_answer_outlined),
                  label: const Text('Заполнить интервью'),
                ),
            ],
          ),
          const SizedBox(height: DomovoyDimensions.space3),
          Expanded(
            child: TextField(
              key: ValueKey('profile-editor:${_document.name}'),
              controller: _document == _ProfileDocument.soul ? _soul : _user,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: InputDecoration(
                alignLabelWithHint: true,
                border: const OutlineInputBorder(),
                labelText: _document == _ProfileDocument.soul
                    ? 'Манера и роль ассистента'
                    : 'Стиль, формат, ограничения и контекст пользователя',
              ),
            ),
          ),
          const SizedBox(height: DomovoyDimensions.space3),
          Text(
            _isDirty
                ? 'Есть несохранённые изменения.'
                : 'Сохранено: ревизия ${profile.revision}.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: _isDirty
                  ? Theme.of(context).colorScheme.tertiary
                  : Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: DomovoyDimensions.space1),
          Text(
            trace == null
                ? 'Сохранённый профиль применится автоматически к следующему запросу.'
                : 'Последний запрос использовал: ${trace.profileName}, ревизия ${trace.profileRevision}, ${trace.renderedCharacters} символов.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _notice(String message) => Center(child: Text(message));

  Future<void> _save(AssistantProfile profile) async {
    final updated = await widget.controller.update(
      profile,
      name: _name.text,
      soulMarkdown: _soul.text,
      userMarkdown: _user.text,
    );
    if (updated != null && mounted) {
      setState(() => _load(updated));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Профиль сохранён. Ревизия ${updated.revision} применится к следующему запросу.',
          ),
        ),
      );
    }
  }

  Future<void> _create() async {
    final intent = await showDialog<_CreateProfileIntent>(
      context: context,
      builder: (context) => _CreateProfileDialog(
        offerInterview:
            widget.controller.state.offerInterviewOnCreate &&
            widget.interviewLlm != null,
        interviewAvailable: widget.interviewLlm != null,
      ),
    );
    if (intent == null || !mounted) return;
    String? draft;
    if (intent.interview && widget.interviewLlm != null) {
      draft = await _runInterview();
      if (draft == null || !mounted) return;
    }
    final created = await widget.controller.create(
      name: intent.name,
      template: intent.template,
      userMarkdown: draft,
    );
    if (created != null && mounted) setState(() => _load(created));
  }

  Future<void> _clone(AssistantProfile profile) async {
    final name = await _askName(
      'Клонировать профиль',
      '${profile.name} — копия',
    );
    if (name == null) return;
    final created = await widget.controller.clone(profile, name: name);
    if (created != null && mounted) setState(() => _load(created));
  }

  Future<void> _delete(AssistantProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить профиль?'),
        content: Text('Профиль «${profile.name}» будет удалён.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) await widget.controller.delete(profile);
  }

  Future<String?> _askName(String title, String initial) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          autofocus: true,
          controller: controller,
          decoration: const InputDecoration(labelText: 'Название'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result == null || result.isEmpty ? null : result;
  }

  Future<void> _interviewExisting(AssistantProfile profile) async {
    final draft = await _runInterview();
    if (draft == null || !mounted) return;
    _user.text = draft;
    setState(() => _document = _ProfileDocument.user);
  }

  Future<String?> _runInterview() async {
    final llm = widget.interviewLlm;
    if (llm == null) return null;
    final controller = ProfileInterviewController(llm: llm);
    try {
      return await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ProfileInterviewDialog(controller: controller),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> _importDocument() async {
    try {
      const markdown = XTypeGroup(
        label: 'Markdown',
        extensions: <String>['md', 'markdown', 'txt'],
      );
      final file = await openFile(acceptedTypeGroups: const [markdown]);
      if (file == null) return;
      final text = await file.readAsString();
      if (_document == _ProfileDocument.soul) {
        normalizeSoulMarkdown(text);
        _soul.text = text;
      } else {
        normalizeUserMarkdown(text);
        _user.text = text;
      }
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (mounted) _showError(_personalizationMessage(error));
    }
  }

  Future<void> _exportDocument() async {
    try {
      final name = _document == _ProfileDocument.soul ? 'SOUL.md' : 'USER.md';
      final location = await getSaveLocation(suggestedName: name);
      if (location == null) return;
      final text = _document == _ProfileDocument.soul ? _soul.text : _user.text;
      final file = XFile.fromData(
        Uint8List.fromList(utf8.encode(text)),
        mimeType: 'text/markdown',
        name: name,
      );
      await file.saveTo(location.path);
    } on Object catch (error) {
      if (mounted) _showError(_personalizationMessage(error));
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

enum _ProfileDocument { soul, user }

final class _CreateProfileIntent {
  const _CreateProfileIntent({
    required this.name,
    required this.template,
    required this.interview,
  });

  final String name;
  final ProfileTemplate template;
  final bool interview;
}

class _CreateProfileDialog extends StatefulWidget {
  const _CreateProfileDialog({
    required this.offerInterview,
    required this.interviewAvailable,
  });

  final bool offerInterview;
  final bool interviewAvailable;

  @override
  State<_CreateProfileDialog> createState() => _CreateProfileDialogState();
}

class _CreateProfileDialogState extends State<_CreateProfileDialog> {
  final _name = TextEditingController();
  var _template = ProfileTemplate.blank;
  late var _interview = widget.offerInterview;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новый профиль'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('new-profile-name'),
            autofocus: true,
            controller: _name,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Название'),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<ProfileTemplate>(
            initialValue: _template,
            decoration: const InputDecoration(labelText: 'Шаблон'),
            items: const [
              DropdownMenuItem(
                value: ProfileTemplate.blank,
                child: Text('Универсальный'),
              ),
              DropdownMenuItem(
                value: ProfileTemplate.learner,
                child: Text('Обучение'),
              ),
              DropdownMenuItem(
                value: ProfileTemplate.expert,
                child: Text('Опытный разработчик'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _template = value);
            },
          ),
          if (widget.interviewAvailable)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Заполнить USER.md через интервью'),
              value: _interview,
              onChanged: (value) => setState(() => _interview = value ?? false),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: _name.text.trim().isEmpty
            ? null
            : () => Navigator.pop(
                context,
                _CreateProfileIntent(
                  name: _name.text.trim(),
                  template: _template,
                  interview: _interview,
                ),
              ),
        child: Text(_interview ? 'Начать интервью' : 'Создать'),
      ),
    ],
  );
}

class _ProfileInterviewDialog extends StatefulWidget {
  const _ProfileInterviewDialog({required this.controller});

  final ProfileInterviewController controller;

  @override
  State<_ProfileInterviewDialog> createState() =>
      _ProfileInterviewDialogState();
}

class _ProfileInterviewDialogState extends State<_ProfileInterviewDialog> {
  final _answer = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(widget.controller.start());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _answer.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return AlertDialog(
      title: Text(
        controller.stage == ProfileInterviewStage.preview
            ? 'Предпросмотр USER.md'
            : 'Интервью · ${controller.topicIndex + 1} из ${ProfileInterviewController.topics.length}',
      ),
      content: SizedBox(
        width: 620,
        child: switch (controller.stage) {
          ProfileInterviewStage.preview => Container(
            constraints: const BoxConstraints(maxHeight: 440),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).dividerColor),
              borderRadius: BorderRadius.circular(4),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                controller.draft ?? '',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
          ProfileInterviewStage.failed => Text(
            controller.error ?? 'Не удалось продолжить интервью.',
          ),
          ProfileInterviewStage.asking ||
          ProfileInterviewStage.generating => const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          ),
          _ => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(controller.question ?? 'Подготовка вопроса…'),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('profile-interview-answer'),
                controller: _answer,
                onChanged: (_) => setState(() {}),
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'Ваш ответ',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (controller.stage == ProfileInterviewStage.awaitingAnswer) ...[
          TextButton(
            onPressed: () async {
              _answer.clear();
              await controller.skip();
            },
            child: const Text('Пропустить'),
          ),
          FilledButton(
            onPressed: _answer.text.trim().isEmpty
                ? null
                : () async {
                    final answer = _answer.text;
                    _answer.clear();
                    await controller.submit(answer);
                  },
            child: const Text('Далее'),
          ),
        ],
        if (controller.stage == ProfileInterviewStage.preview) ...[
          TextButton(onPressed: controller.back, child: const Text('Назад')),
          FilledButton(
            key: const ValueKey('profile-interview-apply'),
            onPressed: () => Navigator.pop(context, controller.draft),
            child: const Text('Применить'),
          ),
        ],
        if (controller.stage == ProfileInterviewStage.failed)
          FilledButton(
            onPressed: controller.start,
            child: const Text('Начать заново'),
          ),
      ],
    );
  }
}

String _personalizationMessage(Object error) {
  if (error is PersonalizationException) return error.error.message;
  return 'Не удалось выполнить операцию с файлом.';
}
