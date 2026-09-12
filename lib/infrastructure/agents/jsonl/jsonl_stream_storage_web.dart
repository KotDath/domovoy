import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'jsonl_stream_storage.dart';

enum JsonlBrowserStage { beforePointerPublication, beforeCleanup }

typedef JsonlBrowserStageHook =
    FutureOr<void> Function(JsonlBrowserStage stage, String key);

/// The uncached asynchronous preferences operations used by browser storage.
abstract interface class JsonlBrowserPreferences {
  Future<Set<String>> getKeys();

  Future<String?> getString(String key);

  Future<void> setString(String key, String value);

  Future<void> remove(String key);
}

/// [SharedPreferencesAsync] deliberately bypasses the legacy process cache.
final class SharedPreferencesJsonlBrowserPreferences
    implements JsonlBrowserPreferences {
  SharedPreferencesJsonlBrowserPreferences([SharedPreferencesAsync? delegate])
    : _delegate = delegate;

  SharedPreferencesAsync? _delegate;

  SharedPreferencesAsync get _resolved {
    return _delegate ??= SharedPreferencesAsync();
  }

  @override
  Future<Set<String>> getKeys() => _resolved.getKeys();

  @override
  Future<String?> getString(String key) => _resolved.getString(key);

  @override
  Future<void> remove(String key) => _resolved.remove(key);

  @override
  Future<void> setString(String key, String value) {
    return _resolved.setString(key, value);
  }
}

JsonlStreamStorage createPlatformJsonlStreamStorage() {
  return JsonlBrowserStreamStorage();
}

/// Browser implementation backed by durable origin-local preferences.
///
/// Every complete JSONL value is written under a new immutable generation key.
/// Publishing that generation's name to the active-pointer key is the commit
/// point. No process-memory value is retained or used as a fallback.
final class JsonlBrowserStreamStorage implements JsonlStreamStorage {
  JsonlBrowserStreamStorage({
    JsonlBrowserPreferences? preferences,
    this.namespace = defaultNamespace,
    this.maxStreamBytes = defaultMaxStreamBytes,
    this.stageHook,
  }) : preferences = preferences ?? SharedPreferencesJsonlBrowserPreferences() {
    if (!_namespacePattern.hasMatch(namespace)) {
      throw ArgumentError.value(namespace, 'namespace', 'invalid namespace');
    }
    if (maxStreamBytes <= 0) {
      throw ArgumentError.value(
        maxStreamBytes,
        'maxStreamBytes',
        'must be positive',
      );
    }
  }

  static const defaultNamespace = 'ru.kotdath.domovoy.agent-sessions-jsonl-v1';
  static const defaultMaxStreamBytes = 256 * 1024 * 1024;

  static final RegExp _namespacePattern = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$',
  );
  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_-]{1,512}$');
  static final RegExp _tokenPattern = RegExp(r'^[a-f0-9]{32}$');

  final JsonlBrowserPreferences preferences;
  final String namespace;
  final int maxStreamBytes;
  final JsonlBrowserStageHook? stageHook;
  final Random _random = Random.secure();
  final _BrowserSerialExecutor _executor = _BrowserSerialExecutor();

  String get _streamPrefix => '$namespace.stream.';

  @override
  Future<void> cleanup(String key) {
    return _executor.run(() async {
      _validateKey(key);
      final active = await preferences.getString(_activeKey(key));
      final generationPrefix = _generationPrefix(key);
      final keys = await preferences.getKeys();
      final obsolete =
          keys
              .where(
                (candidate) =>
                    candidate.startsWith(generationPrefix) &&
                    candidate != active,
              )
              .toList()
            ..sort();
      for (final candidate in obsolete) {
        await _runStage(JsonlBrowserStage.beforeCleanup, key);
        await preferences.remove(candidate);
      }
    });
  }

  @override
  Future<List<String>> listKeys() {
    return _executor.run(() async {
      final suffix = '.active';
      final keys = <String>[];
      for (final candidate in await preferences.getKeys()) {
        if (!candidate.startsWith(_streamPrefix) ||
            !candidate.endsWith(suffix)) {
          continue;
        }
        final key = candidate.substring(
          _streamPrefix.length,
          candidate.length - suffix.length,
        );
        if (key.isNotEmpty && !key.contains('.')) {
          keys.add(key);
        }
      }
      keys.sort();
      return List<String>.unmodifiable(keys);
    });
  }

  @override
  Future<void> publish(String key, List<int> contents) {
    _validateKey(key);
    final immutableContents = Uint8List.fromList(contents);
    if (immutableContents.length > maxStreamBytes) {
      throw StateError('JSONL browser stream exceeds its configured bound.');
    }
    final text = utf8.decode(immutableContents, allowMalformed: false);
    return _executor.run(() async {
      final generation = await _newGenerationKey(key);
      await preferences.setString(generation, text);
      await _runStage(JsonlBrowserStage.beforePointerPublication, key);
      await preferences.setString(_activeKey(key), generation);
    });
  }

  @override
  Future<Stream<List<int>>?> read(String key) {
    return _executor.run(() async {
      _validateKey(key);
      final active = await preferences.getString(_activeKey(key));
      if (active == null) {
        return null;
      }
      if (!_isGenerationKeyFor(active, key)) {
        throw const FormatException('Invalid JSONL browser active pointer.');
      }
      final text = await preferences.getString(active);
      if (text == null) {
        throw StateError('Active JSONL browser generation is unavailable.');
      }
      if (text.length > maxStreamBytes) {
        throw StateError('JSONL browser stream exceeds its configured bound.');
      }
      final bytes = Uint8List.fromList(utf8.encode(text));
      if (bytes.length > maxStreamBytes) {
        throw StateError('JSONL browser stream exceeds its configured bound.');
      }
      return Stream<List<int>>.value(bytes);
    });
  }

  String _activeKey(String key) => '$_streamPrefix$key.active';

  String _generationPrefix(String key) => '$_streamPrefix$key.generation.';

  bool _isGenerationKeyFor(String candidate, String key) {
    final prefix = _generationPrefix(key);
    return candidate.startsWith(prefix) &&
        _tokenPattern.hasMatch(candidate.substring(prefix.length));
  }

  Future<String> _newGenerationKey(String key) async {
    for (var attempt = 0; attempt < 32; attempt += 1) {
      final token = List<int>.generate(
        16,
        (_) => _random.nextInt(256),
      ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
      final candidate = '${_generationPrefix(key)}$token';
      final keys = await preferences.getKeys();
      if (!keys.contains(candidate)) {
        return candidate;
      }
    }
    throw StateError('Unable to allocate a JSONL browser generation.');
  }

  Future<void> _runStage(JsonlBrowserStage stage, String key) async {
    await stageHook?.call(stage, key);
  }

  static void _validateKey(String key) {
    if (!_keyPattern.hasMatch(key)) {
      throw const FormatException('Invalid opaque JSONL stream key.');
    }
  }
}

final class _BrowserSerialExecutor {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final predecessor = _tail;
    final released = Completer<void>();
    _tail = released.future;
    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        released.complete();
      }
    }();
  }
}
