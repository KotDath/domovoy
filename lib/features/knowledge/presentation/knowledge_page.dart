import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/rag/models.dart';
import '../application/knowledge_controller.dart';
import 'knowledge_comparison_page.dart';

class KnowledgePage extends StatefulWidget {
  const KnowledgePage({required this.controller, super.key});
  final KnowledgeController controller;
  @override
  State<KnowledgePage> createState() => _KnowledgePageState();
}

class _KnowledgePageState extends State<KnowledgePage> {
  final _arxiv = TextEditingController();
  final _query = TextEditingController(
    text: 'Какие слои памяти есть в Domovoy?',
  );
  @override
  void dispose() {
    _arxiv.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final chars = c.documents.fold<int>(0, (n, d) => n + d.text.runes.length);
      return Scaffold(
        appBar: AppBar(
          title: const Text('База знаний'),
          actions: [
            IconButton(
              key: const ValueKey('knowledge.reload'),
              tooltip: 'Перечитать с диска',
              onPressed: c.busy ? null : () => unawaited(c.initialize()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: c.corpus,
                  onChanged: c.busy
                      ? null
                      : (v) => unawaited(c.selectCorpus(v!)),
                  items: const [
                    DropdownMenuItem(value: 'domovoy', child: Text('Domovoy')),
                    DropdownMenuItem(
                      value: 'arxiv',
                      child: Text('arXiv: память'),
                    ),
                  ],
                ),
                OutlinedButton.icon(
                  key: const ValueKey('knowledge.health'),
                  onPressed: c.busy ? null : () => unawaited(c.checkService()),
                  icon: const Icon(Icons.network_check),
                  label: const Text('Проверить модели'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Индекс и поиск — на устройстве. Эмбеддинги — на ПК.'),
            if (c.model != null)
              Text('${c.model!.label} · ${c.model!.dimension}D'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const ValueKey('knowledge.demo'),
                  onPressed: c.busy || c.corpus != 'domovoy'
                      ? null
                      : () => unawaited(c.loadDemoCorpus()),
                  child: const Text('Документы Domovoy'),
                ),
                OutlinedButton(
                  key: const ValueKey('knowledge.import'),
                  onPressed: c.busy ? null : () => unawaited(c.importFiles()),
                  child: const Text('Импорт файлов'),
                ),
                OutlinedButton(
                  key: const ValueKey('knowledge.addText'),
                  onPressed: c.busy ? null : () => _addText(context),
                  child: const Text('Добавить текст'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _arxiv,
                    key: const ValueKey('knowledge.arxivId'),
                    enabled: !c.busy,
                    decoration: const InputDecoration(
                      labelText: 'arXiv ID / URL',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('knowledge.arxiv'),
                  tooltip: 'Импортировать PDF arXiv',
                  onPressed: c.busy
                      ? null
                      : () => unawaited(c.importArxiv(_arxiv.text)),
                  icon: const Icon(Icons.download),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '${c.documents.length} документов · $chars символов · '
              '${(chars / 1800).toStringAsFixed(1)} условных страниц (1800 символов)',
            ),
            if (c.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  c.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.progress.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  c.progress,
                  key: const ValueKey('knowledge.progress'),
                ),
              ),
            if (c.canCancel)
              TextButton(onPressed: c.cancel, child: const Text('Отменить')),
            const Divider(),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<ChunkStrategy>(
                  key: const ValueKey('knowledge.strategy'),
                  value: c.strategy,
                  onChanged: c.busy ? null : (v) => c.selectStrategy(v!),
                  items: const [
                    DropdownMenuItem(
                      value: ChunkStrategy.fixed,
                      child: Text('Fixed · 384 / 64'),
                    ),
                    DropdownMenuItem(
                      value: ChunkStrategy.structure,
                      child: Text('Structure · 384 / 64'),
                    ),
                  ],
                ),
                FilledButton(
                  key: const ValueKey('knowledge.index'),
                  onPressed: c.busy || c.documents.isEmpty
                      ? null
                      : () => unawaited(c.buildIndex()),
                  child: const Text('Построить индекс'),
                ),
                OutlinedButton(
                  key: const ValueKey('knowledge.compare'),
                  onPressed: c.busy || c.indexes.length < 2
                      ? null
                      : () => _compare(context),
                  child: const Text('Сравнить стратегии'),
                ),
              ],
            ),
            for (final index in c.indexes.values)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    '${index.strategy.name}: ${index.chunks.length} чанков · '
                    '${index.dimension}D · ${(index.elapsedMs / 1000).toStringAsFixed(1)} с\n'
                    'generation ${index.generation.substring(0, 12)}'
                    '${c.indexStale(index) ? " · документы изменились" : " · сохранён"}',
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _query,
                    key: const ValueKey('knowledge.query'),
                    enabled: !c.busy,
                    decoration: const InputDecoration(
                      labelText: 'Семантический поиск',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) => unawaited(c.search(v)),
                  ),
                ),
                IconButton(
                  key: const ValueKey('knowledge.search'),
                  tooltip: 'Найти чанки',
                  onPressed: c.busy || c.activeIndex == null
                      ? null
                      : () => unawaited(c.search(_query.text)),
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
            for (final hit in c.hits)
              Card(
                child: ListTile(
                  title: Text(
                    '${hit.score.toStringAsFixed(4)} cosine · ${hit.chunk.title}',
                  ),
                  subtitle: Text(hit.chunk.section),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _showChunk(context, hit.chunk),
                ),
              ),
            const Divider(),
            for (final doc in c.documents)
              ListTile(
                title: Text(doc.title),
                subtitle: Text(
                  '${doc.text.runes.length} символов · '
                  '${doc.pageStarts.isEmpty ? "текст" : "${doc.pageStarts.length} PDF-страниц"} · '
                  '${doc.revision.substring(0, 8)}',
                ),
                trailing: doc.pdfHash == null
                    ? null
                    : IconButton(
                        tooltip: 'Открыть исходный PDF',
                        icon: const Icon(Icons.picture_as_pdf),
                        onPressed: () => unawaited(_showPdf(context, doc)),
                      ),
                onTap: () => _showDocument(context, doc),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _addText(BuildContext context) async {
    final title = TextEditingController();
    final text = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новый документ'),
        content: SizedBox(
          width: 500,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              TextField(
                controller: text,
                maxLines: 5,
                decoration: const InputDecoration(labelText: 'Текст'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await widget.controller.addText(title.text, text.text);
    }
    // Dialog exit animation still reads controllers; dispose after route settles.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    title.dispose();
    text.dispose();
  }

  Future<void> _showPdf(BuildContext context, RagDocument doc) async {
    final c = widget.controller;
    final project = c.project;
    final corpus = c.corpus;
    try {
      final bytes = await c.repository.originalPdf(project, corpus, doc);
      if (!context.mounted) return;
      if (bytes == null) throw StateError('Исходный PDF не найден');
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: AppBar(title: Text(doc.title)),
            body: PdfViewer.data(
              Uint8List.fromList(bytes),
              sourceName: doc.source,
            ),
          ),
        ),
      );
    } on Object catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  void _showDocument(BuildContext context, RagDocument doc) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(doc.title)),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              '${doc.source}\n'
              'revision ${doc.revision}\nsource revision: ${doc.sourceRevision ?? "local content hash"}\n'
              '${doc.source.endsWith("automation-user-guide.md") ? "Известная ошибка источника: cron 0 0-30/10 * * * задаёт часы 0–30 вне допустимого диапазона 0–23.\n" : ""}'
              '\n${doc.text}',
            ),
          ),
        ),
      ),
    );
  }

  void _showChunk(BuildContext context, RagChunk chunk, [RagIndex? snapshot]) {
    final index = snapshot ?? widget.controller.activeIndex!;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Чанк и метаданные')),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              'source: ${chunk.source}\nsection: ${chunk.section}\n'
              'chunk_id: ${chunk.id}\nrevision: ${chunk.documentRevision}\n'
              'UTF-16: [${chunk.start}, ${chunk.end})\n'
              'pages: ${chunk.pageStart ?? "—"}–${chunk.pageEnd ?? "—"}\n'
              'tokens: ${chunk.tokens}\nvector: ${index.dimension}D\n'
              'fingerprint: ${index.fingerprint}\n\n${chunk.text}',
            ),
          ),
        ),
      ),
    );
  }

  void _compare(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => KnowledgeComparisonPage(
          controller: widget.controller,
          showChunk: (context, chunk, index) =>
              _showChunk(context, chunk, index),
        ),
      ),
    );
  }
}
