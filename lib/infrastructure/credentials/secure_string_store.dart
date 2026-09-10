import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecureStringStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class MemorySecureStringStore implements SecureStringStore {
  MemorySecureStringStore([Map<String, String>? initial])
    : _values = Map<String, String>.from(initial ?? const <String, String>{});

  final Map<String, String> _values;

  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

final class FlutterSecureStringStore implements SecureStringStore {
  FlutterSecureStringStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
