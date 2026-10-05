import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/grounding.dart';
import 'package:domovoy/core/rag/turn.dart';
import 'package:domovoy/features/knowledge/application/rag_chat_controller.dart';
import 'package:domovoy/features/knowledge/presentation/rag_chat_bar.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_repository.dart';
import 'package:domovoy/infrastructure/rag/jsonl_rag_trace_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';
import '../../../support/memory_jsonl_storage.dart';
import '../../../support/rag_fakes.dart';
import '../../../support/rag_grounding_fixture.dart';

void main() {
  for (final tampered in [false, true]) {
    testWidgets(
      'citation viewer ${tampered ? 'rejects tampering' : 'highlights the frozen exact span'}',
      (tester) async {
        final f = RagGroundingFixture();
        final runtime = testRuntime(
          provider: QueueScriptedLlmProvider(
            id: BuiltInLlmCatalog.deepSeek,
            wireFamily: LlmWireFamily.openaiChatCompletions,
            turns: [],
          ),
        );
        final storage = FakeMemoryJsonlStorage();
        final controller = RagChatController(
          strictGrounding: true,
          coordinator: RagTurnCoordinator(
            repository: JsonlRagRepository(storage),
            models: FakeRagModels(),
          ),
          traces: JsonlRagTraceRepository(storage),
          registry: runtime.registry,
        )..configure(enabled: true);
        addTearDown(controller.dispose);
        addTearDown(runtime.close);
        final grounding =
            jsonDecode(
                  jsonEncode(
                    RagGroundedAnswer.parse(f.answer(), f.turn).toJson(),
                  ),
                )
                as Map;
        if (tampered) {
          ((grounding['claims'] as List).single['evidence'] as List)
                  .single['quote'] =
              'A forged quote';
        }
        controller.history = [
          {
            ...f.turn.toJson(),
            'strict_grounding': true,
            'completion': {
              'grounding': grounding,
              'accepted_message_id': 'accepted',
            },
          },
        ];
        await tester.pumpWidget(
          MaterialApp(home: RagInspectorPage(controller: controller)),
        );
        final button = find.text('Открыть цитату в источнике');
        await tester.scrollUntilVisible(
          button,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.text('Источник и точная цитата'), findsOneWidget);
        if (tampered) {
          expect(
            find.text('Сохранённая цитата не совпадает с ревизией источника.'),
            findsOneWidget,
          );
          expect(find.text('Чанк целиком с подсветкой'), findsNothing);
        } else {
          expect(find.text(RagGroundingFixture.quote), findsOneWidget);
          final expand = find.text('Чанк целиком с подсветкой');
          await tester.scrollUntilVisible(
            expand,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(expand);
          await tester.pumpAndSettle();
          final rich = tester
              .widgetList<SelectableText>(find.byType(SelectableText))
              .singleWhere((w) => w.textSpan != null);
          final span = rich.textSpan!.children![1] as TextSpan;
          expect(span.text, RagGroundingFixture.quote);
          expect(span.style!.backgroundColor, isNotNull);
          expect(rich.textSpan!.toPlainText(), f.chunk.text);
        }
      },
    );
  }
}
