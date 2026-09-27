/// Wall clock and timer boundary of the automation scheduler.
///
/// All instants are UTC. Tests use a fake clock so `*/5`, DST, month edges and
/// missed periods run deterministically without waiting for real time.
abstract interface class AutomationClock {
  DateTime nowUtc();

  AutomationTimer schedule(Duration delay, void Function() callback);
}

abstract interface class AutomationTimer {
  void cancel();

  bool get isActive;
}
