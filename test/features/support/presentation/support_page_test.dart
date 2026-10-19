import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/features/support/application/support_evidence_context.dart';
import 'package:domovoy/features/support/application/support_run_preparer.dart';
import 'package:domovoy/features/support/presentation/support_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../../support/support_harness.dart';
import '../../../support/support_evidence_fixture.dart';

void main() {
  testWidgets(
    'saved dense and supplemental source bodies expose distinct provenance',
    (tester) async {
      final h = SupportHarness(withMcp: false);
      addTearDown(h.close);
      await tester.binding.setSurfaceSize(const Size(1280, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final ticket = await h.create();
      final index = fixture(
        texts: ['Previous body\n', 'Dense body\n', 'Supplemental body\n'],
      );
      final coverage = await expandSupportEvidence(
        FrozenRepository(index),
        prepared(index, [RagHit(index.chunks[1], .81)]),
        CancellationSource().token,
      );
      await h.preparer.traces.saveRequest(
        supportRagProject,
        ticket.sessionId.value,
        'source-test',
        coverage.toJson(),
      );
      await h.controller.initialize();
      await h.controller.select(ticket);
      expect(h.controller.sources.single['context'], coverage.context);
      await tester.pumpWidget(
        MaterialApp(
          theme: DomovoyTheme.light(),
          home: SupportTicketPage(controller: h.controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Источники руководства'));
      await tester.pumpAndSettle();
      final query = find.text(coverage.turn.request.query);
      await tester.ensureVisible(query);
      await tester.tap(query);
      await tester.pumpAndSettle();
      final dense = find.ancestor(
        of: find.textContaining('Dense body'),
        matching: find.byType(SelectableText),
      );
      final supplemental = find.ancestor(
        of: find.textContaining('Supplemental body'),
        matching: find.byType(SelectableText),
      );
      expect(dense, findsOneWidget);
      expect(supplemental, findsOneWidget);
      await tester.ensureVisible(supplemental);
      await tester.pumpAndSettle();
      expect(
        tester
            .getRect(supplemental)
            .intersect(
              tester.getRect(
                find.byKey(const ValueKey('support-details-scroll')),
              ),
            )
            .height,
        greaterThan(20),
      );
      final text = tester.widget<SelectableText>(supplemental).data!;
      expect(text, contains('Соседний фрагмент'));
      expect(text, contains(index.chunks[1].id));
      expect(text, contains(index.generation));
      expect(text, contains(index.documents.first.revision));
      expect(
        text,
        contains('UTF-16 ${index.chunks[2].start}–${index.chunks[2].end}'),
      );
      expect(
        tester.widget<SelectableText>(dense).data,
        contains('Dense · ранг: 1 · cosine: 0.81'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

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

  for (final size in [
    const Size(360, 640),
    const Size(390, 844),
    const Size(1280, 900),
  ]) {
    testWidgets(
      'expanded details, sources and preparation failure keep input usable with keyboard at $size',
      (tester) async {
        final h = SupportHarness(
          withMcp: false,
          manualLoader: () async => throw StateError('offline manual failure'),
        );
        addTearDown(h.close);
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final ticket = await h.create();
        await h.controller.initialize();
        await h.controller.select(ticket);
        // Use the real failed preparation path, with no model/network dispatch.
        expect((await h.controller.send('Нужна помощь')).isSuccess, false);
        expect(h.preparer.error, isNotNull);
        h.controller.sources = [
          {
            'query': 'Обычный вопрос',
            'protocol': 'M1',
            'fingerprint': 'fixture',
            'candidates': [
              {
                'sent': true,
                'chunk': {
                  'source': 'domovoy://manual',
                  'section': 'Раздел',
                  'revision': '1',
                  'text': 'Содержимое источника',
                },
              },
            ],
          },
        ];
        var keyboard = 0.0;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: DomovoyTheme.light(),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MediaQuery(
                  data: MediaQueryData(
                    size: size,
                    viewInsets: EdgeInsets.only(bottom: keyboard),
                  ),
                  child: SupportTicketPage(controller: h.controller),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final details = find.byKey(const ValueKey('support-details-scroll'));
        final scroll = find
            .descendant(of: details, matching: find.byType(Scrollable))
            .first;
        Future<void> reveal(Finder finder) async {
          await tester.scrollUntilVisible(
            finder,
            60,
            scrollable: scroll,
            maxScrolls: 40,
          );
          await tester.pumpAndSettle();
        }

        await reveal(find.text('Описание и технический снимок'));
        await tester.tap(find.text('Описание и технический снимок'));
        await tester.pumpAndSettle();
        await reveal(find.text('Источники руководства'));
        await tester.tap(find.text('Источники руководства'));
        await tester.pumpAndSettle();
        await reveal(find.text('Обычный вопрос'));
        await tester.tap(find.text('Обычный вопрос'));
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('chat-composer-field'));
        await tester.enterText(field, 'Черновик не должен пропасть');
        update(() => keyboard = 300);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        void checkInput() {
          final input = tester.widget<TextField>(field);
          expect(input.controller!.text, 'Черновик не должен пропасть');
          expect(input.focusNode!.hasFocus, true);
          expect(field.hitTestable(), findsOneWidget);
          expect(
            find.byKey(const ValueKey('chat-send')).hitTestable(),
            findsOneWidget,
          );
          expect(
            tester.getRect(find.byKey(const ValueKey('chat-send'))).bottom,
            lessThanOrEqualTo(size.height - keyboard),
          );
        }

        checkInput();
        await reveal(find.textContaining('Содержимое источника'));
        expect(
          find.textContaining('Содержимое источника').hitTestable(),
          findsOneWidget,
        );
        final preparationError = find.descendant(
          of: details,
          matching: find.text(h.preparer.error!),
        );
        await reveal(preparationError);
        // The error can be taller than the keyboard-reduced metadata viewport.
        // Its visible portion must remain readable by scrolling.
        final visibleError = tester
            .getRect(preparationError)
            .intersect(tester.getRect(details));
        expect(visibleError.height, greaterThan(20));
        expect(visibleError.width, greaterThan(100));
        await tester.fling(details, const Offset(0, 2000), 4000);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Изменить статус').hitTestable(), findsOneWidget);
        checkInput();
        update(() => keyboard = 0);
        await tester.pumpAndSettle();
        checkInput();
        expect(tester.takeException(), isNull);
        expect(h.provider.requests, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets('360x640 with 300px keyboard can expand details directly', (
    tester,
  ) async {
    final h = SupportHarness(withMcp: false);
    addTearDown(h.close);
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ticket = await h.create();
    await h.controller.initialize();
    await h.controller.select(ticket);
    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: SupportTicketPage(controller: h.controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = find.text('Описание и технический снимок');
    expect(title.hitTestable(), findsOneWidget);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.byType(SupportSnapshotCard), findsOneWidget);
    expect(
      find.byKey(const ValueKey('chat-composer-field')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

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
