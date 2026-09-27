import 'dart:async';

import '../../core/automation/automation.dart';

/// Wall clock of the running application.
final class SystemAutomationClock implements AutomationClock {
  const SystemAutomationClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  AutomationTimer schedule(Duration delay, void Function() callback) =>
      _SystemAutomationTimer(Timer(delay, callback));
}

final class _SystemAutomationTimer implements AutomationTimer {
  _SystemAutomationTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();

  @override
  bool get isActive => _timer.isActive;
}
