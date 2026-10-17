import 'background_inline.dart'
    if (dart.library.io) 'background_io.dart'
    as platform;

/// Native isolates, inline on web; no Flutter engine dependency.
Future<R> compute<Q, R>(R Function(Q) callback, Q message) =>
    platform.compute(callback, message);
