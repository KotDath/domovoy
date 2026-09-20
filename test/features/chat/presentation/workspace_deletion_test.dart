import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/domain/chat_deletion_intent.dart';
import 'package:domovoy/features/chat/presentation/delete_chat_dialog.dart';
import 'package:domovoy/features/chat/presentation/workspace_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) {
  return MaterialApp(
    theme: DomovoyTheme.light(),
    home: Scaffold(body: child),
  );
}

WorkspaceShell _shell({required VoidCallback onDeleteChat}) {
  return WorkspaceShell(
    chats: const <AgentSessionSummary>[],
    selectedId: null,
    title: 'Текущий чат',
    modelLabel: 'Test model',
    modelLabelFor: (_) => 'Test model',
    body: const SizedBox.expand(),
    composer: const SizedBox(height: 48),
    onNewChat: null,
    onSelectChat: null,
    onOpenSettings: null,
    onDeleteChat: onDeleteChat,
    enabled: true,
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'current chat has a visible delete action on desktop and mobile',
    (tester) async {
      for (final size in <Size>[const Size(1400, 900), const Size(390, 800)]) {
        _setSize(tester, size);
        var deleteCalls = 0;
        await tester.pumpWidget(
          _app(_shell(onDeleteChat: () => deleteCalls += 1)),
        );

        final delete = find.byKey(const ValueKey('chat-delete'));
        expect(delete, findsOneWidget);
        expect(find.byTooltip('Удалить текущий чат'), findsOneWidget);
        await tester.tap(delete);
        await tester.pump();
        expect(deleteCalls, 1);
      }
    },
  );

  testWidgets('chat deletion confirmation promises to keep user files', (
    tester,
  ) async {
    _setSize(tester, const Size(1400, 900));
    bool? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await showDeleteChatConfirmation(
                context: context,
                intent: ChatDeletionIntent(
                  chatId: AgentSessionId('chat-1'),
                  displayTitle: 'Проверка',
                  token: 'confirmation-1',
                ),
              );
            },
            child: const Text('Открыть'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Созданные и прикреплённые файлы удалены не будут'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('delete-cancel')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
