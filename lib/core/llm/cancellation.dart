import 'dart:async';

abstract interface class CancellationRegistration {
  void dispose();
}

abstract interface class CancellationToken {
  bool get isCancelled;

  Future<void> get whenCancelled;

  CancellationRegistration register(void Function() callback);
}

final class CancellationSource {
  CancellationSource();

  final _CancellationToken _token = _CancellationToken();

  CancellationToken get token => _token;

  int get registrationCount => _token._registrationCount;

  void cancel() => _token._cancel();
}

final class _InertCancellationRegistration implements CancellationRegistration {
  const _InertCancellationRegistration();

  @override
  void dispose() {}
}

final class _CancellationRegistration implements CancellationRegistration {
  _CancellationRegistration(this._owner, this._callback);

  _CancellationToken? _owner;
  void Function()? _callback;
  var _disposed = false;

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _owner?._remove(this);
    _owner = null;
    _callback = null;
  }

  void _fire() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final callback = _callback;
    _owner = null;
    _callback = null;
    callback?.call();
  }
}

final class _CancellationToken implements CancellationToken {
  final List<_CancellationRegistration> _registrations =
      <_CancellationRegistration>[];
  Completer<void>? _whenCancelled;
  var _cancelled = false;

  int get _registrationCount => _registrations.length;

  @override
  bool get isCancelled => _cancelled;

  @override
  Future<void> get whenCancelled {
    if (_cancelled) {
      return Future<void>.value();
    }
    return (_whenCancelled ??= Completer<void>()).future;
  }

  @override
  CancellationRegistration register(void Function() callback) {
    if (_cancelled) {
      callback();
      return const _InertCancellationRegistration();
    }
    final registration = _CancellationRegistration(this, callback);
    _registrations.add(registration);
    if (_cancelled) {
      _registrations.remove(registration);
      registration._fire();
      return const _InertCancellationRegistration();
    }
    return registration;
  }

  void _remove(_CancellationRegistration registration) {
    _registrations.remove(registration);
  }

  void _cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    final pending = List<_CancellationRegistration>.from(_registrations);
    _registrations.clear();
    final waiter = _whenCancelled;
    _whenCancelled = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
    for (final registration in pending) {
      registration._fire();
    }
  }
}
