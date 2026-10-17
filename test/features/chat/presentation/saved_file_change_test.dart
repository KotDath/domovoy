import 'dart:convert';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/presentation/timeline_parts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'actual tool change remains inspectable beside arguments/results on mobile and desktop',
    (tester) async {
      for (final size in [const Size(390, 800), const Size(1400, 900)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        final result = jsonEncode({
          'path': 'docs/note.md',
          'change': {
            'path': 'docs/note.md',
            'kind': 'modified',
            'before': 'exact old\r\n',
            'after': 'exact new\r\n',
          },
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: DomovoyTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ChatTimelinePart(
                  key: ValueKey(size),
                  item: ChatToolItem(
                    key: 'tool',
                    callId: ToolCallId('save'),
                    name: 'edit',
                    arguments: '{"path":"docs/note.md"}',
                    displayArguments: '{"path":"docs/note.md"}',
                    status: ChatToolStatus.succeeded,
                    result: result,
                    displayResult: result,
                  ),
                  reasoningExpanded: false,
                  onReasoningToggle: () {},
                ),
              ),
            ),
          ),
        );
        expect(find.text('Изменён · docs/note.md'), findsOneWidget);
        await tester.tap(find.text('Изменён · docs/note.md'));
        await tester.pumpAndSettle();
        expect(find.text('До'), findsOneWidget);
        expect(find.text('После'), findsOneWidget);
        expect(find.text('exact old\r\n'), findsOneWidget);
        expect(find.text('exact new\r\n'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('tool:disclosure')));
        await tester.pumpAndSettle();
        expect(find.text('Аргументы'), findsOneWidget);
        expect(find.text('Результат'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );

  testWidgets('failed mutation cannot display a saved change card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: Scaffold(
          body: ChatTimelinePart(
            item: ChatToolItem(
              key: 'tool',
              callId: ToolCallId('failed'),
              name: 'write',
              arguments: '{}',
              displayArguments: '{}',
              status: ChatToolStatus.failed,
              result: '{"error":"conflict"}',
              displayResult: 'conflict',
            ),
            reasoningExpanded: false,
            onReasoningToggle: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('Сохранённый результат'), findsNothing);
  });
}
