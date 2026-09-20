import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/chat_token_presenter.dart';

class UsageView extends StatelessWidget {
  const UsageView({this.projection, super.key});

  final ChatTokenProjection? projection;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final session = projection?.primaryGroups
        .where((group) => group.key == 'history')
        .firstOrNull;
    String value(String label) {
      final match = session?.values
          .where((entry) => entry.label == label)
          .firstOrNull;
      return match?.display ?? '—';
    }

    return SingleChildScrollView(
      key: const ValueKey('usage-view'),
      padding: DomovoyDimensions.pageInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Использование токенов',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: DomovoyDimensions.space3),
          Text(
            'Локальная статистика текущей сессии. Неизвестное — «—».',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: DomovoyDimensions.space7),
          Wrap(
            spacing: DomovoyDimensions.space7,
            runSpacing: DomovoyDimensions.space7,
            children: [
              _Metric(label: 'Всего токенов', value: value('Всего')),
              _Metric(label: 'Входящие', value: value('Ввод')),
              _Metric(label: 'Исходящие', value: value('Вывод')),
              const _Metric(
                label: 'Стоимость',
                value: '—',
                hint: 'Тарифы не заданы',
              ),
            ],
          ),
          const SizedBox(height: DomovoyDimensions.space7),
          DomovoySurface(
            role: DomovoySurfaceRole.elevated,
            border: true,
            borderRadius: BorderRadius.circular(DomovoyDimensions.radiusLarge),
            padding: DomovoyDimensions.panelInsets,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Токены по дням',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: DomovoyDimensions.space4),
                Text(
                  'Дневная разбивка не хранится. Показываем «—», а не выдуманный график.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.hint});

  final String label;
  final String value;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return SizedBox(
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: DomovoyDimensions.space2),
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
          if (hint != null)
            Text(
              hint!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
            ),
        ],
      ),
    );
  }
}
