import 'dart:async';
import 'dart:convert';

import '../agents/clock.dart';
import '../agents/ids.dart';
import '../llm/cancellation.dart';
import '../projects/ids.dart';
import 'batch_extractor.dart';
import 'candidate.dart';
import 'enums.dart';
import 'entry.dart';
import 'errors.dart';
import 'extraction.dart';
import 'extraction_policy.dart';
import 'ids.dart';
import 'phrase_extractor.dart';
import 'repository.dart';

/// Host-owned candidate identities for extraction output.
final class MemoryExtractionIdFactory {
  MemoryExtractionIdFactory({this.namespace});

  final String? namespace;

  MemoryCandidateId forExplicitPhrase({
    required AgentSessionId sessionId,
    required MemorySourceId sourceId,
    required int phraseIndex,
  }) {
    return _candidateId(<String>[
      'explicit',
      sessionId.value,
      sourceId.value,
      '$phraseIndex',
    ]);
  }

  MemoryCandidateId forBatchProposal({
    required AgentSessionId sessionId,
    required List<MemorySourceId> sourceIds,
    required int proposalIndex,
  }) {
    return _candidateId(<String>[
      'batch',
      sessionId.value,
      ...sourceIds.map((source) => source.value),
      '$proposalIndex',
    ]);
  }

  MemoryCandidateId _candidateId(List<String> parts) {
    final encoded = base64Url
        .encode(utf8.encode(jsonEncode(parts)))
        .replaceAll('=', '');
    final prefix = namespace == null ? 'memory-candidate' : namespace!;
    final legacy = '$prefix-$encoded';
    // Keep already-safe legacy identities stable, but compact production
    // runtime IDs before the storage layer encodes them into a filename again.
    // The bound also leaves room for the `memory-entry-` prefix used when a
    // candidate is confirmed.
    if (utf8.encode(legacy).length <= 160) {
      return MemoryCandidateId(legacy);
    }
    return MemoryCandidateId('memory-candidate-v2-${_stableDigest(legacy)}');
  }
}

final _fnv64Prime = BigInt.parse('100000001b3', radix: 16);
final _fnv64Mask = BigInt.parse('ffffffffffffffff', radix: 16);
final _fnv64OffsetA = BigInt.parse('cbf29ce484222325', radix: 16);
final _fnv64OffsetB = BigInt.parse('84222325cbf29ce4', radix: 16);

String _stableDigest(String input) {
  final bytes = utf8.encode(input);
  return '${_fnv1a64(bytes, _fnv64OffsetA)}'
      '${_fnv1a64(bytes.reversed, _fnv64OffsetB)}';
}

String _fnv1a64(Iterable<int> bytes, BigInt offset) {
  var hash = offset;
  for (final byte in bytes) {
    hash = ((hash ^ BigInt.from(byte)) * _fnv64Prime) & _fnv64Mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

enum MemoryExtractionStatus { skipped, busy, extracted, failed }

final class MemoryExtractionResult {
  MemoryExtractionResult._(this.status, List<MemoryCandidate> candidates)
    : candidates = List<MemoryCandidate>.unmodifiable(candidates);

  factory MemoryExtractionResult.skipped() =>
      MemoryExtractionResult._(MemoryExtractionStatus.skipped, const []);

  factory MemoryExtractionResult.busy() =>
      MemoryExtractionResult._(MemoryExtractionStatus.busy, const []);

  factory MemoryExtractionResult.failed() =>
      MemoryExtractionResult._(MemoryExtractionStatus.failed, const []);

  factory MemoryExtractionResult.extracted(List<MemoryCandidate> candidates) =>
      MemoryExtractionResult._(MemoryExtractionStatus.extracted, candidates);

  final MemoryExtractionStatus status;
  final List<MemoryCandidate> candidates;

  bool get isExtracted => status == MemoryExtractionStatus.extracted;
}

/// Foreground memory-extraction scheduler.
///
/// It records completed transcript sources, persists checkpoints, debounces
/// idle flushes, supports manual flush/pause/resume, guarantees single-flight
/// per session, and never writes active memory: only candidates are persisted.
final class MemoryExtractionCoordinator {
  MemoryExtractionCoordinator({
    required this.extractor,
    required this.repositories,
    required this.checkpoints,
    required this.clock,
    MemoryExtractionIdFactory? ids,
    this.windowSize = memoryExtractionWindowSize,
    this.advance = memoryExtractionAdvance,
    this.idleFlushAfter = memoryExtractionIdleFlush,
    this.maxActiveEntries = 20,
  }) : ids = ids ?? MemoryExtractionIdFactory() {
    if (windowSize <= 0 || advance <= 0 || advance > windowSize) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Extraction window bounds are invalid.',
      );
    }
    if (idleFlushAfter <= Duration.zero) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Extraction idle debounce must be positive.',
      );
    }
    if (maxActiveEntries < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Active record bound must be non-negative.',
      );
    }
  }

  final MemoryBatchExtractor extractor;
  final MemoryRepositories repositories;
  final MemoryExtractionCheckpointRepository checkpoints;
  final AgentClock clock;
  final MemoryExtractionIdFactory ids;
  final int windowSize;
  final int advance;
  final Duration idleFlushAfter;
  final int maxActiveEntries;

  final CancellationSource _operations = CancellationSource();
  final Map<String, _SessionState> _states = <String, _SessionState>{};
  var _disposed = false;

  int _now() => clock.nowMicros();

  _SessionState _state(AgentSessionId sessionId) =>
      _states.putIfAbsent(sessionId.value, () => _SessionState(sessionId));

  /// Records completed transcript messages and schedules the next flush.
  Future<MemoryExtractionResult> onCompletedTurn({
    required AgentSessionId sessionId,
    required ProjectId projectId,
    required List<MemoryExtractionSource> completedSources,
  }) async {
    if (_disposed) return MemoryExtractionResult.failed();
    final state = _state(sessionId);
    state.projectId = projectId;
    _cacheSources(state, completedSources);
    final now = _now();
    final explicit = await _persistExplicitPhrases(
      state,
      completedSources,
      now,
    );
    final checkpoint = await _recordActivity(state, now);
    _rescheduleIdle(state);
    final due =
        checkpoint.pendingSourceIds.length >= windowSize && !state.paused;
    final result = due
        ? await _flush(sessionId, force: false)
        : MemoryExtractionResult.skipped();
    if (explicit.isEmpty) {
      return result;
    }
    return MemoryExtractionResult.extracted(<MemoryCandidate>[
      ...explicit,
      ...result.candidates,
    ]);
  }

  /// Manual `Analyze now`: flushes every pending source immediately.
  Future<MemoryExtractionResult> analyzeNow({
    required AgentSessionId sessionId,
    required ProjectId projectId,
    required List<MemoryExtractionSource> completedSources,
  }) async {
    if (_disposed) return MemoryExtractionResult.failed();
    final state = _state(sessionId);
    state.paused = false;
    state.projectId = projectId;
    _cacheSources(state, completedSources);
    final now = _now();
    final explicit = await _persistExplicitPhrases(
      state,
      completedSources,
      now,
    );
    await _recordActivity(state, now);
    final result = await _flush(sessionId, force: true);
    if (explicit.isEmpty) {
      return result;
    }
    return MemoryExtractionResult.extracted(<MemoryCandidate>[
      ...explicit,
      ...result.candidates,
    ]);
  }

  /// Pauses scheduling. Timers are cancelled; the checkpoint is unchanged.
  void pause(AgentSessionId sessionId) {
    if (_disposed) return;
    final state = _state(sessionId);
    state.paused = true;
    _cancelTimer(state);
    state.activeExtraction?.cancel();
  }

  /// Resumes scheduling and runs an overdue flush in the foreground.
  Future<MemoryExtractionResult> resume({
    required AgentSessionId sessionId,
    required ProjectId projectId,
    required List<MemoryExtractionSource> completedSources,
  }) async {
    if (_disposed) return MemoryExtractionResult.failed();
    final state = _state(sessionId);
    state.paused = false;
    state.projectId = projectId;
    _cacheSources(state, completedSources);
    final now = _now();
    final explicit = await _persistExplicitPhrases(
      state,
      completedSources,
      now,
    );
    final previous = await checkpoints.load(
      sessionId,
      cancellation: _operations.token,
    );
    final known = <String>{
      for (final source
          in previous?.processedSourceIds ?? const <MemorySourceId>[])
        source.value,
      for (final source
          in previous?.pendingSourceIds ?? const <MemorySourceId>[])
        source.value,
    };
    final hasNew =
        previous == null ||
        state.orderedSourceIds.any((source) => !known.contains(source.value));
    late final MemoryExtractionCheckpoint checkpoint;
    if (hasNew) {
      checkpoint = await _recordActivity(state, now);
    } else {
      checkpoint = previous;
      _rememberCheckpoint(state, checkpoint);
    }
    final overdue =
        checkpoint.pendingSourceIds.isNotEmpty &&
        now - checkpoint.lastActivityMicros >= idleFlushAfter.inMicroseconds;
    if (overdue) {
      final result = await _flush(sessionId, force: true);
      if (explicit.isEmpty) {
        return result;
      }
      return MemoryExtractionResult.extracted(<MemoryCandidate>[
        ...explicit,
        ...result.candidates,
      ]);
    }
    _rescheduleIdle(state);
    if (explicit.isNotEmpty) {
      return MemoryExtractionResult.extracted(explicit);
    }
    return MemoryExtractionResult.skipped();
  }

  bool isPaused(AgentSessionId sessionId) =>
      _states[sessionId.value]?.paused ?? false;

  /// Awaits any timer-triggered extraction currently running for [sessionId].
  Future<void> settle(AgentSessionId sessionId) async {
    if (_disposed) return;
    final state = _state(sessionId);
    while (true) {
      final inflight = state.inflight;
      if (inflight == null) {
        return;
      }
      await inflight;
      if (identical(state.inflight, inflight)) {
        state.inflight = null;
        return;
      }
    }
  }

  Future<MemoryExtractionCheckpoint> _recordActivity(
    _SessionState state,
    int now,
  ) async {
    final previous = await checkpoints.load(
      state.sessionId,
      cancellation: _operations.token,
    );
    final next = recordMemoryExtractionActivity(
      sessionId: state.sessionId,
      previous: previous,
      completedSourceIds: state.orderedSourceIds,
      nowMicros: now,
    );
    if (!identical(next, previous)) {
      await checkpoints.save(
        next,
        expectedRevision: previous?.revision ?? 0,
        cancellation: _operations.token,
      );
    }
    _rememberCheckpoint(state, next);
    return next;
  }

  Future<List<MemoryCandidate>> _persistExplicitPhrases(
    _SessionState state,
    List<MemoryExtractionSource> sources,
    int now,
  ) async {
    final created = <MemoryCandidate>[];
    for (final source in sources) {
      if (source.role != MemoryTranscriptRole.user) {
        continue;
      }
      final proposals = parseMemoryRememberPhrases(source.text);
      for (var phraseIndex = 0; phraseIndex < proposals.length; phraseIndex++) {
        final proposal = proposals[phraseIndex];
        final projectId = proposal.scope == MemoryScope.project
            ? state.projectId
            : null;
        if (proposal.scope == MemoryScope.project && projectId == null) {
          continue;
        }
        final MemoryCandidate candidate;
        try {
          candidate = MemoryCandidate(
            id: ids.forExplicitPhrase(
              sessionId: state.sessionId,
              sourceId: source.id,
              phraseIndex: phraseIndex,
            ),
            revision: 0,
            operation: MemoryProposalOperation.create,
            layer: proposal.layer,
            scope: proposal.scope,
            kind: proposal.kind,
            content: proposal.content,
            sourceIds: <MemorySourceId>[source.id],
            createdAtMicros: now,
            updatedAtMicros: now,
            projectId: projectId,
          );
        } on MemoryException {
          continue;
        }
        if (!await _saveCandidate(candidate)) {
          continue;
        }
        created.add(candidate);
      }
    }
    return created;
  }

  Future<MemoryExtractionResult> _flush(
    AgentSessionId sessionId, {
    required bool force,
  }) async {
    if (_disposed) return MemoryExtractionResult.failed();
    final state = _state(sessionId);
    if (state.running) {
      state.rerun = true;
      state.rerunForce = state.rerunForce || force;
      return MemoryExtractionResult.busy();
    }
    state.running = true;
    _cancelTimer(state);
    final runCancellation = CancellationSource();
    state.activeExtraction = runCancellation;
    final cancellation = runCancellation.token;
    try {
      final checkpoint = await checkpoints.load(
        sessionId,
        cancellation: cancellation,
      );
      if (checkpoint == null) {
        state.hasPending = false;
        return MemoryExtractionResult.skipped();
      }
      _rememberCheckpoint(state, checkpoint);
      final plan = planMemoryExtraction(
        pendingSourceIds: checkpoint.pendingSourceIds,
        force: force,
        windowSize: windowSize,
        advance: advance,
      );
      if (plan == null) {
        return MemoryExtractionResult.skipped();
      }
      final sources = <MemoryExtractionSource>[
        for (final id in plan.batchSourceIds)
          if (state.sources[id.value] != null) state.sources[id.value]!,
      ];
      if (sources.length != plan.batchSourceIds.length) {
        return MemoryExtractionResult.failed();
      }
      final projectId = state.projectId;
      if (projectId == null) {
        return MemoryExtractionResult.failed();
      }
      final active = await _activeEntries(
        projectId,
        cancellation: cancellation,
      );
      final drafts = await extractor.extract(
        MemoryExtractionInput(
          projectId: projectId,
          sources: sources,
          activeEntries: active,
        ),
        cancellation: cancellation,
      );
      final now = _now();
      final activeById = <String, MemoryEntry>{
        for (final entry in active) entry.id.value: entry,
      };
      final candidates = <MemoryCandidate>[];
      for (
        var proposalIndex = 0;
        proposalIndex < drafts.length;
        proposalIndex++
      ) {
        final draft = drafts[proposalIndex];
        final candidate = _materializeDraft(
          draft,
          plan: plan,
          state: state,
          activeById: activeById,
          now: now,
          proposalIndex: proposalIndex,
        );
        if (candidate == null) {
          continue;
        }
        if (await _saveCandidate(candidate, cancellation: cancellation)) {
          candidates.add(candidate);
        }
      }
      final advanced = advanceMemoryExtractionCheckpoint(
        previous: checkpoint,
        plan: plan,
        nowMicros: now,
      );
      await checkpoints.save(
        advanced,
        expectedRevision: checkpoint.revision,
        cancellation: cancellation,
      );
      _rememberCheckpoint(state, advanced);
      if (!force && advanced.pendingSourceIds.length >= windowSize) {
        state.rerun = true;
      }
      return MemoryExtractionResult.extracted(candidates);
    } on Object {
      return MemoryExtractionResult.failed();
    } finally {
      state.running = false;
      final rerun = state.rerun;
      final rerunForce = state.rerunForce;
      state.rerun = false;
      state.rerunForce = false;
      if (identical(state.activeExtraction, runCancellation)) {
        state.activeExtraction = null;
      }
      _rescheduleIdle(state);
      if (rerun && !state.paused) {
        state.inflight = _flush(sessionId, force: rerunForce);
        unawaited(state.inflight);
      }
    }
  }

  MemoryCandidate? _materializeDraft(
    MemoryCandidateDraft draft, {
    required MemoryExtractionPlan plan,
    required _SessionState state,
    required Map<String, MemoryEntry> activeById,
    required int now,
    required int proposalIndex,
  }) {
    final MemoryLayer layer;
    final MemoryKind kind;
    final MemoryEntryId? target;
    if (draft.operation == MemoryProposalOperation.update) {
      final existing = activeById[draft.targetEntryId?.value];
      if (existing == null) {
        return null;
      }
      layer = existing.layer;
      kind = existing.kind;
      target = existing.id;
    } else {
      layer = draft.layer;
      kind = draft.kind;
      target = null;
    }
    final content = draft.content;
    if (content == null) {
      return null;
    }
    final projectId = layer == MemoryLayer.working ? state.projectId : null;
    try {
      return MemoryCandidate(
        id: ids.forBatchProposal(
          sessionId: state.sessionId,
          sourceIds: plan.batchSourceIds,
          proposalIndex: proposalIndex,
        ),
        revision: 0,
        operation: draft.operation,
        layer: layer,
        scope: layer == MemoryLayer.working
            ? MemoryScope.project
            : MemoryScope.global,
        kind: kind,
        content: content,
        sourceIds: plan.batchSourceIds,
        createdAtMicros: now,
        updatedAtMicros: now,
        projectId: projectId,
        targetEntryId: target,
      );
    } on MemoryException {
      return null;
    }
  }

  Future<bool> _saveCandidate(
    MemoryCandidate candidate, {
    CancellationToken? cancellation,
  }) async {
    try {
      await repositories.candidateRepository.save(
        candidate,
        expectedRevision: 0,
        cancellation: cancellation ?? _operations.token,
      );
      return true;
    } on MemoryException catch (error) {
      if (error.error.kind == MemoryErrorKind.conflict) {
        return false;
      }
      rethrow;
    }
  }

  Future<List<MemoryEntry>> _activeEntries(
    ProjectId? projectId, {
    CancellationToken? cancellation,
  }) async {
    if (projectId == null) {
      return const <MemoryEntry>[];
    }
    final working = await repositories.workingRepository.list(
      projectId: projectId,
      cancellation: cancellation ?? _operations.token,
    );
    final longTerm = await repositories.longTermRepository.list(
      cancellation: cancellation ?? _operations.token,
    );
    final all = <MemoryEntry>[...working, ...longTerm]
      ..sort((left, right) => left.id.value.compareTo(right.id.value));
    return List<MemoryEntry>.unmodifiable(all.take(maxActiveEntries));
  }

  void _cacheSources(
    _SessionState state,
    List<MemoryExtractionSource> sources,
  ) {
    for (final source in sources) {
      state.sources[source.id.value] = source;
      if (state.knownSourceIds.add(source.id.value)) {
        state.orderedSourceIds.add(source.id);
      }
    }
  }

  void _rescheduleIdle(_SessionState state) {
    _cancelTimer(state);
    if (_disposed || state.paused || !state.hasPending) {
      return;
    }
    final elapsedMicros = state.lastActivityMicros == null
        ? 0
        : _now() - state.lastActivityMicros!;
    final delay = elapsedMicros >= idleFlushAfter.inMicroseconds
        ? idleFlushAfter
        : Duration(microseconds: idleFlushAfter.inMicroseconds - elapsedMicros);
    state.timer = clock.schedule(delay, () {
      unawaited(_idleFlush(state.sessionId));
    });
  }

  void _rememberCheckpoint(
    _SessionState state,
    MemoryExtractionCheckpoint checkpoint,
  ) {
    state.hasPending = checkpoint.hasPending;
    state.lastActivityMicros = checkpoint.lastActivityMicros;
  }

  Future<void> _idleFlush(AgentSessionId sessionId) async {
    final state = _state(sessionId);
    if (state.paused) {
      return;
    }
    state.inflight = _flush(sessionId, force: true);
    await state.inflight;
  }

  void _cancelTimer(_SessionState state) {
    state.timer?.cancel();
    state.timer = null;
  }

  /// Cancels every foreground timer and in-flight extractor invocation.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _operations.cancel();
    for (final state in _states.values) {
      _cancelTimer(state);
      state.activeExtraction?.cancel();
    }
    _states.clear();
  }
}

final class _SessionState {
  _SessionState(this.sessionId);

  final AgentSessionId sessionId;
  ProjectId? projectId;
  var paused = false;
  var running = false;
  var rerun = false;
  var rerunForce = false;
  var hasPending = false;
  int? lastActivityMicros;
  CancellationSource? activeExtraction;
  AgentTimer? timer;
  Future<void>? inflight;
  final Map<String, MemoryExtractionSource> sources =
      <String, MemoryExtractionSource>{};
  final Set<String> knownSourceIds = <String>{};
  final List<MemorySourceId> orderedSourceIds = <MemorySourceId>[];
}
