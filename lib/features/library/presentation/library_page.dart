import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/library_controller.dart';

/// List/detail browser backed solely by the local library MCP read tools.
class LibraryPage extends StatefulWidget {
  const LibraryPage({required this.controller, super.key});
  final LibraryController controller;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.controller.refresh();
  }

  @override
  void didUpdateWidget(covariant LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      widget.controller.refresh();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 850;
    final list = Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              labelText: 'Поиск по библиотеке',
              suffixIcon: IconButton(
                tooltip: 'Найти',
                onPressed: () => state.refresh(search: _search.text),
                icon: const Icon(Icons.search),
              ),
            ),
            onSubmitted: (value) => state.refresh(search: value),
          ),
        ),
        if (state.loading) const LinearProgressIndicator(),
        if (state.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              state.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: state.cards.isEmpty && !state.loading
              ? const Center(child: Text('Сохранённых подборок пока нет.'))
              : ListView.builder(
                  itemCount:
                      state.cards.length + (state.nextCursor == null ? 0 : 1),
                  itemBuilder: (context, index) {
                    if (index == state.cards.length) {
                      return TextButton(
                        onPressed: state.loadMore,
                        child: const Text('Загрузить ещё'),
                      );
                    }
                    final card = state.cards[index];
                    return ListTile(
                      key: ValueKey('library:${card.libraryId.value}'),
                      title: Text(card.topic),
                      subtitle: Text(
                        '${card.paperCount} статей · ${card.savedAt.toLocal()}\n${card.runId == null ? '' : 'Запуск: ${card.runId}'}',
                      ),
                      isThreeLine: card.runId != null,
                      selected: state.selected?.libraryId == card.libraryId,
                      onTap: () => state.open(card.libraryId),
                    );
                  },
                ),
        ),
      ],
    );
    final detail = _LibraryDetail(controller: state);
    return Scaffold(
      appBar: AppBar(title: const Text('Библиотека исследований')),
      body: wide
          ? Row(
              children: [
                SizedBox(width: 360, child: list),
                const VerticalDivider(width: 1),
                Expanded(child: detail),
              ],
            )
          : state.selected == null && !state.loadingDetail
          ? list
          : Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: state.closeDetail,
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('К списку'),
                  ),
                ),
                Expanded(child: detail),
              ],
            ),
    );
  }
}

class _LibraryDetail extends StatelessWidget {
  const _LibraryDetail({required this.controller});
  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.loadingDetail) {
      return const Center(child: CircularProgressIndicator());
    }
    final record = controller.selected;
    if (record == null) return const Center(child: Text('Выберите подборку.'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(record.topic, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text('Сохранено: ${record.savedAt.toLocal()}'),
        if (record.runId != null) Text('Запуск: ${record.runId}'),
        SelectableText('ID: ${record.libraryId.value}'),
        const SizedBox(height: 16),
        Chip(
          label: Text(
            'Источник: аннотации · sourceScope: ${record.digest.sourceScope}',
          ),
        ),
        const SizedBox(height: 12),
        Text('Сводка', style: Theme.of(context).textTheme.titleLarge),
        SelectableText(record.digest.overview),
        const SizedBox(height: 12),
        for (final item in record.digest.items)
          Card(
            child: ListTile(
              title: Text(item.arxivId.value),
              subtitle: Text(
                '${item.finding}${item.limitation == null ? '' : '\nОграничение: ${item.limitation}'}',
              ),
              isThreeLine: item.limitation != null,
              trailing: IconButton(
                tooltip: 'Открыть аннотацию',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => launchUrl(item.abstractUrl),
              ),
            ),
          ),
        const SizedBox(height: 16),
        Text('Статьи', style: Theme.of(context).textTheme.titleLarge),
        for (final paper in record.papers)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    paper.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('${paper.displayId} · ${paper.authors.join(', ')}'),
                  Text(
                    'Опубликовано: ${paper.publishedAt.toLocal()} · Обновлено: ${paper.updatedAt.toLocal()}',
                  ),
                  Text('Категории: ${paper.categories.join(', ')}'),
                  const SizedBox(height: 8),
                  SelectableText(paper.abstractText),
                  TextButton.icon(
                    onPressed: () => launchUrl(paper.abstractUrl),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Аннотация arXiv'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
