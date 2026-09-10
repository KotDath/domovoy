import 'dart:async';

abstract interface class AgentClock {
  int nowMicros();

  Duration get elapsed;

  AgentTimer schedule(Duration delay, void Function() callback);
}

abstract interface class AgentTimer {
  void cancel();
}

final class SystemAgentClock implements AgentClock {
  SystemAgentClock() : _watch = Stopwatch()..start();

  final Stopwatch _watch;

  @override
  int nowMicros() => DateTime.now().microsecondsSinceEpoch;

  @override
  Duration get elapsed => _watch.elapsed;

  @override
  AgentTimer schedule(Duration delay, void Function() callback) {
    return _SystemTimer(Timer(delay, callback));
  }
}

final class _SystemTimer implements AgentTimer {
  _SystemTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

final class FakeAgentClock implements AgentClock {
  FakeAgentClock({int startMicros = 0}) : _nowMicros = startMicros;

  int _nowMicros;
  Duration _elapsed = Duration.zero;
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  @override
  int nowMicros() => _nowMicros;

  @override
  Duration get elapsed => _elapsed;

  @override
  AgentTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer(due: _elapsed + delay, callback: callback);
    _timers.add(timer);
    return timer;
  }

  void elapse(Duration duration) {
    _elapsed += duration;
    _nowMicros += duration.inMicroseconds;
    final due =
        _timers
            .where((timer) => !timer.cancelled && timer.due <= _elapsed)
            .toList()
          ..sort((a, b) => a.due.compareTo(b.due));
    for (final timer in due) {
      if (timer.cancelled) {
        continue;
      }
      timer.cancelled = true;
      timer.callback();
    }
    _timers.removeWhere((timer) => timer.cancelled || timer.due <= _elapsed);
  }
}

final class _FakeTimer implements AgentTimer {
  _FakeTimer({required this.due, required this.callback});

  final Duration due;
  final void Function() callback;
  var cancelled = false;

  @override
  void cancel() {
    cancelled = true;
  }
}

final class AgentIdFactory {
  AgentIdFactory({String prefix = 'id'}) : _prefix = prefix;

  final String _prefix;
  var _n = 0;

  String next([String? kind]) {
    _n += 1;
    return '${kind ?? _prefix}-$_n';
  }
}
