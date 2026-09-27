import 'dart:math';

import '../../../../core/agents/run_context.dart';
import '../../../../core/llm/llm.dart';

/// Identifies one `summarize_papers` invocation to the composition.
///
/// The digest server builds this scope from the MCP `tools/call` envelope:
/// the JSON-RPC request id, the transport session id (when the transport
/// provides one), the MCP task id (when the call is task-augmented) and a
/// bounded copy of the request `_meta`.
///
/// The scope is metadata, not model input: tool arguments and their model can
/// never choose a model. A resolver that cannot associate the scope with a
/// known run returns `null`, and the tool fails with `model_unavailable`.
final class DigestInvocationScope {
  DigestInvocationScope({
    required String requestId,
    String? sessionId,
    String? taskId,
    Map<String, Object?>? meta,
  }) : requestId = _requireScopeId(requestId, 'requestId'),
       sessionId = _trimmedOrNull(sessionId),
       taskId = _trimmedOrNull(taskId),
       meta = _boundedMeta(meta);

  /// JSON-RPC id of the MCP `tools/call` request.
  final String requestId;

  /// MCP transport session id, when the transport exposes one.
  final String? sessionId;

  /// MCP task id, when the call is task-augmented.
  final String? taskId;

  /// Bounded copy of the request `_meta` (scalars only).
  final Map<String, Object?> meta;

  @override
  String toString() =>
      'DigestInvocationScope($requestId, session: $sessionId, task: $taskId)';
}

/// Trusted, fixed model selection for exactly one digest invocation.
final class DigestModelPin {
  const DigestModelPin({required this.model});

  final ModelRef model;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DigestModelPin && other.model == model;

  @override
  int get hashCode => model.hashCode;

  @override
  String toString() => 'DigestModelPin($model)';
}

/// Resolves the model that is fixed for one `summarize_papers` invocation.
///
/// The digest server calls [resolve] exactly once per tool call, before any
/// provider work, and uses the returned pin only for that invocation. A
/// resolver must derive the pin from the calling agent/task context identified
/// by [scope]; it must never read a mutable global "current model" that is
/// shared by concurrent chats or scheduled runs, because two concurrent calls
/// with different pinned models have to stay isolated.
///
/// Returning `null` is a supported, explicit state: the call then fails with
/// `[digest:model_unavailable]` instead of guessing a model. At the time of
/// writing, the B2 agent bridge does not convey a trusted per-call selection
/// through `tools/call`, so the production composition has to wire one (see
/// `docs/mcp-b4-digest-server.md`).
abstract interface class DigestModelPinResolver {
  DigestModelPin? resolve(DigestInvocationScope scope);
}

/// In-memory pin table keyed by a trusted scope key.
///
/// B9 composition registers the pinned [ModelRef] when an agent chat or a
/// scheduled run starts and releases it when the run settles; [scopeKeyOf]
/// extracts the run key from the MCP call envelope. When the bridge starts to
/// forward a trusted scope key (for example in `_meta`), the composition can
/// use the same extractor for both sides, so two concurrent runs with
/// different keys can never observe each other's model.
final class DigestModelPinRegistry implements DigestModelPinResolver {
  DigestModelPinRegistry({required this.scopeKeyOf});

  /// Extracts the run/task key from an invocation scope, or `null` when the
  /// scope does not identify a run this registry knows about.
  final String? Function(DigestInvocationScope scope) scopeKeyOf;

  final Map<String, ModelRef> _pins = <String, ModelRef>{};

  /// Number of registered scopes; for diagnostics and tests.
  int get activeScopeCount => _pins.length;

  /// Registers the fixed model for [scopeKey].
  ///
  /// Registering the same key again replaces the pin; an active run must not
  /// be able to observe a foreign pin because the key is unique per run.
  void registerScope(String scopeKey, ModelRef model) {
    _pins[_requireScopeId(scopeKey, 'scopeKey')] = model;
  }

  /// Removes the pin for [scopeKey]; unknown keys are ignored.
  void releaseScope(String scopeKey) {
    _pins.remove(scopeKey.trim());
  }

  /// Removes every pin; used when the app shuts down.
  void clear() {
    _pins.clear();
  }

  @override
  DigestModelPin? resolve(DigestInvocationScope scope) {
    final key = scopeKeyOf(scope);
    if (key == null) {
      return null;
    }
    final normalized = key.trim();
    if (normalized.isEmpty) {
      return null;
    }
    final model = _pins[normalized];
    return model == null ? null : DigestModelPin(model: model);
  }
}

/// Resolver that never has a pin; every call fails with `model_unavailable`.
///
/// This is the honest placeholder for compositions where the per-call
/// selection is not wired yet: the digest tool reports a clear error instead
/// of silently reusing another chat's model.
final class UnavailableDigestModelPinResolver
    implements DigestModelPinResolver {
  const UnavailableDigestModelPinResolver();

  @override
  DigestModelPin? resolve(DigestInvocationScope scope) => null;
}

/// [AgentRunToolContextFactory] that registers one digest model pin per run.
///
/// The scope key is a fresh, unpredictable capability: it is generated by the
/// application (not the model, not a peer) and never appears in tool
/// arguments, transcripts or logs. [end] releases the pin when the run
/// settles, so a late or replayed `tools/call` from a finished run fails with
/// `[digest:model_unavailable]` instead of reusing a finished run's model.
final class DigestRunToolContextFactory implements AgentRunToolContextFactory {
  DigestRunToolContextFactory({required this.pins, Random? random})
    : _random = random ?? Random.secure();

  final DigestModelPinRegistry pins;
  final Random _random;

  /// Number of scopes currently registered; diagnostics and tests.
  int get activeScopeCount => pins.activeScopeCount;

  @override
  AgentRunToolContext begin({
    required ModelRef model,
    bool bindLibraryRunId = false,
  }) {
    final key = _newScopeKey();
    pins.registerScope(key, model);
    return AgentRunToolContext(
      scopeKey: key,
      bindLibraryRunId: bindLibraryRunId,
    );
  }

  @override
  void end(AgentRunToolContext context) => pins.releaseScope(context.scopeKey);

  String _newScopeKey() {
    final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}

const _maxMetaEntries = 32;
const _maxMetaKeyCharacters = 128;
const _maxMetaValueCharacters = 512;

Map<String, Object?> _boundedMeta(Map<String, Object?>? meta) {
  if (meta == null || meta.isEmpty) {
    return const <String, Object?>{};
  }
  final copy = <String, Object?>{};
  for (final entry in meta.entries) {
    if (copy.length >= _maxMetaEntries) {
      break;
    }
    final key = entry.key;
    if (key.length > _maxMetaKeyCharacters) {
      continue;
    }
    final value = entry.value;
    if (value is String) {
      copy[key] = value.length <= _maxMetaValueCharacters
          ? value
          : value.substring(0, _maxMetaValueCharacters);
    } else if (value is num || value is bool || value == null) {
      copy[key] = value;
    }
  }
  return Map<String, Object?>.unmodifiable(copy);
}

String _requireScopeId(String value, String name) {
  final candidate = value.trim();
  if (candidate.isEmpty || candidate.length > 256) {
    throw ArgumentError.value(value, name, 'must be 1-256 characters');
  }
  return candidate;
}

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}
