import 'dart:async';
import 'dart:convert';

import '../../../core/llm/cancellation.dart';
import '../../../core/personalization/personalization.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';

final class ProfileJsonlKeyCodec {
  const ProfileJsonlKeyCodec();

  static const prefix = 'profile-v1_';
  static const activeKey = '${prefix}active';

  String profile(ProfileId id) => '$prefix${id.value}';

  ProfileId? tryProfile(String key) {
    if (!key.startsWith(prefix) || key == activeKey) return null;
    try {
      return ProfileId(key.substring(prefix.length));
    } on Object {
      return null;
    }
  }
}

final class JsonlProfileRepository
    implements ProfileRepository, ActiveProfileRepository {
  JsonlProfileRepository({
    required this.storage,
    this.keys = const ProfileJsonlKeyCodec(),
  });

  static const _operationType = 'domovoy.personalization_operation';
  static const _selectionType = 'domovoy.personalization_selection';
  static const _version = 1;
  static const _maxStreamBytes = 2 * 1024 * 1024;

  final JsonlStreamStorage storage;
  final ProfileJsonlKeyCodec keys;
  Future<void> _tail = Future<void>.value();

  @override
  Future<List<AssistantProfile>> list({
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    final storageKeys = await _safeListKeys();
    final result = <AssistantProfile>[];
    for (final key in storageKeys) {
      final id = keys.tryProfile(key);
      if (id == null) continue;
      final replay = await _readProfile(key, id);
      if (replay.profile != null) result.add(replay.profile!);
    }
    result.sort((left, right) => left.name.compareTo(right.name));
    return List<AssistantProfile>.unmodifiable(result);
  });

  @override
  Future<AssistantProfile?> load(
    ProfileId id, {
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    return (await _readProfile(keys.profile(id), id)).profile;
  });

  @override
  Future<void> save(
    AssistantProfile profile, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    final key = keys.profile(profile.id);
    final replay = await _readProfile(key, profile.id);
    final existing = replay.profile;
    if (existing == null) {
      if (expectedRevision != 0 || profile.revision != 0) _conflict();
    } else if (existing.revision != expectedRevision ||
        profile.revision != expectedRevision + 1) {
      _conflict();
    }
    final line = _encode(<String, Object?>{
      'type': _operationType,
      'version': _version,
      'recordId': profile.id.value,
      'sequence': replay.nextSequence,
      'operation': 'upsert',
      'expectedRevision': expectedRevision,
      'recordRevision': profile.revision,
      'record': profile.toJson(),
    });
    await _publish(key, <int>[...replay.validPrefix, ...line]);
  });

  @override
  Future<void> delete(
    ProfileId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    final key = keys.profile(id);
    final replay = await _readProfile(key, id);
    final existing = replay.profile;
    if (existing == null || existing.revision != expectedRevision) _conflict();
    final line = _encode(<String, Object?>{
      'type': _operationType,
      'version': _version,
      'recordId': id.value,
      'sequence': replay.nextSequence,
      'operation': 'delete',
      'expectedRevision': expectedRevision,
      'recordRevision': expectedRevision,
    });
    await _publish(key, <int>[...replay.validPrefix, ...line]);
  });

  @override
  Future<ActiveProfileSelection?> loadActive({
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    return (await _readSelection()).selection;
  });

  @override
  Future<void> saveActive(
    ActiveProfileSelection selection, {
    required int expectedRevision,
    required CancellationToken cancellation,
  }) => _serial(() async {
    _throwIfCancelled(cancellation);
    final replay = await _readSelection();
    final existing = replay.selection;
    if (existing == null) {
      if (expectedRevision != 0 || selection.revision != 0) _conflict();
    } else if (existing.revision != expectedRevision ||
        selection.revision != expectedRevision + 1) {
      _conflict();
    }
    final line = _encode(<String, Object?>{
      'type': _selectionType,
      'version': _version,
      'sequence': replay.nextSequence,
      'expectedRevision': expectedRevision,
      'revision': selection.revision,
      'profileId': selection.profileId.value,
    });
    await _publish(ProfileJsonlKeyCodec.activeKey, <int>[
      ...replay.validPrefix,
      ...line,
    ]);
  });

  Future<_ProfileReplay> _readProfile(String key, ProfileId id) async {
    final bytes = await _safeRead(key);
    if (bytes == null) return const _ProfileReplay();
    final decoded = _decodeLines(bytes);
    AssistantProfile? current;
    var sequence = -1;
    for (final map in decoded.lines) {
      if (map['type'] != _operationType ||
          map['version'] != _version ||
          map['recordId'] != id.value ||
          map['sequence'] is! int ||
          map['expectedRevision'] is! int ||
          map['recordRevision'] is! int) {
        _persistence();
      }
      final nextSequence = map['sequence']! as int;
      if (nextSequence != sequence + 1) _persistence();
      sequence = nextSequence;
      final expected = map['expectedRevision']! as int;
      final recordRevision = map['recordRevision']! as int;
      switch (map['operation']) {
        case 'upsert':
          final decodedProfile = AssistantProfile.fromJson(map['record']);
          if (decodedProfile.id != id ||
              decodedProfile.revision != recordRevision ||
              (current == null
                  ? expected != 0 || recordRevision != 0
                  : expected != current.revision ||
                        recordRevision != current.revision + 1)) {
            _persistence();
          }
          current = decodedProfile;
        case 'delete':
          if (current == null ||
              current.revision != expected ||
              recordRevision != expected) {
            _persistence();
          }
          current = null;
        default:
          _persistence();
      }
    }
    return _ProfileReplay(
      profile: current,
      nextSequence: sequence + 1,
      validPrefix: decoded.validPrefix,
    );
  }

  Future<_SelectionReplay> _readSelection() async {
    final bytes = await _safeRead(ProfileJsonlKeyCodec.activeKey);
    if (bytes == null) return const _SelectionReplay();
    final decoded = _decodeLines(bytes);
    ActiveProfileSelection? current;
    var sequence = -1;
    for (final map in decoded.lines) {
      if (map['type'] != _selectionType ||
          map['version'] != _version ||
          map['sequence'] is! int ||
          map['expectedRevision'] is! int ||
          map['revision'] is! int ||
          map['profileId'] is! String) {
        _persistence();
      }
      final nextSequence = map['sequence']! as int;
      final expected = map['expectedRevision']! as int;
      final revision = map['revision']! as int;
      if (nextSequence != sequence + 1 ||
          (current == null
              ? expected != 0 || revision != 0
              : expected != current.revision || revision != expected + 1)) {
        _persistence();
      }
      sequence = nextSequence;
      current = ActiveProfileSelection(
        profileId: ProfileId(map['profileId']! as String),
        revision: revision,
      );
    }
    return _SelectionReplay(
      selection: current,
      nextSequence: sequence + 1,
      validPrefix: decoded.validPrefix,
    );
  }

  _DecodedLines _decodeLines(List<int> bytes) {
    try {
      final text = utf8.decode(bytes);
      final lastNewline = text.lastIndexOf('\n');
      if (lastNewline < 0) return const _DecodedLines();
      final prefix = text.substring(0, lastNewline + 1);
      final lines = <Map<String, Object?>>[];
      for (final raw in prefix.split('\n')) {
        if (raw.isEmpty) continue;
        final value = jsonDecode(raw);
        if (value is! Map) _persistence();
        lines.add(value.cast<String, Object?>());
      }
      return _DecodedLines(lines: lines, validPrefix: utf8.encode(prefix));
    } on PersonalizationException {
      rethrow;
    } on Object {
      _persistence();
    }
  }

  List<int> _encode(Map<String, Object?> value) =>
      utf8.encode('${jsonEncode(value)}\n');

  Future<List<int>?> _safeRead(String key) async {
    try {
      final chunks = await storage.read(key);
      if (chunks == null) return null;
      final bytes = <int>[];
      await for (final chunk in chunks) {
        bytes.addAll(chunk);
        if (bytes.length > _maxStreamBytes) _persistence();
      }
      return bytes;
    } on PersonalizationException {
      rethrow;
    } on Object {
      _persistence();
    }
  }

  Future<List<String>> _safeListKeys() async {
    try {
      return await storage.listKeys();
    } on Object {
      _persistence();
    }
  }

  Future<void> _publish(String key, List<int> bytes) async {
    if (bytes.length > _maxStreamBytes) _persistence();
    try {
      await storage.publish(key, bytes);
      await storage.cleanup(key);
    } on Object {
      _persistence();
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
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

final class _DecodedLines {
  const _DecodedLines({
    this.lines = const <Map<String, Object?>>[],
    this.validPrefix = const <int>[],
  });

  final List<Map<String, Object?>> lines;
  final List<int> validPrefix;
}

final class _ProfileReplay {
  const _ProfileReplay({
    this.profile,
    this.nextSequence = 0,
    this.validPrefix = const <int>[],
  });

  final AssistantProfile? profile;
  final int nextSequence;
  final List<int> validPrefix;
}

final class _SelectionReplay {
  const _SelectionReplay({
    this.selection,
    this.nextSequence = 0,
    this.validPrefix = const <int>[],
  });

  final ActiveProfileSelection? selection;
  final int nextSequence;
  final List<int> validPrefix;
}

void _throwIfCancelled(CancellationToken cancellation) {
  if (cancellation.isCancelled) {
    throwPersonalization(
      PersonalizationErrorKind.configuration,
      'Операция отменена.',
    );
  }
}

Never _conflict() => throwPersonalization(
  PersonalizationErrorKind.conflict,
  'Профиль был изменён в другом месте.',
);

Never _persistence() => throwPersonalization(
  PersonalizationErrorKind.persistence,
  'Не удалось прочитать или сохранить профили.',
);
