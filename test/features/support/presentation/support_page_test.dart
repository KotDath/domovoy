import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/support/presentation/support_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/support_harness.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1280, 900)]) {
    testWidgets(
      'support list/create/snapshot/explicit status/reopen works without project at $size',
      (tester) async {
        final h = SupportHarness(withMcp: false);
        addTearDown(h.close);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: DomovoyTheme.light(),
            home: SupportPage(controller: h.controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Поддержка'), findsOneWidget);
        await tester.tap(find.text('Новое обращение'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Платформа: android'), findsOneWidget);
        expect(find.text('Связать с текущим проектом'), findsNothing);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Тема'),
          'Вопрос о продукте',
        );
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Описание проблемы'),
          'Нужна помощь',
        );
        await tester.tap(find.text('Создать'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Вопрос о продукте'), findsOneWidget);
        expect(find.text('Источники руководства'), findsOneWidget);
        expect(h.controller.selected!.ready, true);
        await tester.tap(find.byTooltip('Изменить статус'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Решено'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Подтвердить'));
        await tester.pumpAndSettle();
        expect(h.controller.selected!.status, SupportStatus.resolved);
        await tester.tap(find.byTooltip('Изменить статус'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Открыто'));
        await tester.pumpAndSettle();
        expect(find.text('Повторно открыть обращение?'), findsOneWidget);
        await tester.tap(find.text('Подтвердить'));
        await tester.pumpAndSettle();
        expect(h.controller.selected!.status, SupportStatus.open);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('cancel creation disposes the dialog safely without a ticket', (
    tester,
  ) async {
    final h = SupportHarness(withMcp: false);
    addTearDown(h.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: SupportPage(controller: h.controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Новое обращение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(h.controller.tickets, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
