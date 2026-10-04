import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/rag/models.dart';
import '../application/knowledge_controller.dart';

class KnowledgeComparisonPage extends StatefulWidget {
  const KnowledgeComparisonPage({
    required this.controller,
    required this.showChunk,
    super.key,
  });
  final KnowledgeController controller;
  final void Function(BuildContext, RagChunk, RagIndex) showChunk;
  @override
  State<KnowledgeComparisonPage> createState() =>
      _KnowledgeComparisonPageState();
}

class _KnowledgeComparisonPageState extends State<KnowledgeComparisonPage> {
  final _query = TextEditingController(
    text: 'Какие слои памяти есть в Domovoy?',
  );
  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      return Scaffold(
        appBar: AppBar(title: const Text('Сравнение chunking')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Два снимка: одинаковый корпус, fingerprint модели и один query-вектор.',
            ),
            TextField(
              controller: _query,
              enabled: !c.busy,
              decoration: const InputDecoration(
                labelText: 'Поисковая проба',
                border: OutlineInputBorder(),
              ),
            ),
            FilledButton(
              onPressed: c.busy
                  ? null
                  : () => unawaited(c.compareSearch(_query.text)),
              child: const Text('Сравнить top-5'),
            ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.error != null)
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (c.comparisonQuery != null)
              Text('Реальный запрос: ${c.comparisonQuery}'),
            for (final index in c.indexes.values) ...[
              const SizedBox(height: 16),
              Text(
                index.strategy.name,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                '${c.indexStale(index) ? "Устаревший снимок · " : ""}'
                '384 / 64 модельных токенов · ${index.chunks.length} чанков · '
                '${index.chunks.map((c) => c.tokens).reduce((a, b) => a + b) ~/ index.chunks.length} средних токенов · '
                '${index.chunks.where((c) => c.forcedSplit).length} разрезов внутри блока\n'
                '${(index.elapsedMs / 1000).toStringAsFixed(1)} с · ${index.serializedBytes} байт JSONL\n'
                '${index.overlapCharacters} повторных UTF-16 символов · '
                '${index.chunks.map((c) => c.tokens).reduce((a, b) => a < b ? a : b)}–'
                '${index.chunks.map((c) => c.tokens).reduce((a, b) => a > b ? a : b)} токенов/чанк\n'
                'fingerprint: ${index.fingerprint}',
              ),
              for (final hit in c.comparisonHits[index.strategy] ?? <RagHit>[])
                ListTile(
                  title: Text(
                    '${hit.score.toStringAsFixed(4)} cosine · ${hit.chunk.title}',
                  ),
                  subtitle: Text(hit.chunk.section),
                  onTap: () => widget.showChunk(context, hit.chunk, index),
                ),
              for (final chunk in index.chunks.take(3))
                Card(
                  child: ListTile(
                    title: Text(
                      '${chunk.section} · [${chunk.start}, ${chunk.end})',
                    ),
                    subtitle: Text(
                      chunk.text,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => widget.showChunk(context, chunk, index),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}
