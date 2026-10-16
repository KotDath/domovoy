Future<R> compute<Q, R>(R Function(Q) callback, Q message) async =>
    callback(message);
