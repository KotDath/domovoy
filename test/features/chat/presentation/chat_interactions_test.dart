import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:domovoy/features/chat/presentation/chat_composer.dart';
import 'package:domovoy/features/chat/presentation/chat_timeline.dart';
import 'package:domovoy/features/chat/presentation/model_selector.dart';
import 'package:domovoy/features/chat/presentation/reasoning_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'Enter sends once, Shift+Enter edits, and draft clears on success',
    (tester) async {
      await _setView(tester, const Size(1200, 800));
      final sent = <String>[];
      await tester.pumpWidget(
        _app(
          _composer(
            onSend: (draft) async {
              sent.add(draft);
              return const ChatCommandResult.succeeded();
            },
          ),
        ),
      );
      final field = find.byKey(const ValueKey('chat-composer-field'));
      await tester.tap(field);
      await tester.enterText(field, 'line one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.enterText(field, 'line one\nline two');
      expect(sent, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, <String>['line one\nline two']);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    },
  );

  testWidgets('empty, composing, and duplicate submissions are not admitted', (
    tester,
  ) async {
    await _setView(tester, const Size(1200, 800));
    final gate = Completer<ChatCommandResult>();
    var sends = 0;
    await tester.pumpWidget(
      _app(
        _composer(
          onSend: (_) {
            sends += 1;
            return gate.future;
          },
        ),
      ),
    );
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.tap(field);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 0);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 5),
        composing: TextRange(start: 0, end: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 0);

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(sends, 1);
    gate.complete(const ChatCommandResult.succeeded());
    await tester.pump();
  });

  testWidgets('running composer exposes reachable stop and retains draft', (
    tester,
  ) async {
    await _setView(tester, const Size(1200, 800));
    var stops = 0;
    await tester.pumpWidget(
      _app(
        _composer(
          running: true,
          onStop: () async {
            stops += 1;
            return const ChatCommandResult.succeeded();
          },
        ),
      ),
    );
    expect(find.byKey(const ValueKey('chat-send')), findsNothing);
    final stop = find.byKey(const ValueKey('chat-stop'));
    expect(stop, findsOneWidget);
    expect(
      tester.getSize(stop).height,
      greaterThanOrEqualTo(DomovoyDimensions.minimumTarget),
    );
    await tester.tap(stop);
    await tester.pump();
    expect(stops, 1);
  });

  testWidgets('accepted pending send can be stopped without double stop', (
    tester,
  ) async {
    await _setView(tester, const Size(1200, 800));
    final sendGate = Completer<ChatCommandResult>();
    final stopGate = Completer<ChatCommandResult>();
    var stops = 0;
    Widget composer(bool running) => ChatComposer(
      key: const ValueKey('persistent-composer'),
      providerGroups: _groups(),
      selection: _selection,
      onSend: (_) => sendGate.future,
      onStop: () {
        stops += 1;
        return stopGate.future;
      },
      onSelectionChanged: (_) async => const ChatCommandResult.unchanged(),
      running: running,
      enabled: true,
    );

    await tester.pumpWidget(_app(composer(false)));
    final field = find.byKey(const ValueKey('chat-composer-field'));
    await tester.enterText(field, 'pending');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpWidget(_app(composer(true)));
    await tester.tap(find.byKey(const ValueKey('chat-stop')));
    await tester.tap(find.byKey(const ValueKey('chat-stop')));
    expect(stops, 1);
    stopGate.complete(const ChatCommandResult.succeeded());
    sendGate.complete(const ChatCommandResult.cancelled());
    await tester.pump();
  });

  testWidgets(
    'reasoning disclosures start collapsed and expand independently',
    (tester) async {
      final projection = ChatTimelineProjection(<ChatTimelineItem>[
        const ChatReasoningItem(
          key: 'reasoning-one',
          responseKey: 'response-one',
          text: 'first hidden thought',
        ),
        const ChatReasoningItem(
          key: 'reasoning-two',
          responseKey: 'response-two',
          text: 'second hidden thought',
        ),
      ]);
      await tester.pumpWidget(_app(ChatTimeline(projection: projection)));
      expect(find.text('first hidden thought'), findsNothing);
      expect(find.text('second hidden thought'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('reasoning-one:toggle')));
      await tester.pump();
      expect(find.text('first hidden thought'), findsOneWidget);
      expect(find.text('second hidden thought'), findsNothing);
      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('reasoning-two:toggle')),
      );
      expect(semantics.label, contains('Показать'));
    },
  );

  testWidgets('tool content expands with selectable malformed fallback', (
    tester,
  ) async {
    final projection = ChatTimelineProjection(<ChatTimelineItem>[
      ChatToolItem(
        key: 'tool-card',
        callId: ToolCallId('call'),
        name: 'custom.tool',
        arguments: 'not-json exactly',
        displayArguments: 'not-json exactly',
        status: ChatToolStatus.failed,
        result: 'plain result',
        displayResult: 'plain result',
      ),
    ]);
    await tester.pumpWidget(_app(ChatTimeline(projection: projection)));
    expect(find.text('not-json exactly'), findsNothing);
    await tester.tap(find.text('custom.tool'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data == 'not-json exactly',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) => widget is SelectableText && widget.data == 'plain result',
      ),
      findsOneWidget,
    );
    expect(find.text('Ошибка'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('not-json exactly'), findsNothing);
  });

  testWidgets(
    'configuration error offers settings and live status is bounded',
    (tester) async {
      var settings = 0;
      final projection = ChatTimelineProjection(<ChatTimelineItem>[
        const ChatErrorItem(
          key: 'configuration-error',
          kind: ChatTimelineErrorKind.failed,
          message: 'Проверьте модель и настройки.',
          offersSettings: true,
        ),
      ]);
      await tester.pumpWidget(
        _app(
          ChatTimeline(
            projection: projection,
            announcement: 'Не удалось завершить ответ',
            onOpenSettings: () => settings += 1,
          ),
        ),
      );
      final status = tester.getSemantics(
        find.byKey(const ValueKey('chat-live-status')),
      );
      expect(status.label, 'Не удалось завершить ответ');
      await tester.tap(find.byKey(const ValueKey('timeline-open-settings')));
      expect(settings, 1);
    },
  );

  testWidgets(
    'desktop model menu renders registry and custom provider groups',
    (tester) async {
      await _setView(tester, const Size(1200, 800));
      final customModel = _model(
        provider: 'custom-provider',
        id: 'custom-model',
        reasoning: ModelReasoningCapability.unsupported,
      );
      final groups = <LlmProviderGroup>[
        ..._groups(),
        LlmProviderGroup(
          providerId: customModel.providerId,
          displayName: 'Custom Local',
          models: <LlmModel>[customModel],
        ),
      ];
      AgentSessionSelection? selected;
      await tester.pumpWidget(
        _app(
          ChatModelSelector(
            groups: groups,
            selection: _selection,
            onSelected: (value) => selected = value,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('model-selector')));
      await tester.pumpAndSettle();
      expect(find.text('Custom Local'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('model-option:custom-provider:custom-model')),
      );
      await tester.pump();
      expect(selected!.model, customModel.ref);
      expect(selected!.reasoningMode, ReasoningMode.disabled);
      expect(selected!.reasoningEffort, ReasoningEffort.modelDefault);
    },
  );

  testWidgets('narrow selectors use sheets and return focus to trigger', (
    tester,
  ) async {
    await _setView(tester, const Size(390, 844), textScale: 2);
    await tester.pumpWidget(
      _app(
        ChatModelSelector(
          groups: _groups(),
          selection: _selection,
          onSelected: (_) {},
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('model-selector')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-selector-sheet')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-selector-sheet')), findsNothing);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'model-selector');
    expect(tester.takeException(), isNull);
  });

  test('reasoning choices exactly follow every built-in capability', () {
    for (final group in _groups()) {
      for (final model in group.models) {
        final choices = reasoningChoicesFor(model);
        expect(choices, isNotEmpty);
        switch (model.capabilities.reasoning) {
          case ModelReasoningCapability.unsupported:
            expect(choices, hasLength(1));
            expect(choices.single.mode, ReasoningMode.disabled);
          case ModelReasoningCapability.optional:
            expect(
              choices.where((choice) => choice.mode == ReasoningMode.disabled),
              hasLength(1),
            );
            expect(
              choices.where((choice) => choice.mode == ReasoningMode.enabled),
              hasLength(model.capabilities.selectableEfforts.length + 1),
            );
          case ModelReasoningCapability.required:
            expect(
              choices.every((choice) => choice.mode == ReasoningMode.enabled),
              isTrue,
            );
            expect(
              choices,
              hasLength(model.capabilities.selectableEfforts.length + 1),
            );
        }
        expect(
          choices
              .where((choice) => choice.effort.isExplicit)
              .map((choice) => choice.effort),
          model.capabilities.selectableEfforts,
        );
      }
    }
  });
}

Widget _composer({
  Future<ChatCommandResult> Function(String)? onSend,
  Future<ChatCommandResult> Function()? onStop,
  bool running = false,
}) => ChatComposer(
  providerGroups: _groups(),
  selection: _selection,
  onSend: onSend ?? (_) async => const ChatCommandResult.succeeded(),
  onStop: onStop ?? () async => const ChatCommandResult.succeeded(),
  onSelectionChanged: (_) async => const ChatCommandResult.unchanged(),
  running: running,
  enabled: true,
);

Widget _app(Widget child) => MaterialApp(
  theme: DomovoyTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

List<LlmProviderGroup> _groups() {
  final registry = LlmProviderRegistry();
  BuiltInLlmCatalog.registerInto(registry);
  return registry.providerGroups;
}

AgentSessionSelection get _selection => AgentSessionSelection(
  model: BuiltInLlmCatalog.gpt54Model.ref,
  reasoningMode: ReasoningMode.enabled,
  reasoningEffort: ReasoningEffort.high,
);

LlmModel _model({
  required String provider,
  required String id,
  required ModelReasoningCapability reasoning,
}) => LlmModel(
  providerId: ProviderId(provider),
  id: ModelId(id),
  name: 'Custom Model',
  wireFamily: LlmWireFamily.openaiChatCompletions,
  capabilities: ModelCapabilities(
    supportsTextInput: true,
    reasoning: reasoning,
    supportsTools: true,
  ),
  contextBound: 1000,
  outputBound: 100,
);

Future<void> _setView(
  WidgetTester tester,
  Size size, {
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}
