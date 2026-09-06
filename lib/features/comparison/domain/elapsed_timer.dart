abstract interface class ElapsedClock {
  Duration elapsed();
}

final class StopwatchElapsedClock implements ElapsedClock {
  StopwatchElapsedClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  Duration elapsed() => _stopwatch.elapsed;
}

typedef ElapsedClockFactory = ElapsedClock Function();
