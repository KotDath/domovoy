import 'package:flutter/material.dart';
import '../../../core/projects/ids.dart';
import '../../../core/support/support.dart';
import '../../chat/application/chat_timeline_projector.dart';
import '../../chat/presentation/chat_composer.dart';
import '../../chat/presentation/chat_timeline.dart';
import '../application/support_controller.dart';

class SupportPage extends StatefulWidget {
  const SupportPage({required this.controller, this.projectId, super.key});
  final SupportController controller;
  final ProjectId? projectId;
  @override
  State<SupportPage> createState() => _SupportPageState();
}

class _SupportPageState extends State<SupportPage> {
  SupportController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.initialize();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Поддержка'),
        actions: [
          IconButton(
            tooltip: 'Обновить обращения',
            onPressed: c.locked ? null : c.initialize,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Консультации по Domovoy. Данные сохраняются на этом устройстве. Не отправляйте ключи и личные файлы.',
                  ),
                ),
                if (c.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(c.error!, key: const ValueKey('support-error')),
                  ),
                if (c.busy) const LinearProgressIndicator(),
                Expanded(
                  child: c.tickets.isEmpty
                      ? const Center(child: Text('Обращений пока нет'))
                      : ListView.builder(
                          itemCount: c.tickets.length,
                          itemBuilder: (context, index) {
                            final ticket = c.tickets[index];
                            return ListTile(
                              title: Text(ticket.subject),
                              subtitle: Text(
                                ticket.ready
                                    ? ticket.status.label
                                    : 'Создание не завершено',
                              ),
                              trailing: ticket.ready
                                  ? const Icon(Icons.chevron_right)
                                  : TextButton(
                                      onPressed: c.locked
                                          ? null
                                          : () => c.recover(ticket),
                                      child: const Text('Повторить создание'),
                                    ),
                              onTap: !ticket.ready || c.locked
                                  ? null
                                  : () async {
                                      await c.select(ticket);
                                      if (context.mounted &&
                                          c.selected?.id == ticket.id &&
                                          c.error == null) {
                                        await Navigator.of(context).push<void>(
                                          MaterialPageRoute(
                                            builder: (_) => SupportTicketPage(
                                              controller: c,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: c.locked ? null : () => _create(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Новое обращение'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> _create(BuildContext context) async {
    final snapshot = c.captureSnapshot(c.initialSelection().model);
    final draft = await showDialog<_SupportDraft>(
      context: context,
      builder: (_) => _SupportCreateDialog(
        snapshot: snapshot,
        hasProject: widget.projectId != null,
      ),
    );
    if (draft == null) return;
    await c.create(
      draft.subject,
      draft.description,
      snapshot,
      projectId: draft.project ? widget.projectId : null,
    );
    if (context.mounted && c.selected != null && c.error == null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => SupportTicketPage(controller: c)),
      );
    }
  }
}

typedef _SupportDraft = ({String subject, String description, bool project});

class _SupportCreateDialog extends StatefulWidget {
  const _SupportCreateDialog({
    required this.snapshot,
    required this.hasProject,
  });
  final SupportSnapshot snapshot;
  final bool hasProject;
  @override
  State<_SupportCreateDialog> createState() => _SupportCreateDialogState();
}

class _SupportCreateDialogState extends State<_SupportCreateDialog> {
  final subject = TextEditingController();
  final description = TextEditingController();
  final valid = GlobalKey<FormState>();
  bool linkProject = false;
  @override
  void dispose() {
    subject.dispose();
    description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новое обращение'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Form(
          key: valid,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: subject,
                decoration: const InputDecoration(labelText: 'Тема'),
                maxLength: 160,
                validator: (s) =>
                    s == null || s.trim().isEmpty ? 'Укажите тему' : null,
              ),
              TextFormField(
                controller: description,
                decoration: const InputDecoration(
                  labelText: 'Описание проблемы',
                ),
                maxLines: 4,
                maxLength: 6000,
                validator: (s) =>
                    s == null || s.trim().isEmpty ? 'Опишите проблему' : null,
              ),
              if (widget.hasProject)
                CheckboxListTile(
                  value: linkProject,
                  title: const Text('Связать с текущим проектом'),
                  subtitle: const Text('Без передачи файлов проекта'),
                  onChanged: (v) => setState(() => linkProject = v ?? false),
                ),
              SupportSnapshotCard(snapshot: widget.snapshot),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (valid.currentState!.validate()) {
            Navigator.pop(context, (
              subject: subject.text,
              description: description.text,
              project: linkProject,
            ));
          }
        },
        child: const Text('Создать'),
      ),
    ],
  );
}

class SupportTicketPage extends StatelessWidget {
  const SupportTicketPage({required this.controller, super.key});
  final SupportController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final c = controller;
      final ticket = c.selected;
      final state = c.chat.state;
      final session = state.selectedSession;
      if (ticket == null || session == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Обращение недоступно')),
        );
      }
      return PopScope(
        canPop: !c.locked,
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              ticket.subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: SafeArea(
            child: Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    // Measure only the space left above the composer after
                    // Scaffold applies keyboard insets. Metadata can scroll
                    // while the timeline keeps part of that remaining space.
                    builder: (context, constraints) => Column(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight * .85,
                          ),
                          child: SingleChildScrollView(
                            key: const ValueKey('support-details-scroll'),
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(ticket.status.label),
                                      ),
                                      PopupMenuButton<SupportStatus>(
                                        tooltip: 'Изменить статус',
                                        enabled: !c.locked,
                                        onSelected: (status) =>
                                            _status(context, status),
                                        itemBuilder: (_) => SupportStatus.values
                                            .map(
                                              (s) => PopupMenuItem(
                                                value: s,
                                                child: Text(s.label),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    ],
                                  ),
                                ),
                                ExpansionTile(
                                  title: const Text(
                                    'Описание и технический снимок',
                                  ),
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: SelectableText(ticket.description),
                                    ),
                                    SupportSnapshotCard(
                                      snapshot: ticket.snapshot,
                                    ),
                                    TextButton(
                                      onPressed: c.locked
                                          ? null
                                          : c.refreshSnapshot,
                                      child: const Text('Обновить снимок'),
                                    ),
                                  ],
                                ),
                                ExpansionTile(
                                  key: const ValueKey('support-sources'),
                                  title: const Text('Источники руководства'),
                                  subtitle: const Text(
                                    'Извлечённые фрагменты; проверяйте выводы ассистента',
                                  ),
                                  children: [
                                    if (c.sources.isEmpty)
                                      const ListTile(
                                        title: Text(
                                          'Источники появятся после подготовки вопроса',
                                        ),
                                      ),
                                    for (final trace in c.sources.reversed)
                                      ExpansionTile(
                                        title: Text(
                                          trace['query'] as String? ?? 'Вопрос',
                                        ),
                                        subtitle: Text(
                                          '${trace['protocol']} · ${trace['fingerprint']}',
                                        ),
                                        children: [
                                          for (final candidate
                                              in (trace['candidates']
                                                      as List? ??
                                                  []))
                                            if ((candidate as Map)['sent'] ==
                                                true)
                                              Padding(
                                                padding: const EdgeInsets.all(
                                                  12,
                                                ),
                                                child: SelectableText(
                                                  '${candidate['chunk']['source']}\n${candidate['chunk']['section']}\nРевизия: ${candidate['chunk']['revision']}\nФрагмент: ${candidate['chunk']['id']} · UTF-16 ${candidate['chunk']['start']}–${candidate['chunk']['end']}\n${candidate['retrieval_kind'] == 'support_document_neighbor' ? 'Соседний фрагмент · основание: ${candidate['seed_chunk_id']} · поколение: ${candidate['generation']}' : 'Dense · ранг: ${candidate['dense_rank']} · cosine: ${candidate['cosine']}'}\n${candidate['chunk']['text']}',
                                                ),
                                              ),
                                        ],
                                      ),
                                  ],
                                ),
                                if (c.error != null) Text(c.error!),
                                if (c.preparer.busy)
                                  LinearProgressIndicator(
                                    semanticsLabel: c.preparer.progress,
                                  ),
                                if (c.preparer.busy || c.preparer.error != null)
                                  Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(
                                      c.preparer.error ?? c.preparer.progress,
                                    ),
                                  ),
                                if (ticket.status == SupportStatus.resolved)
                                  const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Text(
                                      'Для продолжения выберите статус «Открыто».',
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: ChatTimeline(
                            projection: const ChatTimelineProjector().project(
                              snapshot: session,
                              liveRun: state.liveRun,
                              workspaceError: state.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ChatComposer(
                    wrapControls: true,
                    providerGroups: state.providerGroups,
                    selection: session.selection,
                    onSend: c.send,
                    onStop: c.stop,
                    onSelectionChanged: c.chat.changeSelection,
                    running: state.isBusy,
                    enabled: !c.busy && ticket.status != SupportStatus.resolved,
                    providerCatalog: state.providerCatalog,
                    onRefreshModels: c.chat.refreshProviderModels,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  Future<void> _status(BuildContext context, SupportStatus status) async {
    if (status == controller.selected?.status) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          status == SupportStatus.open &&
                  controller.selected?.status == SupportStatus.resolved
              ? 'Повторно открыть обращение?'
              : 'Изменить статус?',
        ),
        content: Text('Новый статус: ${status.label}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.setStatus(status);
  }
}

class SupportSnapshotCard extends StatelessWidget {
  const SupportSnapshotCard({required this.snapshot, super.key});
  final SupportSnapshot snapshot;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SelectableText(
          'Технический снимок\nНаблюдение: ${DateTime.fromMicrosecondsSinceEpoch(snapshot.observedAt).toLocal()}\nПлатформа: ${snapshot.platform}\nВерсия: ${snapshot.version}\nПровайдер: ${snapshot.provider}\nМодель: ${snapshot.model}\nMCP: ${snapshot.mcp}\nRAG: ${snapshot.rag}\nДанные могут устареть. Ключи, адреса серверов и личные файлы не включены.',
        ),
      ),
    ),
  );
}
