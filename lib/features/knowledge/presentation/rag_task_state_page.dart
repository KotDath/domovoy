import 'package:flutter/material.dart';

import '../../../core/rag/task_state.dart';
import '../application/rag_chat_controller.dart';

class RagTaskStatePage extends StatefulWidget {
  const RagTaskStatePage({required this.controller, super.key});
  final RagChatController controller;
  @override
  State<RagTaskStatePage> createState() => _RagTaskStatePageState();
}

class _RagTaskStatePageState extends State<RagTaskStatePage> {
  final _id = TextEditingController(text: 'goal.main');
  final _value = TextEditingController();
  RagTaskFactKind _kind = RagTaskFactKind.goal;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _id.dispose();
    _value.dispose();
    super.dispose();
  }

  Future<void> _save({bool retire = false}) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.controller.editTaskFact(
        _id.text.trim(),
        _kind,
        _value.text,
        retire: retire,
      );
      if (mounted) setState(_value.clear);
    } on RagTaskStateConflict {
      if (mounted) {
        setState(
          () => _error = 'Состояние уже изменилось. Откройте его заново.',
        );
      }
    } on Object {
      if (mounted) {
        setState(
          () => _error =
              'Не удалось сохранить: проверьте поле, тип и непустое значение.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Память текущей задачи')),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller, state = widget.controller.taskState;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SwitchListTile(
              title: const Text('Учитывать память задачи'),
              subtitle: const Text(
                'В режиме по документам новые условия из ваших сообщений применяются автоматически после проверки цитаты. Выключение не удаляет сохранённые условия.',
              ),
              value: c.taskStateEnabled,
              onChanged: c.busy
                  ? null
                  : (v) => c.configure(taskStateEnabled: v),
            ),
            const Text(
              'Чтобы автоматически заменить цель, начните сообщение «Новая цель: …» или «Our new goal is …». Цель также можно изменить вручную ниже. Это условия этой беседы, а не общая или подтверждённая долговременная память Domovoy. Документы и ответы ассистента не изменяют их. Для M3/M4 с памятью задачи нужны явно экспериментальные пороги; прежняя калибровка рассчитана без неё.',
            ),
            if (state == null)
              const Text('Выберите чат: память задачи ещё не загружена.')
            else ...[
              Text(
                'Проект: ${state.project}\nЧат: ${state.session}\nВерсия: ${state.revision}',
              ),
              if (state.facts.isEmpty) const Text('Условия пока не заданы.'),
              for (final fact in state.facts)
                Card(
                  child: ListTile(
                    title: Text(fact.id),
                    subtitle: SelectableText(fact.quote),
                    trailing: IconButton(
                      tooltip: 'Изменить ${fact.id}',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: _saving
                          ? null
                          : () {
                              setState(() {
                                _id.text = fact.id;
                                _value.text = fact.quote;
                                _kind = fact.kind;
                              });
                            },
                    ),
                  ),
                ),
              if (c.taskStateDiff.isNotEmpty) ...[
                const Text('Последние изменения'),
                for (final diff in c.taskStateDiff)
                  SelectableText(
                    '${diff['id']} · r${diff['revision']}\n${diff['before'] ?? 'не задано'} → ${diff['after']}',
                  ),
              ],
              ExpansionTile(
                title: Text('Заменённые значения · ${state.superseded.length}'),
                children: [
                  for (final f in state.superseded)
                    ListTile(
                      title: Text('${f.id} · исходная r${f.sourceRevision}'),
                      subtitle: SelectableText(f.quote),
                    ),
                ],
              ),
              ExpansionTile(
                title: const Text('Источники условий'),
                children: [
                  for (final fact in state.facts)
                    ListTile(
                      title: Text(
                        '${fact.id} · ${fact.sourceKind == 'manual_user_edit' ? 'ручная правка' : 'автоматически из вашей реплики'}',
                      ),
                      subtitle: SelectableText(
                        'Отправка ${fact.submissionId}\nЦитата: ${fact.quote}',
                      ),
                    ),
                ],
              ),
              ExpansionTile(
                title: Text('Снятые условия · ${state.retirements.length}'),
                children: [
                  for (final f in state.retirements)
                    ListTile(
                      title: Text('${f.id} · снято r${f.sourceRevision}'),
                      subtitle: SelectableText(
                        'Причина из вашей реплики: ${f.quote}',
                      ),
                    ),
                ],
              ),
              const Divider(),
              const Text('Ручное редактирование'),
              DropdownButtonFormField<RagTaskFactKind>(
                key: ValueKey(_kind),
                initialValue: _kind,
                decoration: const InputDecoration(labelText: 'Тип условия'),
                items: [
                  for (final k in RagTaskFactKind.values)
                    DropdownMenuItem(value: k, child: Text(k.wireName)),
                ],
                onChanged: _saving ? null : (k) => setState(() => _kind = k!),
              ),
              TextField(
                controller: _id,
                decoration: const InputDecoration(
                  labelText: 'Поле (например constraint.time)',
                ),
              ),
              TextField(
                controller: _value,
                minLines: 1,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Значение / ваша цитата',
                ),
              ),
              if (_error != null) Text(_error!),
              FilledButton(
                onPressed: _saving ? null : () => _save(),
                child: Text(
                  _saving ? 'Сохранение…' : 'Сохранить ручную правку',
                ),
              ),
              OutlinedButton(
                onPressed: _saving ? null : () => _save(retire: true),
                child: const Text('Снять условие (история сохранится)'),
              ),
            ],
          ],
        );
      },
    ),
  );
}

class RagUserStateCitationPage extends StatelessWidget {
  const RagUserStateCitationPage({
    required this.trace,
    required this.citation,
    super.key,
  });
  final Map trace, citation;
  @override
  Widget build(BuildContext context) {
    RagTaskState? state;
    RagTaskFact? fact;
    var valid = false;
    try {
      state = RagTaskState.fromJson(
        Map<String, dynamic>.from(trace['task_state'] as Map),
      );
      fact = state.facts.singleWhere((f) => f.id == citation['fact_id']);
      final quote = citation['quote'] as String;
      final start = citation['start_utf16'] as int,
          end = citation['end_utf16'] as int;
      valid =
          state.project == trace['project'] &&
          state.session == trace['session'] &&
          citation['project'] == state.project &&
          citation['session'] == state.session &&
          citation['state_revision'] == state.revision &&
          citation['chunk_id'] == state.evidenceId(fact) &&
          citation['submission_id'] == fact.submissionId &&
          citation['user_text_sha256'] == fact.toJson()['user_text_sha256'] &&
          start >= 0 &&
          end > start &&
          end <= fact.userText.length &&
          fact.userText.substring(start, end) == quote &&
          fact.quote.contains(quote);
    } on Object {
      valid = false;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Источник: условия пользователя')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Выбор пользователя из этой беседы. Это не цитата документа.',
            ),
            if (!valid)
              const Text(
                'Сохранённый источник не совпадает с областью, версией или цитатой.',
              )
            else ...[
              Text(
                'Проект ${state!.project}\nЧат ${state.session}\nВерсия задачи ${state.revision}\n${fact!.id}',
              ),
              SelectableText(
                'Отправка ${fact.submissionId}\nUTF-16 [${citation['start_utf16']}, ${citation['end_utf16']})',
              ),
              const SizedBox(height: 12),
              SelectableText(
                '«${citation['quote']}»',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 12),
              const Text('Исходная пользовательская реплика'),
              SelectableText(fact.userText),
            ],
          ],
        ),
      ),
    );
  }
}
