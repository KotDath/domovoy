import 'dart:async';

final class ChatStreamPacingPolicy {
  const ChatStreamPacingPolicy({
    this.notificationInterval = const Duration(milliseconds: 32),
  });

  final Duration notificationInterval;
}

abstract interface class ChatScheduledNotification {
  void cancel();
}

abstract interface class ChatStreamScheduler {
  ChatScheduledNotification schedule(Duration delay, void Function() callback);
}

final class TimerChatStreamScheduler implements ChatStreamScheduler {
  const TimerChatStreamScheduler();

  @override
  ChatScheduledNotification schedule(
    Duration delay,
    void Function() callback,
  ) => _TimerNotification(Timer(delay, callback));
}

final class _TimerNotification implements ChatScheduledNotification {
  _TimerNotification(this.timer);

  final Timer timer;

  @override
  void cancel() => timer.cancel();
}
