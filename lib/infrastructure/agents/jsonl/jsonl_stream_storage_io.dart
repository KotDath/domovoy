import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'jsonl_stream_storage.dart';

typedef JsonlApplicationSupportDirectoryResolver = Future<Directory> Function();

enum JsonlFilesystemStage {
  beforeGenerationFlush,
  beforePointerPublication,
  beforeCleanup,
}

typedef JsonlFilesystemStageHook =
    FutureOr<void> Function(JsonlFilesystemStage stage, String key);

JsonlStreamStorage createPlatformJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
  );
}

/// Native atomic-generation implementation of [JsonlStreamStorage].
///
/// One instance serializes its own filesystem operations. As specified by the
/// repository contract, coordination between processes or independently
/// constructed concurrent writers is intentionally unsupported.
final class JsonlFilesystemStreamStorage implements JsonlStreamStorage {
  JsonlFilesystemStreamStorage({
    required this.applicationSupportDirectoryResolver,
    this.stageHook,
    this.namespaceDirectoryName = storageDirectoryName,
  }) {
    if (!_namespaceDirectoryPattern.hasMatch(namespaceDirectoryName)) {
      throw ArgumentError.value(
        namespaceDirectoryName,
        'namespaceDirectoryName',
        'invalid storage directory name',
      );
    }
  }

  static const applicationDirectoryName = 'ru.kotdath.domovoy';
  static const storageDirectoryName = 'agent-sessions-jsonl-v1';
  static const projectStorageDirectoryName = 'project-workspaces-jsonl-v1';
  static final RegExp _namespaceDirectoryPattern = RegExp(
    r'^[A-Za-z0-9._-]{1,64}$',
  );
  static const activeManifestName = 'active';
  static const _manifestType = 'domovoy.jsonl.active_generation';
  static const _manifestVersion = 1;
  static const _maxManifestBytes = 2048;

  static final RegExp _keyPattern = RegExp(r'^[A-Za-z0-9_-]{1,512}$');
  static final RegExp _generationPattern = RegExp(
    r'^generation-[a-f0-9]{32}\.jsonl$',
  );
  static final RegExp _temporaryGenerationPattern = RegExp(
    r'^\.generation-[a-f0-9]{32}\.tmp$',
  );
  static final RegExp _temporaryManifestPattern = RegExp(
    r'^\.active-[a-f0-9]{32}\.tmp$',
  );

  final JsonlApplicationSupportDirectoryResolver
  applicationSupportDirectoryResolver;
  final JsonlFilesystemStageHook? stageHook;
  final String namespaceDirectoryName;
  final Random _random = Random.secure();
  final _FilesystemSerialExecutor _executor = _FilesystemSerialExecutor();
  Future<Directory>? _rootFuture;

  @override
  Future<void> cleanup(String key) {
    return _executor.run(() async {
      _validateKey(key);
      final root = await _root();
      final namespace = await _namespace(root, key, create: false);
      if (namespace == null) {
        return;
      }
      final manifest = await _readManifest(namespace, key);
      final activeGeneration = manifest?.generation;
      await for (final entity in namespace.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == activeManifestName || name == activeGeneration) {
          continue;
        }
        if (!_generationPattern.hasMatch(name) &&
            !_temporaryGenerationPattern.hasMatch(name) &&
            !_temporaryManifestPattern.hasMatch(name)) {
          continue;
        }
        await _runStage(JsonlFilesystemStage.beforeCleanup, key);
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          throw const FileSystemException(
            'Unexpected directory in JSONL namespace.',
          );
        }
        await entity.delete();
      }
      if (manifest == null && await namespace.list().isEmpty) {
        await namespace.delete();
      }
    });
  }

  @override
  Future<List<String>> listKeys() {
    return _executor.run(() async {
      final root = await _root();
      final keys = <String>[];
      await for (final entity in root.list(followLinks: false)) {
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory ||
            type == FileSystemEntityType.link) {
          keys.add(p.basename(entity.path));
        }
      }
      keys.sort();
      return List<String>.unmodifiable(keys);
    });
  }

  @override
  Future<void> publish(String key, List<int> contents) {
    final immutableContents = Uint8List.fromList(contents);
    return _executor.run(() async {
      _validateKey(key);
      final root = await _root();
      final namespace = (await _namespace(root, key, create: true))!;
      final token = await _newToken(namespace);
      final generationName = 'generation-$token.jsonl';
      final generationTemporary = File(
        p.join(namespace.path, '.generation-$token.tmp'),
      );
      final generation = File(p.join(namespace.path, generationName));

      await _writeFlushed(
        generationTemporary,
        immutableContents,
        beforeFlush: () =>
            _runStage(JsonlFilesystemStage.beforeGenerationFlush, key),
      );
      await generationTemporary.rename(generation.path);

      await _runStage(JsonlFilesystemStage.beforePointerPublication, key);
      final manifestTemporary = File(
        p.join(namespace.path, '.active-$token.tmp'),
      );
      final manifest = utf8.encode(
        '${jsonEncode(<String, Object?>{'type': _manifestType, 'version': _manifestVersion, 'key': key, 'generation': generationName})}\n',
      );
      await _writeFlushed(manifestTemporary, manifest);
      await manifestTemporary.rename(
        p.join(namespace.path, activeManifestName),
      );
    });
  }

  @override
  Future<Stream<List<int>>?> read(String key) {
    return _executor.run(() async {
      _validateKey(key);
      final root = await _root();
      final namespace = await _namespace(root, key, create: false);
      if (namespace == null) {
        return null;
      }
      final manifest = await _readManifest(namespace, key);
      if (manifest == null) {
        return null;
      }
      final generation = File(p.join(namespace.path, manifest.generation));
      final type = await FileSystemEntity.type(
        generation.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.file) {
        throw const FileSystemException(
          'Active JSONL generation is unavailable.',
        );
      }
      return generation.openRead();
    });
  }

  Future<Directory> _root() {
    return _rootFuture ??= _initializeRoot();
  }

  Future<Directory> _initializeRoot() async {
    final applicationSupport =
        (await applicationSupportDirectoryResolver()).absolute;
    final root = Directory(
      p.join(
        applicationSupport.path,
        applicationDirectoryName,
        namespaceDirectoryName,
      ),
    );
    await root.create(recursive: true);
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException('JSONL storage root is not a directory.');
    }
    return root;
  }

  Future<Directory?> _namespace(
    Directory root,
    String key, {
    required bool create,
  }) async {
    final directory = Directory(p.join(root.path, key));
    var type = await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.notFound && create) {
      await directory.create();
      type = await FileSystemEntity.type(directory.path, followLinks: false);
    }
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    if (type != FileSystemEntityType.directory) {
      throw const FileSystemException(
        'JSONL stream namespace is not a directory.',
      );
    }
    return directory;
  }

  Future<_ActiveManifest?> _readManifest(
    Directory namespace,
    String expectedKey,
  ) async {
    final file = File(p.join(namespace.path, activeManifestName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('JSONL active manifest is not a file.');
    }
    final length = await file.length();
    if (length <= 0 || length > _maxManifestBytes) {
      throw const FormatException('Invalid JSONL active manifest length.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > _maxManifestBytes) {
      throw const FormatException('Invalid JSONL active manifest length.');
    }
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      if (!text.endsWith('\n') || text.indexOf('\n') != text.length - 1) {
        throw const FormatException('Invalid JSONL active manifest framing.');
      }
      final value = jsonDecode(text.substring(0, text.length - 1));
      if (value is! Map) {
        throw const FormatException('Invalid JSONL active manifest.');
      }
      final map = Map<String, Object?>.from(value);
      const expectedFields = <String>{'type', 'version', 'key', 'generation'};
      if (map.length != expectedFields.length ||
          !map.keys.every(expectedFields.contains) ||
          map['type'] != _manifestType ||
          map['version'] != _manifestVersion ||
          map['key'] != expectedKey ||
          map['generation'] is! String) {
        throw const FormatException('Invalid JSONL active manifest fields.');
      }
      final generation = map['generation']! as String;
      if (!_generationPattern.hasMatch(generation)) {
        throw const FormatException('Invalid JSONL generation name.');
      }
      return _ActiveManifest(generation);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Invalid JSONL active manifest.');
    }
  }

  Future<String> _newToken(Directory namespace) async {
    for (var attempt = 0; attempt < 32; attempt += 1) {
      final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
      final token = bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join();
      final generation = File(
        p.join(namespace.path, 'generation-$token.jsonl'),
      );
      final temporary = File(p.join(namespace.path, '.generation-$token.tmp'));
      if (!await generation.exists() && !await temporary.exists()) {
        return token;
      }
    }
    throw const FileSystemException(
      'Unable to allocate a JSONL generation name.',
    );
  }

  Future<void> _writeFlushed(
    File file,
    List<int> contents, {
    FutureOr<void> Function()? beforeFlush,
  }) async {
    final handle = await file.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(contents);
      await beforeFlush?.call();
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<void> _runStage(JsonlFilesystemStage stage, String key) async {
    await stageHook?.call(stage, key);
  }

  static void _validateKey(String key) {
    if (!_keyPattern.hasMatch(key)) {
      throw const FormatException('Invalid opaque JSONL stream key.');
    }
  }
}

final class _ActiveManifest {
  const _ActiveManifest(this.generation);

  final String generation;
}

final class _FilesystemSerialExecutor {
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
