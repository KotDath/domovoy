import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/rag/models.dart';
import '../application/rag_chat_controller.dart';

class RagChatBar extends StatelessWidget {
  const RagChatBar({
    required this.controller,
    required this.child,
    required this.enabled,
    super.key,
  });
  final RagChatController controller;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<bool>(
                key: const ValueKey('rag.mode'),
                value: controller.enabled,
                items: const [
                  DropdownMenuItem(value: false, child: Text('Обычный')),
                  DropdownMenuItem(value: true, child: Text('По документам')),
                ],
                onChanged: enabled && !controller.busy
                    ? (value) => controller.configure(enabled: value)
                    : null,
              ),
              if (controller.enabled) ...[
                DropdownButton<String>(
                  key: const ValueKey('rag.corpus'),
                  value: controller.corpus,
                  items: const [
                    DropdownMenuItem(value: 'domovoy', child: Text('Domovoy')),
                    DropdownMenuItem(
                      value: 'arxiv',
                      child: Text('arXiv: память'),
                    ),
                  ],
                  onChanged: enabled && !controller.busy
                      ? (value) => controller.configure(corpus: value)
                      : null,
                ),
                DropdownButton<ChunkStrategy>(
                  key: const ValueKey('rag.strategy'),
                  value: controller.strategy,
                  items: [
                    for (final strategy in ChunkStrategy.values)
                      DropdownMenuItem(
                        value: strategy,
                        child: Text(strategy.name),
                      ),
                  ],
                  onChanged: enabled && !controller.busy
                      ? (value) => controller.configure(strategy: value)
                      : null,
                ),
              ],
              TextButton.icon(
                key: const ValueKey('rag.inspector'),
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => RagInspectorPage(controller: controller),
                  ),
                ),
                icon: const Icon(Icons.source_outlined, size: 18),
                label: Text(
                  'Источники · ${controller.history.isEmpty ? 0 : _sent(controller.history.last).length}',
                ),
              ),
            ],
          ),
        ),
        if (controller.busy || controller.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(controller.error ?? controller.progress),
          ),
        child,
      ],
    ),
  );
}

List<Map> _sent(Map trace) => (trace['candidates'] as List? ?? [])
    .whereType<Map>()
    .where((row) => row['sent'] == true)
    .toList();

class RagInspectorPage extends StatelessWidget {
  const RagInspectorPage({required this.controller, super.key});
  final RagChatController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Источники и RAG-инспектор')),
    body: ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            title: const Text('Нейтральное сравнение'),
            subtitle: const Text(
              'Без профиля и памяти. Для M0/M1 используйте отдельные новые чаты и одинаковую модель.',
            ),
            value: controller.neutralEvaluation,
            onChanged: controller.busy
                ? null
                : (value) => controller.configure(neutral: value),
          ),
          const Text(
            'Ссылки показывают извлечённые источники. Цитаты и смысл ответа на этом этапе не проверены.',
          ),
          if (controller.error != null) Text(controller.error!),
          if (controller.history.isEmpty)
            const Text('В этом чате ещё нет сохранённых RAG-запросов.'),
          for (final trace in controller.history.reversed)
            _TraceCard(trace: trace),
        ],
      ),
    ),
  );
}

class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.trace});
  final Map<String, dynamic> trace;
  @override
  Widget build(BuildContext context) {
    final request = trace['request'] as Map? ?? {};
    final completion = trace['completion'] as Map?;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${trace['protocol']} · ${trace['query']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SelectableText(
              'request ${trace['id']}\n'
              '${trace['corpus']} · ${trace['strategy']} · generation ${trace['generation']}\n'
              'fingerprint ${trace['fingerprint']}\n'
              'модель ${jsonEncode(request['model'])}\n'
              'инструментов ${request['tools_count']} · ${request['utf8_bytes']} байт полного запроса\n'
              'подготовка ${jsonEncode(trace['timings_ms'])} мс\n'
              'результат ${completion?['terminal'] ?? 'запрос сохранён; результат ещё не получен'}\n'
              'message ${completion?['accepted_message_id']} · всего ${completion?['elapsed_ms']} мс',
            ),
            if (completion != null)
              ExpansionTile(
                title: const Text('Usage провайдера'),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent(
                      '  ',
                    ).convert(completion['usage']),
                  ),
                ],
              ),
            for (final candidate
                in (trace['candidates'] as List? ?? []).whereType<Map>())
              _SourceCard(candidate: candidate),
            ExpansionTile(
              title: const Text('Фактически отправленный контекст'),
              children: [
                SelectableText(request['system_prompt'] as String? ?? ''),
              ],
            ),
            ExpansionTile(
              title: const Text('История в фактическом запросе'),
              children: [
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(request['messages']),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.candidate});
  final Map candidate;
  @override
  Widget build(BuildContext context) {
    final chunk = candidate['chunk'] as Map;
    return ExpansionTile(
      title: Text(
        '${candidate['sent'] == true ? 'Отправлен' : 'Исключён'} · '
        '${(candidate['cosine'] as num).toStringAsFixed(4)} cosine · ${chunk['source']}',
      ),
      subtitle: Text(
        '${chunk['section']}\n${candidate['excluded_reason'] ?? 'retrieval provenance'}',
      ),
      children: [
        SelectableText(
          'chunk_id ${chunk['id']}\nrevision ${chunk['revision']}\n'
          'UTF-16 [${chunk['start']}, ${chunk['end']}) · страницы ${chunk['page_start']}–${chunk['page_end']}\n\n'
          '${chunk['text']}',
        ),
      ],
    );
  }
}
