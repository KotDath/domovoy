import 'dart:async';
import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/continuation.dart';
import '../llm/errors.dart';
import '../llm/events.dart';
import '../llm/generation.dart';
import '../llm/identifiers.dart';
import '../llm/messages.dart';
import '../llm/registry.dart';
import '../llm/request.dart';
import '../llm/usage.dart';
import 'clock.dart';
import 'definition.dart';
import 'errors.dart';
import 'events.dart';
import 'hooks.dart';
import 'ids.dart';
import 'messaging.dart';
import 'policies.dart';
import 'record.dart';
import 'repository.dart';
import 'schema.dart';
import 'tools.dart';
import 'transcript.dart';

enum SessionPersistence { transient, repository }

enum AgentRuntimeLifecycle { open, closing, closed }

abstract interface class AgentRuntime {
  Agent agent(AgentDefinition definition);

  Future<void> close();
}

abstract interface class Agent {
  AgentDefinition get definition;

  AgentRun run(String input, {AgentRunOptions? options});

  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options});

  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
  });

  Future<AgentSession> restoreSession(AgentSessionId id);
}

abstract interface class AgentSession {
  AgentSessionId get id;

  AgentSessionSnapshot get snapshot;

  AgentSessionLifecycle get lifecycle;

  AgentRun run(String input, {AgentRunOptions? options});

  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options});

  Future<void> close();
}

abstract interface class AgentRun {
  RunId get id;

  Stream<AgentRunEvent> get events;

  Future<void> cancel();
}

final class InMemoryAgentRuntime implements AgentRuntime {
  InMemoryAgentRuntime({
    required this.registry,
    AgentToolRegistry? tools,
    Map<String, ToolPermissionPolicy>? policies,
    this.approval,
    AgentSessionRepository? repository,
    AgentSessionCodec? codec,
    InMemorySessionRouter? router,
    AgentClock? clock,
    AgentIdFactory? ids,
    this.hooks = const <AgentLifecycleHook>[],
    AgentRunLimits? profileLimits,
    AgentRuntimeProfile? profile,
    AgentPersistencePolicy? persistencePolicy,
  }) : tools = tools ?? AgentToolRegistry(),
       policies =
           policies ??
           <String, ToolPermissionPolicy>{
             'deny': const DenyAllPolicy(),
             'allow': const AllowAllPolicy(),
           },
       repository = repository ?? InMemoryAgentSessionRepository(),
       codec = codec ?? const AgentSessionCodec(),
       router = router ?? InMemorySessionRouter(),
       clock = clock ?? SystemAgentClock(),
       ids = ids ?? AgentIdFactory(),
       profile = profile ?? AgentRuntimeProfile(limits: profileLimits),
       persistencePolicy = persistencePolicy ?? AgentPersistencePolicy();

  final LlmProviderRegistry registry;
  final AgentToolRegistry tools;
  final Map<String, ToolPermissionPolicy> policies;
  final ToolApprovalHandler? approval;
  final AgentSessionRepository repository;
  final AgentSessionCodec codec;
  final InMemorySessionRouter router;
  final AgentClock clock;
  final AgentIdFactory ids;
  final List<AgentLifecycleHook> hooks;
  final AgentRuntimeProfile profile;
  final AgentPersistencePolicy persistencePolicy;
  AgentRunLimits? get profileLimits => profile.limits;
  AgentLivenessPolicy get profileLiveness => profile.liveness;
  AgentNoProgressPolicy get profileNoProgress => profile.noProgress;
  AgentTokenBudget get profileBudget => profile.budget;

  final Map<String, _LiveSession> _live = <String, _LiveSession>{};
  final Map<String, Future<void>> _restoreQuarantine = <String, Future<void>>{};
  final Map<int, Completer<void>> _opening = <int, Completer<void>>{};
  var _openingSeq = 0;
  var _lifecycle = AgentRuntimeLifecycle.open;
  Future<void>? _closeFuture;
  var _sharedDeadlineFired = false;
  final CancellationSource _sharedDeadlineSignal = CancellationSource();
  AgentTimer? _sharedDeadlineTimer;

  AgentRuntimeLifecycle get lifecycle => _lifecycle;
  bool get isClosing =>
      _lifecycle == AgentRuntimeLifecycle.closing ||
      _lifecycle == AgentRuntimeLifecycle.closed;
  bool get sharedDeadlineFired => _sharedDeadlineFired;
  CancellationToken get sharedDeadlineToken => _sharedDeadlineSignal.token;

  bool isRestoreQuarantined(AgentSessionId id) =>
      _restoreQuarantine.containsKey(id.value);

  void quarantineRestore(AgentSessionId id, Future<void> pending) {
    _restoreQuarantine[id.value] = pending;
    unawaited(
      pending.then<void>(
        (_) {
          if (identical(_restoreQuarantine[id.value], pending)) {
            _restoreQuarantine.remove(id.value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_restoreQuarantine[id.value], pending)) {
            _restoreQuarantine.remove(id.value);
          }
        },
      ),
    );
  }

  @override
  Agent agent(AgentDefinition definition) {
    _ensureOpen();
    return _BoundAgent(this, definition);
  }

  void _ensureOpen() {
    if (isClosing) {
      throwAgent(AgentErrorKind.configuration, 'Agent runtime is closed.');
    }
  }

  int _beginOpening() {
    _ensureOpen();
    final ticket = ++_openingSeq;
    _opening[ticket] = Completer<void>();
    return ticket;
  }

  void _endOpening(int ticket) {
    final completer = _opening.remove(ticket);
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _startSharedCloseBudget() {
    if (_sharedDeadlineTimer != null || _sharedDeadlineFired) {
      return;
    }
    final grace = persistencePolicy.cancellationGracePeriod;
    _sharedDeadlineTimer = clock.schedule(grace, () {
      _sharedDeadlineFired = true;
      _sharedDeadlineSignal.cancel();
    });
  }

  @override
  Future<void> close() => _closeFuture ??= _performClose();

  Future<void> _performClose() async {
    _lifecycle = AgentRuntimeLifecycle.closing;
    final opening = List<Completer<void>>.from(_opening.values);
    final sessions = List<_LiveSession>.from(_live.values);
    _startSharedCloseBudget();
    Object? firstError;
    await Future.wait(<Future<void>>[
      _awaitOpeningOrDeadline(opening),
      Future.wait(
        sessions.map((session) async {
          try {
            await session.close();
          } on Object catch (error) {
            firstError ??= AgentException(sanitizeCloseFailure(error));
          }
        }),
      ),
    ]);
    for (final completer in List<Completer<void>>.from(_opening.values)) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _opening.clear();
    _sharedDeadlineTimer?.cancel();
    _lifecycle = AgentRuntimeLifecycle.closed;
    final error = firstError;
    if (error is AgentException) {
      throw error;
    }
    if (error != null) {
      throw AgentException(sanitizedCloseError());
    }
  }

  Future<void> _awaitOpeningOrDeadline(List<Completer<void>> opening) async {
    if (opening.isEmpty) {
      return;
    }
    final done = Completer<void>();
    var remaining = opening.length;
    void trip() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    for (final completer in opening) {
      unawaited(
        completer.future.whenComplete(() {
          remaining -= 1;
          if (remaining <= 0) {
            trip();
          }
        }),
      );
    }
    final registration = _sharedDeadlineSignal.token.register(trip);
    try {
      await done.future;
    } finally {
      registration.dispose();
    }
  }

  void _registerLive(_LiveSession session) {
    _ensureOpen();
    if (_live.containsKey(session.id.value)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session ${session.id.value} is already live.',
      );
    }
    _live[session.id.value] = session;
    router.register(session.id);
  }

  void _unregisterLive(AgentSessionId id) {
    _live.remove(id.value);
    router.markClosed(id);
    router.unregister(id);
  }

  int debugPersistenceWaiters(AgentSessionId id) =>
      _live[id.value]?.debugPersistenceWaiters ?? 0;

  int debugMaxPersistenceWaiters(AgentSessionId id) =>
      _live[id.value]?.debugMaxPersistenceWaiters ?? 0;
}

final class _BoundAgent implements Agent {
  _BoundAgent(this._runtime, this.definition);

  final InMemoryAgentRuntime _runtime;

  @override
  final AgentDefinition definition;

  @override
  AgentRun run(String input, {AgentRunOptions? options}) {
    return _startOneCall(_userMessageFromString(input), options);
  }

  @override
  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options}) {
    return _startOneCall(_requireUser(input), options);
  }

  AgentRun _startOneCall(LlmMessage input, AgentRunOptions? options) {
    _runtime._ensureOpen();
    final cancel = CancellationSource();
    late StreamController<AgentRunEvent> controller;
    final runId = RunId(_runtime.ids.next('run'));
    final inner = _OneCallInner();
    final ticket = _runtime._beginOpening();
    late final _StreamRun streamRun;
    controller = StreamController<AgentRunEvent>(
      onCancel: () => streamRun.cancel(),
    );
    unawaited(() async {
      CancellationRegistration? cancelReg;
      try {
        if (cancel.token.isCancelled) {
          inner.emit(controller, const AgentRunCancelled());
          return;
        }
        final session = await _open(
          persistence: SessionPersistence.transient,
          ticket: ticket,
        );
        inner.session = session;
        if (cancel.token.isCancelled) {
          await session.close();
          inner.emit(controller, const AgentRunCancelled());
          return;
        }
        final run = session.runTyped(input, options: options, runId: runId);
        inner.run = run;
        cancelReg = cancel.token.register(() {
          unawaited(
            run.cancel().then<void>(
              (_) {},
              onError: (Object error, StackTrace stackTrace) {},
            ),
          );
        });
        inner.markBound();
        await for (final event in run.events) {
          inner.emit(controller, event);
        }
      } on AgentException catch (error) {
        inner.emit(controller, AgentRunFailed(error.error));
      } on LlmException catch (error) {
        inner.emit(controller, AgentRunFailed(agentErrorFromLlm(error.error)));
      } on Object {
        inner.emit(controller, AgentRunFailed(sanitizedRuntimeError()));
      } finally {
        inner.markBound();
        cancelReg?.dispose();
        _runtime._endOpening(ticket);
        try {
          await inner.session?.close();
        } on AgentException {
          // Persistence errors remain on the session close future.
        }
        await _closeRunController(controller);
      }
    }());
    streamRun = _StreamRun(
      id: runId,
      controller: controller,
      cancel: cancel,
      inner: inner,
    );
    return streamRun;
  }

  @override
  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
  }) {
    return _open(id: id, persistence: persistence);
  }

  @override
  Future<AgentSession> restoreSession(AgentSessionId id) async {
    _runtime._ensureOpen();
    final ticket = _runtime._beginOpening();
    try {
      if (_runtime.isRestoreQuarantined(id)) {
        throwAgent(
          AgentErrorKind.persistence,
          'Session ${id.value} is temporarily unavailable.',
        );
      }
      late final AgentSessionRecord record;
      try {
        final stored = await _runtime.repository.load(id);
        if (stored == null) {
          throwAgent(
            AgentErrorKind.persistence,
            'Session ${id.value} was not found.',
          );
        }
        record = _runtime.codec.decode(_runtime.codec.encode(stored));
      } on AgentException {
        rethrow;
      } on LlmException catch (error) {
        throw AgentException(
          AgentError(
            kind: AgentErrorKind.configuration,
            message: error.error.message,
          ),
        );
      } on Object {
        throw AgentException(sanitizedPersistenceError());
      }
      _runtime._ensureOpen();
      if (record.id != id) {
        throwAgent(
          AgentErrorKind.persistence,
          'Stored session identity does not match the requested identifier.',
        );
      }
      _resolveResourcesFor(record.definition);
      try {
        final selection = _runtime.registry.resolve(record.definition.model);
        validateContinuationEntries(
          messages: record.transcript.messages,
          entries: record.continuationEntries,
          origin: record.definition.model,
          wireFamily: selection.model.wireFamily,
        );
      } on LlmException catch (error) {
        throwAgent(AgentErrorKind.configuration, error.error.message);
      }
      final session = _LiveSession(
        runtime: _runtime,
        definition: record.definition,
        id: record.id,
        persistence: SessionPersistence.repository,
        transcript: record.transcript,
        usage: record.usage,
        modelTurns: record.modelTurns,
        toolAttempts: record.toolAttempts,
        continuationEntries: record.continuationEntries,
        revision: record.revision,
        createdAtMicros: record.createdAtMicros,
        persisted: true,
      );
      _runtime._registerLive(session);
      return session;
    } finally {
      _runtime._endOpening(ticket);
    }
  }

  Future<_LiveSession> _open({
    AgentSessionId? id,
    required SessionPersistence persistence,
    int? ticket,
  }) async {
    final ownedTicket = ticket ?? _runtime._beginOpening();
    var released = false;
    void release() {
      if (released) {
        return;
      }
      released = true;
      _runtime._endOpening(ownedTicket);
    }

    try {
      _runtime._ensureOpen();
      _resolveResources();
      _runtime._ensureOpen();
      final sessionId = id ?? AgentSessionId(_runtime.ids.next('session'));
      final now = _runtime.clock.nowMicros();
      final session = _LiveSession(
        runtime: _runtime,
        definition: definition,
        id: sessionId,
        persistence: persistence,
        transcript: AgentTranscript(messages: definition.initialMessages),
        createdAtMicros: now,
      );
      _runtime._registerLive(session);
      try {
        if (persistence == SessionPersistence.repository) {
          await session.checkpoint();
        }
        release();
        return session;
      } on Object {
        release();
        try {
          await session.close();
        } on AgentException {
          // The original create/restore failure is the error to surface.
        }
        rethrow;
      }
    } on Object {
      release();
      rethrow;
    }
  }

  void _resolveResources() => _resolveResourcesFor(definition);

  void _resolveResourcesFor(AgentDefinition def) {
    try {
      _runtime.registry.resolve(def.model);
    } on LlmException catch (error) {
      throwAgent(AgentErrorKind.configuration, error.error.message);
    }
    for (final tool in def.enabledTools) {
      if (!_runtime.tools.contains(tool)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Tool "${tool.value}" is not registered.',
        );
      }
    }
    if (!_runtime.policies.containsKey(def.policy.value)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Policy "${def.policy.value}" is not registered.',
      );
    }
  }
}

final class _OneCallInner {
  AgentRun? run;
  _LiveSession? session;
  final Completer<void> _bound = Completer<void>();
  var terminalEmitted = false;

  Future<void> get whenBound => _bound.future;

  void markBound() {
    if (!_bound.isCompleted) {
      _bound.complete();
    }
  }

  void emit(StreamController<AgentRunEvent> controller, AgentRunEvent event) {
    if (controller.isClosed) {
      return;
    }
    if (event.isTerminal) {
      if (terminalEmitted) {
        return;
      }
      terminalEmitted = true;
    }
    controller.add(event);
  }

  Future<void> cancel() async {
    await run?.cancel();
  }
}

final class _StreamRun implements AgentRun {
  _StreamRun({
    required this.id,
    required StreamController<AgentRunEvent> controller,
    required CancellationSource cancel,
    required _OneCallInner inner,
  }) : _controller = controller,
       _cancel = cancel,
       _inner = inner;

  @override
  final RunId id;

  final StreamController<AgentRunEvent> _controller;
  final CancellationSource _cancel;
  final _OneCallInner _inner;
  Future<void>? _cancelFuture;

  @override
  Stream<AgentRunEvent> get events => _controller.stream;

  @override
  Future<void> cancel() {
    _cancel.cancel();
    return _cancelFuture ??= _performCancel();
  }

  Future<void> _performCancel() async {
    Object? firstError;
    void remember(Object error) {
      firstError ??= error is AgentException
          ? error
          : AgentException(sanitizeCloseFailure(error));
    }

    try {
      await _inner.whenBound;
    } on Object catch (error) {
      remember(error);
    }
    try {
      await _inner.cancel();
    } on Object catch (error) {
      remember(error);
    }
    try {
      await _inner.session?.close();
    } on AgentException catch (error) {
      if (error.error.kind != AgentErrorKind.persistence &&
          error.error.kind != AgentErrorKind.conflict) {
        remember(AgentException(sanitizeCloseFailure(error)));
      }
    } on Object catch (error) {
      remember(error);
    }
    _inner.emit(_controller, const AgentRunCancelled());
    final error = firstError;
    if (error != null) {
      throw error;
    }
  }
}

final class _LiveSession implements AgentSession {
  _LiveSession({
    required this.runtime,
    required this.definition,
    required this.id,
    required this.persistence,
    required this.transcript,
    LlmUsage? usage,
    this.modelTurns = 0,
    this.toolAttempts = 0,
    List<LlmContinuationEntry> continuationEntries =
        const <LlmContinuationEntry>[],
    this.revision = 0,
    required this.createdAtMicros,
    this.persisted = false,
  }) : usage = usage ?? LlmUsage(),
       continuationEntries = List<LlmContinuationEntry>.from(
         continuationEntries,
       );

  final InMemoryAgentRuntime runtime;
  final AgentDefinition definition;

  @override
  final AgentSessionId id;

  final SessionPersistence persistence;
  AgentTranscript transcript;
  LlmUsage usage;
  int modelTurns;
  int toolAttempts;
  List<LlmContinuationEntry> continuationEntries;
  int revision;
  var persisted = false;
  final int createdAtMicros;
  AgentSessionLifecycle _lifecycle = AgentSessionLifecycle.idle;
  _LiveRun? _active;
  var _closed = false;
  Future<void>? _closeFuture;
  Future<void> _checkpointChain = Future<void>.value();
  CancellationSource? _activePersistCancel;
  Future<void>? _activePersistFuture;
  AgentSessionRecord? _frozenSnapshot;
  var _shutdownStarted = false;
  var _finalFlushAttempted = false;
  var _deadlineFired = false;
  CancellationSource _shutdownSignal = CancellationSource();
  CancellationSource _deadlineSignal = CancellationSource();
  Future<bool>? _shutdownWork;
  AgentTimer? _deadlineTimer;
  var persistenceUnreliable = false;
  AgentException? _closeError;
  var debugMaxPersistenceWaiters = 0;
  bool get persistenceShutdownStarted => _shutdownStarted;
  bool get isClosing =>
      _closed ||
      _lifecycle == AgentSessionLifecycle.closing ||
      _lifecycle == AgentSessionLifecycle.closed;
  int get debugPersistenceWaiters =>
      _shutdownSignal.registrationCount + _deadlineSignal.registrationCount;

  void _notePersistenceWaiters() {
    final count = debugPersistenceWaiters;
    if (count > debugMaxPersistenceWaiters) {
      debugMaxPersistenceWaiters = count;
    }
  }

  @override
  AgentSessionLifecycle get lifecycle => _lifecycle;

  @override
  AgentSessionSnapshot get snapshot => AgentSessionSnapshot(
    id: id,
    definition: definition,
    lifecycle: _lifecycle,
    transcript: AgentTranscript(messages: transcript.messages),
    usage: usage,
    modelTurns: modelTurns,
    toolAttempts: toolAttempts,
    revision: revision,
  );

  @override
  AgentRun run(String input, {AgentRunOptions? options}) {
    return runTyped(_userMessageFromString(input), options: options);
  }

  @override
  AgentRun runTyped(
    LlmMessage input, {
    AgentRunOptions? options,
    RunId? runId,
  }) {
    final message = _requireUser(input);
    runtime._ensureOpen();
    if (_lifecycle == AgentSessionLifecycle.closed ||
        _lifecycle == AgentSessionLifecycle.closing) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session ${id.value} is closed.',
      );
    }
    if (_lifecycle == AgentSessionLifecycle.running || _active != null) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session ${id.value} already has an active run.',
      );
    }
    _lifecycle = AgentSessionLifecycle.running;
    final run = _LiveRun(
      session: this,
      input: message,
      options: options ?? AgentRunOptions(),
      id: runId ?? RunId(runtime.ids.next('run')),
    );
    _active = run;
    run.start();
    return run;
  }

  void detachRun() {
    _active = null;
    if (!_closed && _lifecycle == AgentSessionLifecycle.running) {
      _lifecycle = AgentSessionLifecycle.idle;
    }
  }

  AgentSessionRecord _recordForSave({required int nextRevision}) {
    return AgentSessionRecord(
      id: id,
      revision: nextRevision,
      definition: definition,
      transcript: transcript,
      usage: usage,
      modelTurns: modelTurns,
      toolAttempts: toolAttempts,
      createdAtMicros: createdAtMicros,
      continuationEntries: continuationEntries,
      updatedAtMicros: runtime.clock.nowMicros(),
    );
  }

  void freezeSnapshot() {
    if (_frozenSnapshot != null && (_shutdownStarted || isClosing)) {
      return;
    }
    _frozenSnapshot = _recordForSave(
      nextRevision: persisted ? revision + 1 : 0,
    );
  }

  Future<void> checkpoint() async {
    if (persistence != SessionPersistence.repository) {
      return;
    }
    if (persistenceUnreliable) {
      throw AgentException(sanitizedPersistenceError());
    }
    if (_shutdownStarted) {
      throw _cancelledException();
    }
    await _serialized(() async {
      final isCreate = !persisted;
      final record = _recordForSave(nextRevision: isCreate ? 0 : revision + 1);
      await _saveRecord(record, expectedRevision: isCreate ? 0 : revision);
    });
  }

  Future<void> _serialized(Future<void> Function() operation) async {
    final previous = _checkpointChain;
    final done = Completer<void>();
    _checkpointChain = done.future;
    try {
      try {
        await previous;
      } on Object {
        // A failed prior save still releases the chain.
      }
      await operation();
    } finally {
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  Future<void> _saveRecord(
    AgentSessionRecord record, {
    required int expectedRevision,
  }) async {
    final persist = CancellationSource();
    _activePersistCancel = persist;
    final future = runtime.repository.save(
      record,
      expectedRevision: expectedRevision,
      cancellation: persist.token,
    );
    _activePersistFuture = future;
    final settled = Completer<void>();
    void trip() {
      if (!settled.isCompleted) {
        settled.complete();
      }
    }

    unawaited(
      future.then<void>(
        (_) => trip(),
        onError: (Object error, StackTrace stackTrace) => trip(),
      ),
    );
    CancellationRegistration? deadlineReg;
    void armDeadline() {
      deadlineReg ??= _deadlineSignal.token.register(trip);
      _notePersistenceWaiters();
    }

    final shutdownReg = _shutdownSignal.token.register(armDeadline);
    _notePersistenceWaiters();
    try {
      await settled.future;
      if (_deadlineReached) {
        persist.cancel();
        _markUnreliable(future);
        throw AgentException(sanitizedPersistenceError());
      }
      await future;
      if (_deadlineReached) {
        persist.cancel();
        _markUnreliable(future);
        throw AgentException(sanitizedPersistenceError());
      }
      revision = record.revision;
      persisted = true;
    } on AgentException {
      rethrow;
    } on Object {
      throw AgentException(sanitizedPersistenceError());
    } finally {
      shutdownReg.dispose();
      deadlineReg?.dispose();
      if (identical(_activePersistCancel, persist)) {
        _activePersistCancel = null;
        if (identical(_activePersistFuture, future)) {
          _activePersistFuture = null;
        }
      }
    }
  }

  bool get _deadlineReached => _deadlineFired;

  void beginPersistenceShutdown() {
    if (persistence != SessionPersistence.repository) {
      return;
    }
    _startShutdownBudget();
  }

  void clearFrozenSnapshot() {
    if (_shutdownStarted || isClosing || persistenceUnreliable) {
      return;
    }
    _frozenSnapshot = null;
  }

  void clearPersistenceShutdown() {
    if (persistenceUnreliable || isClosing) {
      return;
    }
    _shutdownStarted = false;
    _finalFlushAttempted = false;
    _deadlineFired = false;
    _frozenSnapshot = null;
    _shutdownWork = null;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    _shutdownSignal = CancellationSource();
    _deadlineSignal = CancellationSource();
  }

  CancellationRegistration? _sharedDeadlineReg;

  void _startShutdownBudget() {
    if (_shutdownStarted) {
      return;
    }
    _shutdownStarted = true;
    _shutdownSignal.cancel();
    if (runtime.isClosing) {
      if (runtime.sharedDeadlineFired) {
        _deadlineFired = true;
        _deadlineSignal.cancel();
        _activePersistCancel?.cancel();
        return;
      }
      _sharedDeadlineReg = runtime.sharedDeadlineToken.register(() {
        _deadlineFired = true;
        _activePersistCancel?.cancel();
        _deadlineSignal.cancel();
      });
      _activePersistCancel?.cancel();
      return;
    }
    final grace = runtime.persistencePolicy.cancellationGracePeriod;
    _deadlineTimer = runtime.clock.schedule(grace, () {
      _deadlineFired = true;
      _activePersistCancel?.cancel();
      _deadlineSignal.cancel();
    });
    _activePersistCancel?.cancel();
  }

  void _markUnreliable(Future<void>? pending) {
    persistenceUnreliable = true;
    _closeError ??= AgentException(sanitizedPersistenceError());
    if (pending != null) {
      runtime.quarantineRestore(id, pending);
      unawaited(
        pending.then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {},
        ),
      );
    }
  }

  Future<bool> runPersistenceShutdown() {
    if (persistence != SessionPersistence.repository) {
      return Future<bool>.value(true);
    }
    if (persistenceUnreliable) {
      _deadlineTimer?.cancel();
      return Future<bool>.value(false);
    }
    return _shutdownWork ??= _performPersistenceShutdown();
  }

  Future<bool> _performPersistenceShutdown() async {
    freezeSnapshot();
    _startShutdownBudget();
    final inflight = _activePersistFuture;
    if (inflight != null) {
      final settled = Completer<void>();
      void trip() {
        if (!settled.isCompleted) {
          settled.complete();
        }
      }

      unawaited(
        inflight.then<void>(
          (_) => trip(),
          onError: (Object error, StackTrace stackTrace) => trip(),
        ),
      );
      final deadlineReg = _deadlineSignal.token.register(trip);
      _notePersistenceWaiters();
      try {
        await settled.future;
      } finally {
        deadlineReg.dispose();
      }
    }
    if (_deadlineReached && inflight != null) {
      _markUnreliable(inflight);
      _deadlineTimer?.cancel();
      return false;
    }
    if (inflight != null) {
      try {
        await inflight;
      } on AgentException catch (error) {
        if (error.error.kind != AgentErrorKind.cancelled) {
          _markUnreliable(null);
          _deadlineTimer?.cancel();
          return false;
        }
      } on Object {
        _markUnreliable(null);
        _deadlineTimer?.cancel();
        return false;
      }
    }
    if (_deadlineReached) {
      _markUnreliable(_activePersistFuture);
      _deadlineTimer?.cancel();
      return false;
    }
    if (!_finalFlushAttempted) {
      _finalFlushAttempted = true;
      final frozen = _frozenSnapshot;
      if (frozen != null) {
        final isCreate = !persisted;
        final record = frozen.copyWith(
          revision: isCreate ? 0 : revision + 1,
          updatedAtMicros: runtime.clock.nowMicros(),
        );
        try {
          await _serialized(() async {
            await _saveRecord(
              record,
              expectedRevision: isCreate ? 0 : revision,
            );
          });
        } on AgentException catch (error) {
          _markUnreliable(
            error.error.kind == AgentErrorKind.cancelled
                ? _activePersistFuture
                : null,
          );
          _deadlineTimer?.cancel();
          return false;
        } on Object {
          _markUnreliable(null);
          _deadlineTimer?.cancel();
          return false;
        }
      }
    }
    _deadlineTimer?.cancel();
    return !persistenceUnreliable;
  }

  @override
  Future<void> close() => _closeFuture ??= _performClose();

  Future<void> _performClose() async {
    _closed = true;
    _lifecycle = AgentSessionLifecycle.closing;
    if (persistence == SessionPersistence.repository) {
      beginPersistenceShutdown();
    }
    final active = _active;
    if (active != null) {
      unawaited(active.cancel());
      if (persistence == SessionPersistence.repository) {
        await _awaitUnwindOrDeadline(active);
      } else {
        await active._unwound.future;
      }
      await active._awaitProviderTeardowns();
    }
    if (_frozenSnapshot == null) {
      freezeSnapshot();
    }
    await _awaitCheckpointChainOrDeadline();
    if (_activePersistFuture != null && !persistenceUnreliable) {
      _markUnreliable(_activePersistFuture);
    }
    if (persistence == SessionPersistence.repository &&
        persisted &&
        !persistenceUnreliable) {
      await runPersistenceShutdown();
    }
    _sharedDeadlineReg?.dispose();
    runtime._unregisterLive(id);
    _lifecycle = AgentSessionLifecycle.closed;
    final error = _closeError;
    if (error != null && persisted) {
      throw error;
    }
  }

  Future<void> _awaitUnwindOrDeadline(_LiveRun run) async {
    final done = Completer<void>();
    void trip() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    unawaited(
      run._unwound.future.then<void>(
        (_) => trip(),
        onError: (Object error, StackTrace stackTrace) => trip(),
      ),
    );
    final registration = _deadlineSignal.token.register(trip);
    if (_deadlineReached) {
      trip();
    }
    try {
      await done.future;
    } finally {
      registration.dispose();
    }
  }

  Future<void> _awaitCheckpointChainOrDeadline() async {
    final done = Completer<void>();
    void trip() {
      if (!done.isCompleted) {
        done.complete();
      }
    }

    unawaited(
      _checkpointChain.then<void>(
        (_) => trip(),
        onError: (Object error, StackTrace stackTrace) => trip(),
      ),
    );
    final registration = _deadlineSignal.token.register(trip);
    if (_deadlineReached) {
      trip();
    }
    try {
      await done.future;
    } finally {
      registration.dispose();
    }
  }
}

final class _LiveRun implements AgentRun {
  _LiveRun({
    required this.session,
    required this.input,
    required this.options,
    required this.id,
  }) : cancelSource = CancellationSource();

  @override
  final RunId id;
  final _LiveSession session;
  final LlmMessage input;
  final AgentRunOptions options;
  final CancellationSource cancelSource;
  late final StreamController<AgentRunEvent> _controller;
  var _started = false;
  var _terminated = false;
  var _stopping = false;
  AgentTimer? _idleTimer;
  AgentTimer? _durationTimer;
  var _noProgressCount = 0;
  String? _lastFingerprint;
  var _progressMarker = false;
  var _inboundThisCycle = false;
  var _turnUsageCommitted = false;
  LlmUsage _turnUsage = LlmUsage();
  Duration _runStartedAt = Duration.zero;
  final Set<String> _executedCallIds = <String>{};
  Completer<void>? _stopLock;
  var _closeAfter = false;
  late final ResolvedRunGuards guards;
  late final LlmGenerationConfig _generation;
  var _runModelTurns = 0;
  var _runToolAttempts = 0;
  LlmUsage _usageBaseline = LlmUsage();
  Future<void>? _cancelFuture;
  final Completer<void> _unwound = Completer<void>();
  final List<Future<_CancelSettlement>> _providerTeardowns =
      <Future<_CancelSettlement>>[];
  var _closingController = false;

  @override
  Stream<AgentRunEvent> get events {
    _ensureController();
    return _controller.stream;
  }

  @override
  Future<void> cancel() {
    cancelSource.cancel();
    return _cancelFuture ??= _performCancel();
  }

  Future<void> _performCancel() async {
    Object? firstError;
    void remember(Object error) {
      firstError ??= error is AgentException
          ? error
          : AgentException(sanitizeCloseFailure(error));
    }

    try {
      if (!_terminated) {
        session.beginPersistenceShutdown();
        await _completeWith(const AgentRunCancelled());
      }
    } on Object catch (error) {
      remember(error);
    }
    try {
      await _unwound.future;
    } on Object catch (error) {
      remember(error);
    }
    try {
      await _awaitProviderTeardowns();
    } on Object catch (error) {
      remember(error);
    }
    if (_closeAfter) {
      try {
        await session.close();
      } on AgentException catch (error) {
        if (error.error.kind != AgentErrorKind.persistence &&
            error.error.kind != AgentErrorKind.conflict) {
          remember(AgentException(sanitizeCloseFailure(error)));
        }
      } on Object catch (error) {
        remember(error);
      }
    }
    final error = firstError;
    if (error != null) {
      throw error;
    }
  }

  void start() {
    _ensureController();
    _done = _execute();
    unawaited(_done);
  }

  late final Future<void> _done;

  void _trackProviderTeardown(Future<void> future) {
    _providerTeardowns.add(_observeCancel(future));
  }

  Future<void> _awaitProviderTeardowns() async {
    if (_providerTeardowns.isEmpty) {
      return;
    }
    Object? firstError;
    for (final future in List<Future<_CancelSettlement>>.from(
      _providerTeardowns,
    )) {
      final settled = await future;
      if (settled.error != null) {
        firstError ??= settled.error;
      }
    }
    if (firstError != null) {
      throw AgentException(sanitizeCloseFailure(firstError));
    }
  }

  void _ensureController() {
    if (_started) {
      return;
    }
    _started = true;
    _controller = StreamController<AgentRunEvent>(
      onCancel: () {
        if (_closingController) {
          return null;
        }
        return cancel();
      },
    );
  }

  Future<void> _execute() async {
    try {
      guards = _resolveGuards();
      _generation = _resolveGeneration();
      _usageBaseline = session.usage;
      _runStartedAt = session.runtime.clock.elapsed;
      _armWatchdogs();
      _emit(AgentRunStarted(runId: id, sessionId: session.id));
      _throwIfCancelled();
      await _drainInbound();
      session.transcript = session.transcript.append(input);
      await _checkpoint();
      _resetIdle();
      await _loop();
    } on _RunStop catch (stop) {
      await _finishStop(stop.reason);
    } on AgentException catch (error) {
      await _fail(
        error.error,
        closeSession:
            error.error.kind == AgentErrorKind.persistence ||
            error.error.kind == AgentErrorKind.conflict,
      );
    } on LlmException catch (error) {
      await _fail(agentErrorFromLlm(error.error));
    } on Object {
      await _fail(sanitizedRuntimeError());
    } finally {
      _idleTimer?.cancel();
      _durationTimer?.cancel();
      await _stopLock?.future;
      session.detachRun();
      if (!_unwound.isCompleted) {
        _unwound.complete();
      }
      try {
        await _awaitProviderTeardowns();
      } on Object {
        if (_cancelFuture == null) {
          rethrow;
        }
      }
      if (_closeAfter) {
        try {
          await session.close();
        } on AgentException {
          // Persistence errors remain on the shared close future.
        }
      }
      _closingController = true;
      await _closeRunController(_controller);
    }
  }

  Future<void> _loop() async {
    while (true) {
      _throwIfCancelled();
      _checkDuration();
      if (guards.maxModelTurns != null &&
          _runModelTurns >= guards.maxModelTurns!) {
        throw _RunStop(AgentStopReason.modelTurnLimit);
      }
      _checkBudgets(preWork: true);
      _throwIfCancelled();
      final turnId = TurnId(session.runtime.ids.next('turn'));
      await _runHooks((hook) => hook.beforeModelTurn(_hookContext(turnId)));
      _throwIfCancelled();
      final selection = session.runtime.registry.resolve(
        session.definition.model,
      );
      if (_generation.maxOutputTokens != null &&
          _generation.maxOutputTokens! > selection.model.outputBound) {
        throwAgent(
          AgentErrorKind.configuration,
          'maxOutputTokens exceeds the model output bound.',
        );
      }
      final enabled = session.runtime.tools.descriptorsFor(
        session.definition.enabledTools,
      );
      final request = LlmRequest(
        model: session.definition.model,
        context: LlmContext(
          systemPrompt: session.definition.systemPrompt,
          messages: session.transcript.messages,
          tools: enabled,
          continuationEntries: session.continuationEntries,
        ),
        generation: _generation,
      );
      _runModelTurns += 1;
      session.modelTurns += 1;
      final assembler = _ToolCallAssembler();
      final answer = StringBuffer();
      final reasoning = StringBuffer();
      LlmFinishReason? finish;
      LlmProviderTurnState? completedTurnState;
      _turnUsage = LlmUsage();
      _turnUsageCommitted = false;
      await for (final event in _providerEvents(request)) {
        _throwIfCancelled();
        switch (event) {
          case LlmReasoningDelta(:final text):
            reasoning.write(text);
            _resetIdle();
            _emit(AgentReasoningDelta(text));
          case LlmTextDelta(:final text):
            answer.write(text);
            _resetIdle();
            _emit(AgentAnswerDelta(text));
          case LlmToolCallDelta():
            assembler.add(event);
            _resetIdle();
          case LlmUsageUpdate(:final usage):
            _onUsage(usage);
          case LlmCompleted(
            :final finishReason,
            :final usage,
            :final turnState,
          ):
            finish = finishReason;
            completedTurnState = turnState;
            if (usage != null) {
              _turnUsage = _mergeUsage(_turnUsage, usage);
            }
          case LlmFailed(:final error):
            throw AgentException(agentErrorFromLlm(error));
          case LlmCancelled():
            throw AgentException(
              AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
            );
        }
      }
      _throwIfCancelled();
      _commitTurnUsage();
      final calls = List<LlmToolCallPart>.unmodifiable(assembler.complete());
      try {
        assertResponsesTurnStateMatchesAssistant(
          state: completedTurnState,
          text: answer.toString(),
          calls: calls,
        );
      } on LlmException catch (error) {
        throw AgentException(agentErrorFromLlm(error.error));
      }
      final assistantParts = <LlmContentPart>[
        if (reasoning.isNotEmpty) LlmReasoningPart(reasoning.toString()),
        if (answer.isNotEmpty) LlmTextPart(answer.toString()),
        ...calls,
      ];
      if (assistantParts.isNotEmpty) {
        session.transcript = session.transcript.append(
          LlmMessage(role: LlmMessageRole.assistant, parts: assistantParts),
        );
        if (completedTurnState != null) {
          session.continuationEntries.add(
            LlmContinuationEntry(
              assistantMessageIndex: session.transcript.messages.length - 1,
              state: completedTurnState,
            ),
          );
        }
        await _checkpoint();
        _resetIdle();
      }
      await _runHooks((hook) => hook.afterModelTurn(_hookContext(turnId)));
      if (calls.isEmpty) {
        await _completeWith(
          AgentRunCompleted(finishReason: finish, usage: session.usage),
        );
        return;
      }
      if (_generation.reasoningMode == ReasoningMode.enabled &&
          selection.model.wireFamily == LlmWireFamily.openaiResponses &&
          (completedTurnState == null ||
              !responsesTurnStateHasEncryptedReasoning(completedTurnState))) {
        throwAgent(
          AgentErrorKind.protocol,
          'Reasoning-enabled Responses tool turns require encrypted continuation state.',
        );
      }
      _checkBudgetUnverifiable();
      _emit(AgentToolAssembled(calls));
      if (guards.maxToolCalls != null &&
          _runToolAttempts >= guards.maxToolCalls!) {
        throw _RunStop(AgentStopReason.toolCallLimit);
      }
      final results = <LlmToolResultPart>[];
      for (final call in calls) {
        _throwIfCancelled();
        if (!_executedCallIds.add(call.callId.value)) {
          throwAgent(
            AgentErrorKind.protocol,
            'Duplicate tool call id "${call.callId.value}".',
          );
        }
        if (guards.maxToolCalls != null &&
            _runToolAttempts >= guards.maxToolCalls!) {
          throw _RunStop(AgentStopReason.toolCallLimit);
        }
        _runToolAttempts += 1;
        session.toolAttempts += 1;
        final result = await _handleTool(turnId, call);
        results.add(result);
        session.transcript = session.transcript.append(
          LlmMessage(
            role: LlmMessageRole.tool,
            parts: <LlmContentPart>[result],
          ),
        );
        await _checkpoint();
        _resetIdle();
      }
      _noteCycle(calls: calls, results: results, answer: answer.toString());
      if (_noProgressCount == guards.noProgress.warningThreshold) {
        _emit(AgentNoProgressWarning(_noProgressCount));
      }
      if (_noProgressCount >= guards.noProgress.stopThreshold) {
        throw _RunStop(AgentStopReason.noProgress);
      }
      _checkBudgets(preWork: false);
      if (guards.maxModelTurns != null &&
          _runModelTurns >= guards.maxModelTurns!) {
        throw _RunStop(AgentStopReason.modelTurnLimit);
      }
      await _drainInbound();
    }
  }

  Future<LlmToolResultPart> _handleTool(
    TurnId turnId,
    LlmToolCallPart call,
  ) async {
    _throwIfCancelled();
    Map<String, Object?> arguments;
    try {
      arguments = decodeToolArguments(call.arguments);
    } on AgentException catch (error) {
      return _toolResult(
        callId: call.callId,
        success: false,
        content: jsonEncode(<String, Object?>{'error': error.error.message}),
      );
    }
    final enabled = session.definition.enabledTools.any(
      (id) => id.value == call.name,
    );
    final tool = session.runtime.tools.lookup(call.name);
    if (!enabled || tool == null) {
      return _toolResult(
        callId: call.callId,
        success: false,
        content: jsonEncode(<String, Object?>{
          'error': 'Unknown or disabled tool.',
        }),
      );
    }
    try {
      validateArguments(tool.descriptor.parameters, arguments);
    } on AgentException catch (error) {
      return _toolResult(
        callId: call.callId,
        success: false,
        content: jsonEncode(<String, Object?>{'error': error.error.message}),
      );
    }
    final invocation = ToolInvocation(
      callId: call.callId.value,
      name: call.name,
      arguments: arguments,
    );
    final policy = session.runtime.policies[session.definition.policy.value]!;
    late final ToolPermission permission;
    try {
      permission = policy.decide(invocation);
    } on Object {
      throw AgentException(sanitizedRuntimeError());
    }
    _emit(AgentPermissionDecision(callId: call.callId, permission: permission));
    var allowed = permission == ToolPermission.allow;
    if (permission == ToolPermission.ask) {
      final handler = session.runtime.approval;
      if (handler == null) {
        allowed = false;
      } else {
        try {
          allowed = await _awaitUnlessCancelled(handler.approve(invocation));
          _resetIdle();
        } on AgentException catch (error) {
          if (error.error.kind == AgentErrorKind.cancelled) {
            rethrow;
          }
          return _toolResult(
            callId: call.callId,
            success: false,
            content: jsonEncode(<String, Object?>{
              'error': sanitizePublicText(
                error.error.message,
                fallback: 'Tool execution failed.',
              ),
            }),
          );
        } on Object {
          return _toolResult(
            callId: call.callId,
            success: false,
            content: jsonEncode(<String, Object?>{
              'error': sanitizePublicText(
                null,
                fallback: 'Tool execution failed.',
              ),
            }),
          );
        }
      }
    }
    if (!allowed) {
      return _toolResult(
        callId: call.callId,
        success: false,
        content: jsonEncode(<String, Object?>{'error': 'Tool denied.'}),
      );
    }
    _throwIfCancelled();
    _emit(AgentToolStarted(callId: call.callId, name: call.name));
    _resetIdle();
    await _runHooks(
      (hook) =>
          hook.beforeTool(_hookContext(turnId, callId: call.callId.value)),
    );
    _throwIfCancelled();
    final liveness = _RunLiveness(this, call.callId);
    ToolExecutionResult? result;
    var executionAttempted = false;
    var cancelledDuringExecute = false;
    AgentException? executorAgentError;
    var executorFailed = false;
    try {
      executionAttempted = true;
      result = await _awaitUnlessCancelled(
        tool.executor.execute(
          invocation,
          cancellation: cancelSource.token,
          liveness: liveness,
        ),
      );
      if (cancelSource.token.isCancelled || _stopping || _terminated) {
        cancelledDuringExecute = true;
      }
    } on AgentException catch (error) {
      if (error.error.kind == AgentErrorKind.cancelled) {
        cancelledDuringExecute = true;
      } else {
        executorAgentError = error;
      }
    } on Object {
      executorFailed = true;
    }
    if (executionAttempted &&
        !cancelledDuringExecute &&
        !_stopping &&
        !_terminated) {
      _resetIdle();
      await _runHooks(
        (hook) =>
            hook.afterTool(_hookContext(turnId, callId: call.callId.value)),
      );
    }
    if (cancelledDuringExecute) {
      throw AgentException(
        AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
      );
    }
    if (executorAgentError != null || executorFailed || result == null) {
      return _toolResult(
        callId: call.callId,
        success: false,
        content: jsonEncode(<String, Object?>{
          'error': sanitizePublicText(
            executorAgentError?.error.message,
            fallback: 'Tool execution failed.',
          ),
        }),
      );
    }
    return _toolResult(
      callId: call.callId,
      success: result.success,
      content: result.success
          ? result.transcriptContent
          : jsonEncode(<String, Object?>{
              'error': sanitizePublicText(
                result.errorMessage,
                fallback: 'Tool execution failed.',
              ),
            }),
    );
  }

  LlmToolResultPart _toolResult({
    required ToolCallId callId,
    required bool success,
    required String content,
  }) {
    _emit(AgentToolFinished(callId: callId, success: success));
    return LlmToolResultPart(callId: callId, content: content);
  }

  Future<void> _drainInbound() async {
    final envelopes = session.runtime.router.drain(session.id);
    for (final envelope in envelopes) {
      session.transcript = session.transcript.append(envelope.payload);
      _inboundThisCycle = true;
      _resetIdle();
      _emit(
        AgentInboundMessageConsumed(
          source: envelope.source,
          message: envelope.payload,
          correlationId: envelope.correlationId,
          replyTo: envelope.replyTo,
        ),
      );
    }
    if (envelopes.isNotEmpty) {
      await _checkpoint();
    }
  }

  Future<void> _checkpoint() async {
    try {
      await session.checkpoint();
    } on AgentException catch (error) {
      if (error.error.kind == AgentErrorKind.cancelled) {
        rethrow;
      }
      throw AgentException(
        error.error.kind == AgentErrorKind.conflict
            ? error.error
            : sanitizedPersistenceError(),
      );
    }
    _throwIfCancelled();
    _resetIdle();
  }

  void _onUsage(LlmUsage usage) {
    _turnUsage = _mergeUsage(_turnUsage, usage);
    _resetIdle();
    _emit(AgentUsageUpdated(_addUsage(session.usage, _turnUsage)));
    _checkBudgets(preWork: false);
  }

  void _commitTurnUsage({bool checkBudget = true}) {
    if (_turnUsageCommitted) {
      return;
    }
    session.usage = _addUsage(session.usage, _turnUsage);
    _turnUsageCommitted = true;
    _emit(AgentUsageUpdated(session.usage));
    if (checkBudget) {
      _checkBudgets(preWork: false);
    }
  }

  LlmUsage _runScopedUsage(LlmUsage sessionUsage) {
    int? delta(int? current, int? baseline) {
      if (current == null) {
        return null;
      }
      if (baseline == null) {
        return current;
      }
      final value = current - baseline;
      return value < 0 ? 0 : value;
    }

    return LlmUsage(
      inputTokens: delta(sessionUsage.inputTokens, _usageBaseline.inputTokens),
      outputTokens: delta(
        sessionUsage.outputTokens,
        _usageBaseline.outputTokens,
      ),
      totalTokens: delta(sessionUsage.totalTokens, _usageBaseline.totalTokens),
      cacheHitTokens: delta(
        sessionUsage.cacheHitTokens,
        _usageBaseline.cacheHitTokens,
      ),
      cacheMissTokens: delta(
        sessionUsage.cacheMissTokens,
        _usageBaseline.cacheMissTokens,
      ),
    );
  }

  void _checkBudgets({required bool preWork}) {
    final sessionUsage = _turnUsageCommitted
        ? session.usage
        : _addUsage(session.usage, _turnUsage);
    final usage = _runScopedUsage(sessionUsage);
    void over(int? used, int? limit, AgentStopReason reason) {
      if (limit != null && used != null && used >= limit) {
        throw _RunStop(reason);
      }
    }

    over(
      usage.inputTokens,
      guards.inputTokenBudget,
      AgentStopReason.inputBudget,
    );
    over(
      usage.outputTokens,
      guards.outputTokenBudget,
      AgentStopReason.outputBudget,
    );
    over(
      usage.totalTokens,
      guards.totalTokenBudget,
      AgentStopReason.totalBudget,
    );
    if (!preWork) {
      return;
    }
    if (_runModelTurns > 0) {
      _checkBudgetUnverifiable(usage: usage);
    }
  }

  void _checkBudgetUnverifiable({LlmUsage? usage}) {
    final current = usage ?? _runScopedUsage(session.usage);
    bool unverifiable(int? used, int? limit) => limit != null && used == null;
    if (unverifiable(current.inputTokens, guards.inputTokenBudget) ||
        unverifiable(current.outputTokens, guards.outputTokenBudget) ||
        unverifiable(current.totalTokens, guards.totalTokenBudget)) {
      throwAgent(
        AgentErrorKind.budgetUnverifiable,
        'Configured token budget cannot be verified from provider usage.',
      );
    }
  }

  Stream<LlmEvent> _providerEvents(LlmRequest request) {
    late StreamController<LlmEvent> controller;
    StreamSubscription<LlmEvent>? subscription;
    CancellationRegistration? registration;
    var closed = false;

    void shutdown({LlmEvent? terminal}) {
      if (closed) {
        return;
      }
      closed = true;
      if (terminal != null && !controller.isClosed) {
        controller.add(terminal);
      }
      if (!controller.isClosed) {
        unawaited(controller.close());
      }
      _trackProviderTeardown(subscription?.cancel() ?? Future<void>.value());
    }

    controller = StreamController<LlmEvent>(
      onListen: () {
        subscription = session.runtime.registry
            .stream(request, cancellation: cancelSource.token)
            .listen(
              (event) {
                if (!controller.isClosed) {
                  controller.add(event);
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!controller.isClosed) {
                  controller.addError(error, stackTrace);
                }
              },
              onDone: () => shutdown(),
            );
        registration = cancelSource.token.register(() {
          shutdown(terminal: const LlmCancelled());
        });
      },
      onCancel: () {
        registration?.dispose();
        _trackProviderTeardown(subscription?.cancel() ?? Future<void>.value());
      },
    );
    return controller.stream;
  }

  void _noteCycle({
    required List<LlmToolCallPart> calls,
    required List<LlmToolResultPart> results,
    required String answer,
  }) {
    if (_inboundThisCycle || _progressMarker || answer.isNotEmpty) {
      _noProgressCount = 0;
      _lastFingerprint = null;
      _inboundThisCycle = false;
      _progressMarker = false;
      return;
    }
    final fingerprint = canonicalJsonEncode(<String, Object?>{
      'calls': [
        for (final call in calls)
          <String, Object?>{
            'name': call.name,
            'arguments': _canonicalArguments(call.arguments),
          },
      ],
      'results': [
        for (final result in results) _canonicalResult(result.content),
      ],
    });
    if (fingerprint == _lastFingerprint) {
      _noProgressCount += 1;
    } else {
      _noProgressCount = 1;
      _lastFingerprint = fingerprint;
    }
    _inboundThisCycle = false;
    _progressMarker = false;
  }

  Object? _canonicalArguments(String raw) {
    try {
      return canonicalizeJson(decodeToolArguments(raw));
    } on Object {
      return raw.trim();
    }
  }

  Object? _canonicalResult(String raw) {
    try {
      return canonicalizeJson(jsonDecode(raw));
    } on Object {
      return raw.trim();
    }
  }

  ResolvedRunGuards _resolveGuards() {
    final def = session.definition;
    final profile = session.runtime.profile;
    T? layer<T>({
      required QuotaOverride<T>? run,
      required bool definitionSpecified,
      required T? definitionValue,
      required T? profileValue,
    }) {
      return resolveSpecified(
        run: run,
        definitionSpecified: definitionSpecified,
        definitionValue: definitionValue,
        profileValue: profileValue,
      );
    }

    return ResolvedRunGuards(
      maxModelTurns: layer(
        run: options.maxModelTurns,
        definitionSpecified: def.limits != null,
        definitionValue: def.limits?.maxModelTurns,
        profileValue: profile.limits.maxModelTurns,
      ),
      maxToolCalls: layer(
        run: options.maxToolCalls,
        definitionSpecified: def.limits != null,
        definitionValue: def.limits?.maxToolCalls,
        profileValue: profile.limits.maxToolCalls,
      ),
      maxDuration: layer(
        run: options.maxDuration,
        definitionSpecified: def.limits != null,
        definitionValue: def.limits?.maxDuration,
        profileValue: profile.limits.maxDuration,
      ),
      maxOutputTokensPerTurn: layer(
        run: options.maxOutputTokensPerTurn,
        definitionSpecified: def.limits != null,
        definitionValue: def.limits?.maxOutputTokensPerTurn,
        profileValue: profile.limits.maxOutputTokensPerTurn,
      ),
      inputTokenBudget: layer(
        run: options.inputTokenBudget,
        definitionSpecified: def.budget != null,
        definitionValue: def.budget?.inputTokens,
        profileValue: profile.budget.inputTokens,
      ),
      outputTokenBudget: layer(
        run: options.outputTokenBudget,
        definitionSpecified: def.budget != null,
        definitionValue: def.budget?.outputTokens,
        profileValue: profile.budget.outputTokens,
      ),
      totalTokenBudget: layer(
        run: options.totalTokenBudget,
        definitionSpecified: def.budget != null,
        definitionValue: def.budget?.totalTokens,
        profileValue: profile.budget.totalTokens,
      ),
      idleTimeout: layer(
        run: options.idleTimeout,
        definitionSpecified: def.liveness != null,
        definitionValue: def.liveness?.idleTimeout,
        profileValue: profile.liveness.idleTimeout,
      ),
      noProgress: AgentNoProgressPolicy(
        warningThreshold:
            layer(
              run: options.noProgressWarning,
              definitionSpecified: def.noProgress != null,
              definitionValue: def.noProgress?.warningThreshold,
              profileValue: profile.noProgress.warningThreshold,
            ) ??
            5,
        stopThreshold:
            layer(
              run: options.noProgressStop,
              definitionSpecified: def.noProgress != null,
              definitionValue: def.noProgress?.stopThreshold,
              profileValue: profile.noProgress.stopThreshold,
            ) ??
            10,
      ),
    );
  }

  LlmGenerationConfig _resolveGeneration() {
    final definition = session.definition.generation;
    final override = options.reasoning;
    final mode = override?.mode ?? definition.reasoningMode;
    final effort = override?.effort ?? definition.reasoningEffort;
    return LlmGenerationConfig(
      reasoningMode: mode,
      reasoningEffort: effort,
      temperature: definition.temperature,
      maxOutputTokens:
          guards.maxOutputTokensPerTurn ?? definition.maxOutputTokens,
    );
  }

  void _armWatchdogs() {
    if (guards.maxDuration != null) {
      _durationTimer = session.runtime.clock.schedule(guards.maxDuration!, () {
        unawaited(_finishStop(AgentStopReason.durationLimit));
      });
    }
    _rescheduleIdle();
  }

  void _rescheduleIdle() {
    _idleTimer?.cancel();
    final timeout = guards.idleTimeout;
    if (timeout == null || _stopping || _terminated) {
      return;
    }
    _idleTimer = session.runtime.clock.schedule(timeout, () {
      unawaited(_finishStop(AgentStopReason.idleTimeout));
    });
  }

  void _resetIdle() {
    _rescheduleIdle();
  }

  void _checkDuration() {
    if (guards.maxDuration != null &&
        session.runtime.clock.elapsed - _runStartedAt >= guards.maxDuration!) {
      throw _RunStop(AgentStopReason.durationLimit);
    }
  }

  void _throwIfCancelled() {
    if (_terminated || _stopping) {
      throw AgentException(
        AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
      );
    }
    if (cancelSource.token.isCancelled) {
      throw AgentException(
        AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
      );
    }
  }

  Future<T> _awaitUnlessCancelled<T>(Future<T> future) async {
    final done = Completer<T>();
    unawaited(
      future.then(
        (value) {
          if (!done.isCompleted) {
            if (cancelSource.token.isCancelled || _terminated || _stopping) {
              done.completeError(
                AgentException(
                  AgentError(
                    kind: AgentErrorKind.cancelled,
                    message: 'cancelled',
                  ),
                ),
              );
            } else {
              done.complete(value);
            }
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!done.isCompleted) {
            if (cancelSource.token.isCancelled || _terminated || _stopping) {
              done.completeError(
                AgentException(
                  AgentError(
                    kind: AgentErrorKind.cancelled,
                    message: 'cancelled',
                  ),
                ),
              );
            } else {
              done.completeError(error, stackTrace);
            }
          }
        },
      ),
    );
    final registration = cancelSource.token.register(() {
      if (!done.isCompleted) {
        done.completeError(
          AgentException(
            AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
          ),
        );
      }
    });
    try {
      return await done.future;
    } finally {
      registration.dispose();
    }
  }

  Future<void> _runHooks(
    Future<void> Function(AgentLifecycleHook hook) invoke,
  ) async {
    try {
      for (final hook in session.runtime.hooks) {
        await invoke(hook);
      }
    } on AgentException catch (error) {
      if (error.error.kind == AgentErrorKind.cancelled) {
        rethrow;
      }
      throw AgentException(sanitizedRuntimeError());
    } on Object {
      throw AgentException(sanitizedRuntimeError());
    }
  }

  AgentHookContext _hookContext(TurnId turnId, {String? callId}) {
    return AgentHookContext(
      sessionId: session.id,
      runId: id,
      turnId: turnId,
      callId: callId,
      snapshot: session.snapshot,
    );
  }

  void _emit(AgentRunEvent event) {
    if (_controller.isClosed) {
      return;
    }
    if (event.isTerminal) {
      if (_terminated) {
        return;
      }
      _terminated = true;
      _stopping = true;
    } else if (_terminated) {
      return;
    }
    _controller.add(event);
  }

  bool _usesPersistenceShutdown(AgentRunEvent terminal) {
    if (terminal is AgentRunCancelled) {
      return true;
    }
    if (terminal is AgentRunStopped) {
      return terminal.reason == AgentStopReason.idleTimeout ||
          terminal.reason == AgentStopReason.durationLimit;
    }
    return false;
  }

  Future<void> _completeWith(
    AgentRunEvent terminal, {
    bool closeSession = false,
  }) async {
    final existing = _stopLock;
    if (existing != null) {
      await existing.future;
      return;
    }
    final lock = Completer<void>();
    _stopLock = lock;
    _stopping = true;
    cancelSource.cancel();
    _idleTimer?.cancel();
    _durationTimer?.cancel();
    try {
      _commitTurnUsage(checkBudget: false);
      session.freezeSnapshot();
      if (_usesPersistenceShutdown(terminal)) {
        final acknowledged = await session.runPersistenceShutdown();
        _emit(terminal);
        _finishPersistenceBarrier(
          acknowledged: acknowledged,
          closeSession: closeSession,
        );
        return;
      }
      if (terminal is AgentRunFailed &&
          (terminal.error.kind == AgentErrorKind.persistence ||
              terminal.error.kind == AgentErrorKind.conflict)) {
        _emit(terminal);
        _closeAfter = true;
        return;
      }
      try {
        await session.checkpoint();
      } on AgentException catch (error) {
        if (session.persistenceShutdownStarted) {
          final acknowledged = await session.runPersistenceShutdown();
          if (acknowledged) {
            _emit(terminal);
            _finishPersistenceBarrier(
              acknowledged: true,
              closeSession: closeSession,
            );
            return;
          }
        }
        _emit(
          AgentRunFailed(
            error.error.kind == AgentErrorKind.conflict
                ? error.error
                : sanitizedPersistenceError(),
          ),
        );
        _closeAfter = true;
        return;
      } on Object {
        if (session.persistenceShutdownStarted) {
          final acknowledged = await session.runPersistenceShutdown();
          if (acknowledged) {
            _emit(terminal);
            _finishPersistenceBarrier(
              acknowledged: true,
              closeSession: closeSession,
            );
            return;
          }
        }
        _emit(AgentRunFailed(sanitizedPersistenceError()));
        _closeAfter = true;
        return;
      }
      _emit(terminal);
      if (closeSession || session.persistenceUnreliable) {
        _closeAfter = true;
      } else {
        session.clearFrozenSnapshot();
      }
    } finally {
      if (!lock.isCompleted) {
        lock.complete();
      }
    }
  }

  void _finishPersistenceBarrier({
    required bool acknowledged,
    required bool closeSession,
  }) {
    if (!acknowledged || closeSession) {
      _closeAfter = true;
      return;
    }
    if (!session.isClosing) {
      session.clearPersistenceShutdown();
    }
  }

  Future<void> _finishStop(AgentStopReason reason) {
    _commitTurnUsage(checkBudget: false);
    if (reason == AgentStopReason.idleTimeout ||
        reason == AgentStopReason.durationLimit) {
      session.beginPersistenceShutdown();
    }
    return _completeWith(AgentRunStopped(reason, usage: session.usage));
  }

  Future<void> _fail(AgentError error, {bool closeSession = false}) async {
    if (error.kind == AgentErrorKind.cancelled) {
      await _completeWith(const AgentRunCancelled());
      return;
    }
    final close =
        closeSession ||
        error.kind == AgentErrorKind.persistence ||
        error.kind == AgentErrorKind.conflict;
    await _completeWith(AgentRunFailed(error), closeSession: close);
  }
}

final class _RunStop implements Exception {
  _RunStop(this.reason);

  final AgentStopReason reason;
}

AgentException _cancelledException() {
  return AgentException(
    AgentError(kind: AgentErrorKind.cancelled, message: 'cancelled'),
  );
}

final class _RunLiveness implements ToolExecutionLiveness {
  _RunLiveness(this.run, this.callId);

  final _LiveRun run;
  final ToolCallId callId;

  @override
  void reportProgress({String? detail}) {
    run._progressMarker = true;
    run._resetIdle();
    run._emit(
      AgentToolProgress(
        callId: callId,
        detail: detail == null
            ? null
            : sanitizePublicText(detail, fallback: 'Tool reported progress.'),
      ),
    );
  }
}

final class _ToolCallAssembler {
  final Map<int, _Acc> _byIndex = <int, _Acc>{};
  final Map<String, int> _indexByCallId = <String, int>{};

  void add(LlmToolCallDelta delta) {
    final existingIndex = _indexByCallId[delta.callId.value];
    if (existingIndex != null && existingIndex != delta.index) {
      throwAgent(
        AgentErrorKind.protocol,
        'Tool call id "${delta.callId.value}" changed index.',
      );
    }
    final existing = _byIndex[delta.index];
    if (existing != null && existing.callId != delta.callId) {
      throwAgent(
        AgentErrorKind.protocol,
        'Tool call index ${delta.index} changed id.',
      );
    }
    final acc = existing ?? _Acc(delta.callId, delta.index);
    _byIndex[delta.index] = acc;
    _indexByCallId[delta.callId.value] = delta.index;
    if (delta.name != null) {
      acc.name.write(delta.name);
    }
    if (delta.argumentsFragment != null) {
      acc.args.write(delta.argumentsFragment);
    }
  }

  List<LlmToolCallPart> complete() {
    final indexes = _byIndex.keys.toList()..sort();
    final seen = <String>{};
    return [
      for (final index in indexes)
        () {
          final acc = _byIndex[index]!;
          if (!seen.add(acc.callId.value)) {
            throwAgent(
              AgentErrorKind.protocol,
              'Duplicate tool call id "${acc.callId.value}".',
            );
          }
          return LlmToolCallPart(
            callId: acc.callId,
            name: acc.name.toString(),
            arguments: acc.args.toString(),
          );
        }(),
    ];
  }
}

final class _Acc {
  _Acc(this.callId, this.index);

  final ToolCallId callId;
  final int index;
  final StringBuffer name = StringBuffer();
  final StringBuffer args = StringBuffer();
}

LlmMessage _userMessageFromString(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    throwAgent(AgentErrorKind.configuration, 'Run input must not be blank.');
  }
  return LlmMessage(
    role: LlmMessageRole.user,
    parts: <LlmContentPart>[LlmTextPart(text)],
  );
}

LlmMessage _requireUser(LlmMessage input) {
  if (input.role != LlmMessageRole.user) {
    throwAgent(
      AgentErrorKind.configuration,
      'Run input must be a user-role message.',
    );
  }
  return input;
}

LlmUsage _mergeUsage(LlmUsage current, LlmUsage incoming) {
  return LlmUsage(
    inputTokens: incoming.inputTokens ?? current.inputTokens,
    outputTokens: incoming.outputTokens ?? current.outputTokens,
    totalTokens: incoming.totalTokens ?? current.totalTokens,
    cacheHitTokens: incoming.cacheHitTokens ?? current.cacheHitTokens,
    cacheMissTokens: incoming.cacheMissTokens ?? current.cacheMissTokens,
  );
}

LlmUsage _addUsage(LlmUsage current, LlmUsage incoming) {
  int? add(int? a, int? b) {
    if (a == null && b == null) {
      return null;
    }
    return (a ?? 0) + (b ?? 0);
  }

  return LlmUsage(
    inputTokens: add(current.inputTokens, incoming.inputTokens),
    outputTokens: add(current.outputTokens, incoming.outputTokens),
    totalTokens: add(current.totalTokens, incoming.totalTokens),
    cacheHitTokens: add(current.cacheHitTokens, incoming.cacheHitTokens),
    cacheMissTokens: add(current.cacheMissTokens, incoming.cacheMissTokens),
  );
}

final class _CancelSettlement {
  const _CancelSettlement.ok() : error = null, stackTrace = null;

  const _CancelSettlement.failed(this.error, this.stackTrace);

  final Object? error;
  final StackTrace? stackTrace;
}

Future<_CancelSettlement> _observeCancel(Future<void> future) {
  final captured = Completer<_CancelSettlement>();
  future.then<void>(
    (_) {
      if (!captured.isCompleted) {
        captured.complete(const _CancelSettlement.ok());
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      if (!captured.isCompleted) {
        captured.complete(_CancelSettlement.failed(error, stackTrace));
      }
    },
  );
  return captured.future;
}

Future<void> _closeRunController<T>(StreamController<T> controller) async {
  if (controller.isClosed) {
    return;
  }
  if (controller.hasListener) {
    await controller.close();
  } else {
    unawaited(controller.close());
  }
}
