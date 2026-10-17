import 'dart:isolate';

Future<R> compute<Q, R>(R Function(Q) callback, Q message) =>
    Isolate.run(() => callback(message));
