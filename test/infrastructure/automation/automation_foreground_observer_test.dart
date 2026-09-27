import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/infrastructure/automation/automation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  ({AutomationService service, FakeAutomationClock clock}) build() {
    final repository = InMemoryAutomationRepository();
    final clock = FakeAutomationClock(DateTime.utc(2026, 1, 1, 12));
    final service = AutomationService(
      tasks: repository,
      runs: repository,
      executor: ScriptedAutomationExecutor(),
      timeZones: automationTestZones(),
      clock: clock,
      ids: SequentialAutomationIdGenerator(),
    );
    return (service: service, clock: clock);
  }

  testWidgets('mobile lifecycle pauses timers and resumes on foreground', (
    tester,
  ) async {
    final harness = build();
    await harness.service.start();
    final observer = AutomationForegroundObserver(
      service: harness.service,
      pauseWhenBackgrounded: () => true,
    );
    observer.attach();

    // Transient states (app switcher, notification shade) keep the timers.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    expect(harness.service.isForeground, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(harness.service.isForeground, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(harness.service.isForeground, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(harness.service.isForeground, isTrue);

    observer.detach();
    await harness.service.dispose();
  });

  testWidgets('desktop predicate ignores lifecycle changes', (tester) async {
    final harness = build();
    await harness.service.start();
    final observer = AutomationForegroundObserver(
      service: harness.service,
      pauseWhenBackgrounded: () => false,
    );
    observer.attach();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(harness.service.isForeground, isTrue);

    observer.detach();
    await harness.service.dispose();
  });
}
