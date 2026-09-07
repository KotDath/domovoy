import 'dart:async';

import 'package:domovoy/core/environment/environment_reader.dart';
import 'package:domovoy/features/prompt/domain/agent.dart';
import 'package:domovoy/features/prompt/presentation/prompt_page.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';
import 'package:domovoy/features/settings/domain/model_settings.dart';
import 'package:domovoy/features/settings/presentation/reasoning_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// Model store whose writes stay pending until [release] is called.
final class GatedModelStore implements DeepSeekModelSettingsStore {
  GatedModelStore(this.value);

  DeepSeekModelSettings? value;
  final Completer<void> _gate = Completer<void>();
  bool _open = false;

  @override
  Future<DeepSeekModelSettings?> read() async => value;

  @override
  Future<void> write(DeepSeekModelSettings settings) async {
    if (!_open) {
      await _gate.future;
    }
    value = settings;
  }

  void release() {
    _open = true;
    if (!_gate.isCompleted) {
      _gate.complete();
    }
  }
}

void main() {
  group('settings persistence race', () {
    testWidgets('dialog cannot be dismissed while reasoning is saving, '
        'and the next request uses the fresh value', (tester) async {
      final agent = ControlledAgent();
      final keyStore = MemoryApiKeyOverrideStore();
      final resolver = ApiKeyResolver(
        overrideStore: keyStore,
        environment: const MapEnvironmentReader({}),
      );
      final modelStore = GatedModelStore(
        const DeepSeekModelSettings(reasoningEnabled: true),
      );
      final reasoning = ReasoningSettings(store: modelStore);
      addTearDown(reasoning.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: PromptPage(
            agent: agent,
            overrideStore: keyStore,
            apiKeyResolver: resolver,
            modelSettingsStore: modelStore,
            reasoningSettings: reasoning,
          ),
        ),
      );
      await tester.pumpAndSettle();

      tester
          .widget<IconButton>(find.byKey(const ValueKey('open-settings')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsOneWidget);

      // Start a reasoning write that stays pending.
      await tester.tap(find.byKey(const ValueKey('reasoning-switch')));
      await tester.pump();

      // Close is disabled while the write is in flight...
      final close = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Закрыть'),
      );
      expect(close.onPressed, isNull);

      // ...tapping it cannot dismiss the dialog...
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await tester.pump();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsOneWidget);

      // ...neither can the system back button...
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsOneWidget);

      // ...nor a barrier tap.
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsOneWidget);

      // Let the write finish, then dismissal works again.
      modelStore.release();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Закрыть'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Закрыть'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reasoning-switch')), findsNothing);

      // The next Day 1 request snapshots the fresh (disabled) value,
      // not the stale pre-dialog one.
      await tester.enterText(
        find.byKey(const ValueKey('prompt-input')),
        'hello',
      );
      await tester.tap(find.byKey(const ValueKey('submit-prompt')));
      await tester.pump();

      expect(agent.inputs, hasLength(1));
      expect(agent.inputs.single.thinking, ThinkingMode.disabled);

      for (final controller in agent.controllers) {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    });
  });
}
