import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../core/rag/models.dart';
import '../../../core/rag/turn.dart';
import '../../../core/rag/retrieval.dart';
import '../application/rag_chat_controller.dart';
import '../application/rag_final_answer_gate.dart';

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
                DropdownButton<RagProtocol>(
                  key: const ValueKey('rag.protocol'),
                  value: controller.protocol,
                  items: [
                    for (final mode in RagProtocol.values.where(
                      (m) => m != RagProtocol.m0,
                    ))
                      DropdownMenuItem(
                        value: mode,
                        child: Text(mode.name.toUpperCase()),
                      ),
                  ],
                  onChanged: enabled && !controller.busy
                      ? (value) => controller.configure(protocol: value)
                      : null,
                ),
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
              'Без профиля и памяти. Для сравнения используйте отдельные новые чаты и одинаковую модель.',
            ),
            value: controller.neutralEvaluation,
            onChanged: controller.busy
                ? null
                : (value) => controller.configure(neutral: value),
          ),
          if (controller.enabled) ...[
            SwitchListTile(
              title: const Text('Проверять цитаты до сохранения'),
              subtitle: const Text(
                'Ответ поступит в историю после проверки JSON, источников и точных цитат. Смысл цитат оценивается отдельно.',
              ),
              value: controller.strictGrounding,
              onChanged: controller.busy
                  ? null
                  : (v) => controller.configure(strictGrounding: v),
            ),
            if (controller.strictGrounding)
              DropdownButtonFormField<RagGroundingFault>(
                key: ValueKey(controller.groundingFault),
                initialValue: controller.groundingFault,
                decoration: const InputDecoration(
                  labelText: 'Диагностика: явная подмена ответа',
                ),
                items: const [
                  DropdownMenuItem(
                    value: RagGroundingFault.none,
                    child: Text('Отключена'),
                  ),
                  DropdownMenuItem(
                    value: RagGroundingFault.wrongChunkId,
                    child: Text('Демо: неверный chunk ID'),
                  ),
                  DropdownMenuItem(
                    value: RagGroundingFault.wrongQuote,
                    child: Text('Демо: выдуманная цитата'),
                  ),
                ],
                onChanged: controller.busy
                    ? null
                    : (v) => controller.configure(groundingFault: v),
              ),
            if (controller.groundingFault != RagGroundingFault.none)
              const Text(
                'Включена демонстрационная подмена: реальный ответ модели намеренно повреждается перед проверкой. Отклонённые черновики не входят в историю.',
              ),
          ],
          if (controller.enabled) ...[
            Text('Настройки отбора · ${controller.retrieval.calibrationId}'),
            if (controller.retrieval.calibrationId == 'manual-experiment')
              const Text(
                'Экспериментальные пороги. Для текущего корпуса и моделей '
                'они не проверены; качество отбора может измениться.',
              ),
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.configure(
                      retrieval: controller.defaultRetrieval,
                      strategy: controller.defaultRetrieval.strategy,
                    ),
              child: const Text('Восстановить калибровку'),
            ),
            Text(
              'Cosine порог: ${controller.retrieval.denseThreshold.toStringAsFixed(3)} (M2/M3)',
            ),
            Slider(
              key: const ValueKey('rag.denseThreshold'),
              min: -1,
              max: 1,
              divisions: 200,
              value: controller.retrieval.denseThreshold,
              onChanged: controller.busy
                  ? null
                  : (v) => controller.configure(
                      retrieval: RagRetrievalConfig(
                        denseThreshold: v,
                        rerankThreshold: controller.retrieval.rerankThreshold,
                        calibrationId: 'manual-experiment',
                      ),
                    ),
            ),
            Text(
              'BGE raw logit порог: ${controller.retrieval.rerankThreshold.toStringAsFixed(2)} (M4)',
            ),
            Slider(
              key: const ValueKey('rag.rerankThreshold'),
              min: controller.retrieval.rerankThreshold < -15
                  ? controller.retrieval.rerankThreshold.floorToDouble() - 1
                  : -15,
              max: controller.retrieval.rerankThreshold > 15
                  ? controller.retrieval.rerankThreshold.ceilToDouble() + 1
                  : 15,
              divisions: 300,
              value: controller.retrieval.rerankThreshold,
              onChanged: controller.busy
                  ? null
                  : (v) => controller.configure(
                      retrieval: RagRetrievalConfig(
                        denseThreshold: controller.retrieval.denseThreshold,
                        rerankThreshold: v,
                        calibrationId: 'manual-experiment',
                      ),
                    ),
            ),
          ],
          Text(
            controller.strictGrounding
                ? 'Точные цитаты проверяет приложение. Это не автоматическое доказательство смысла ответа. Старые запросы могли выполняться без проверки.'
                : 'Ссылки показывают извлечённые источники. Цитаты и смысл ответа не проверены.',
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
    final diagnostic = trace['diagnostic'] as Map?;
    final grounding = completion?['grounding'] as Map?;
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
            Text(
              'Кандидаты: ${(trace['candidates'] as List? ?? []).length} → '
              'источники: ${(trace['candidates'] as List? ?? []).where((c) => c['sent'] == true).length}',
            ),
            if (trace['strict_grounding'] == true)
              Text(
                'Проверка ответа: ${grounding?['status'] ?? (diagnostic?['accepted'] == false ? 'отклонён' : 'ожидание')}',
              ),
            if (trace['physical_answer_requests'] == 0)
              const Text('Недостаточно данных · запросов к модели ответа: 0'),
            if (diagnostic != null)
              ExpansionTile(
                title: Text(
                  'Диагностика проверки · ${diagnostic['accepted'] == true ? 'принят' : 'отклонён'} · ${diagnostic['reason'] ?? 'точные цитаты'}',
                ),
                children: [
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(diagnostic),
                  ),
                ],
              ),
            if (grounding != null)
              for (final claim
                  in (grounding['claims'] as List? ?? []).whereType<Map>())
                _GroundedClaimCard(claim: claim, trace: trace),
            if (trace['rewritten_query'] != null)
              SelectableText('Поисковый запрос: ${trace['rewritten_query']}'),
            if ((trace['rewrite_audit'] as Map?)?['fallback_reason'] != null)
              Text(
                'Исходный запрос сохранён: ${(trace['rewrite_audit'] as Map)['fallback_reason']}',
              ),
            Text('Время этапов: ${jsonEncode(trace['timings_ms'])} мс'),
            if (trace['reranker_scale'] != null)
              Text('Реранкер: BGE v2-m3 · ${trace['reranker_scale']}'),
            ExpansionTile(
              title: const Text('Трасса запроса и конфигурация'),
              children: [
                SelectableText(
                  'request ${trace['id']}\n'
                  '${trace['corpus']} · ${trace['strategy']} · generation ${trace['generation']}\n'
                  'fingerprint ${trace['fingerprint']}\n'
                  'rewrite ${trace['rewritten_query']}\n'
                  'rewrite fallback ${(trace['rewrite_audit'] as Map?)?['fallback_reason']} · '
                  '${(trace['rewrite_audit'] as Map?)?['elapsed_ms']} мс\n'
                  'отбор ${jsonEncode(trace['retrieval_config'])}\n'
                  'reranker ${trace['reranker_fingerprint']} · ${trace['reranker_scale']}\n'
                  'reranker usage ${jsonEncode(trace['reranker_usage'])}\n'
                  'модель ${jsonEncode(request['model'])}\n'
                  'инструментов ${request['tools_count']} · ${request['utf8_bytes']} байт полного запроса\n'
                  'подготовка ${jsonEncode(trace['timings_ms'])} мс\n'
                  'результат ${completion?['terminal'] ?? 'запрос сохранён; результат ещё не получен'}\n'
                  'message ${completion?['accepted_message_id']} · всего ${completion?['elapsed_ms']} мс',
                ),
              ],
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

class _GroundedClaimCard extends StatelessWidget {
  const _GroundedClaimCard({required this.claim, required this.trace});
  final Map claim, trace;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(claim['text'] as String),
          for (final citation
              in (claim['evidence'] as List).whereType<Map>()) ...[
            SelectableText('«${citation['quote']}»'),
            Text('${citation['source']} · ${citation['section']}'),
            TextButton(
              onPressed: () {
                final candidate = (trace['candidates'] as List)
                    .whereType<Map>()
                    .where(
                      (c) => (c['chunk'] as Map)['id'] == citation['chunk_id'],
                    )
                    .firstOrNull;
                if (candidate == null || candidate['sent'] != true) return;
                Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => _CitationPage(
                      chunk: candidate['chunk'] as Map,
                      citation: citation,
                    ),
                  ),
                );
              },
              child: const Text('Открыть цитату в источнике'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _CitationPage extends StatelessWidget {
  const _CitationPage({required this.chunk, required this.citation});
  final Map chunk, citation;
  @override
  Widget build(BuildContext context) {
    final text = chunk['text'] as String;
    final start = (citation['start_utf16'] as int) - (chunk['start'] as int);
    final end = (citation['end_utf16'] as int) - (chunk['start'] as int);
    final valid =
        citation['revision'] == chunk['revision'] &&
        start >= 0 &&
        end <= text.length &&
        end > start &&
        text.substring(start, end) == citation['quote'];
    return Scaffold(
      appBar: AppBar(title: const Text('Источник и точная цитата')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${chunk['source']} · ${chunk['section']}'),
            SelectableText(
              'chunk_id ${chunk['id']}\nrevision ${chunk['revision']}\n'
              'UTF-16 [${citation['start_utf16']}, ${citation['end_utf16']}) · страницы ${citation['page_start']}–${citation['page_end']}',
            ),
            if (!valid)
              const Text(
                'Сохранённая цитата не совпадает с ревизией источника.',
              )
            else ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: SelectableText(text.substring(start, end)),
              ),
              ExpansionTile(
                title: const Text('Чанк целиком с подсветкой'),
                children: [
                  SelectableText.rich(
                    TextSpan(
                      style: DefaultTextStyle.of(context).style,
                      children: [
                        TextSpan(text: text.substring(0, start)),
                        TextSpan(
                          text: text.substring(start, end),
                          style: TextStyle(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextSpan(text: text.substring(end)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
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
        '${(candidate['cosine'] as num).toStringAsFixed(4)} cosine · ${chunk['source']}'
        '${candidate['rerank'] == null ? '' : ' · ${(candidate['rerank'] as num).toStringAsFixed(3)} BGE raw logit'}',
      ),
      subtitle: Text(
        'dense #${candidate['dense_rank']}'
        '${candidate['rerank_rank'] == null ? '' : ' → rerank #${candidate['rerank_rank']}'}\n'
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
