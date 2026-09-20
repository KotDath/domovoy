import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/cancellation.dart';
import '../../../core/llm/messages.dart';
import '../../../core/memory/memory.dart';
import '../../../core/projects/ids.dart';
import 'memory_inspector_state.dart';

/// Application controller behind the memory inspector.
///
/// It reads the independent memory namespaces, performs host-owned candidate
/// confirmation/edit/rejection, entry forgetting, read-toggle and trace
/// preview, and manual extraction. It never mutates the chat transcript.
final class MemoryInspectorController extends ChangeNotifier
    implements MemoryReadToggles {
  MemoryInspectorController({
    required this.repositories,
    required this.retrieval,
    required this.toggles,
    this.extraction,
    this.entryIds,
    int Function()? nowMicros,
  }) : _nowMicros = nowMicros ?? (() => DateTime.now().microsecondsSinceEpoch),
       _state = MemoryInspectorState(
         status: MemoryInspectorStatus.loading,
         includeWorking: toggles.includeWorking,
         includeLongTerm: toggles.includeLongTerm,
       );

  final MemoryRepositories repositories;
  final MemoryRetrievalService retrieval;
  final MemoryReadTogglesController toggles;
  final MemoryExtractionCoordinator? extraction;
  final String Function()? entryIds;
  final int Function() _nowMicros;

  MemoryInspectorState _state;
  var _disposed = false;
  var _refreshGeneration = 0;
  var _traceGeneration = 0;
  AgentSessionSnapshot? _session;
  ProjectId? _projectId;
  String _query = '';

  MemoryInspectorState get state => _state;

  bool get canAnalyze =>
      extraction != null && _session != null && _projectId != null;

  @override
  bool get includeWorking => toggles.includeWorking;

  @override
  bool get includeLongTerm => toggles.includeLongTerm;

  /// Binds the currently visible chat/project and refreshes stored memory.
  Future<void> attachSession({
    required AgentSessionSnapshot? session,
    required ProjectId? projectId,
  }) async {
    final previousSession = _session;
    final sessionChanged =
        previousSession?.id != session?.id || _projectId != projectId;
    final completedSnapshotChanged =
        !sessionChanged &&
        session != null &&
        session.lifecycle == AgentSessionLifecycle.idle &&
        previousSession?.revision != session.revision;
    _session = session;
    _projectId = projectId;
    _emit(
      _state.copyWith(
        shortTerm: _shortTermPreviews(session),
        projectId: projectId,
        sessionId: session?.id,
      ),
    );
    if (sessionChanged || completedSnapshotChanged) {
      if (session != null && projectId != null) {
        await _resumeAttachedSession(session, projectId);
      }
      await refresh();
    }
  }

  Future<void> refresh() async {
    final projectId = _projectId;
    final sessionId = _session?.id;
    final generation = ++_refreshGeneration;
    final cancellation = CancellationSource().token;
    _emit(_state.copyWith(status: MemoryInspectorStatus.loading));
    try {
      final working = projectId == null
          ? const <MemoryEntry>[]
          : await repositories.workingRepository.list(
              projectId: projectId,
              cancellation: cancellation,
            );
      final longTerm = await repositories.longTermRepository.list(
        cancellation: cancellation,
      );
      final pending = await repositories.candidateRepository.list(
        status: MemoryCandidateStatus.pending,
        cancellation: cancellation,
      );
      final candidates = pending
          .where(
            (candidate) =>
                candidate.projectId == null || candidate.projectId == projectId,
          )
          .toList(growable: false);
      final trace = await _planTrace(projectId);
      if (!_isCurrentRefresh(generation, sessionId, projectId)) {
        return;
      }
      _emit(
        _state.copyWith(
          status: MemoryInspectorStatus.ready,
          error: null,
          working: working,
          longTerm: longTerm,
          candidates: candidates,
          trace: trace,
        ),
      );
    } on MemoryException catch (error) {
      if (!_isCurrentRefresh(generation, sessionId, projectId)) {
        return;
      }
      _emit(
        _state.copyWith(
          status: MemoryInspectorStatus.failed,
          error: error.error.message,
          busy: false,
        ),
      );
    } on Object {
      if (!_isCurrentRefresh(generation, sessionId, projectId)) {
        return;
      }
      _emit(
        _state.copyWith(
          status: MemoryInspectorStatus.failed,
          error: sanitizedMemoryPersistenceError().message,
          busy: false,
        ),
      );
    }
  }

  void selectLayer(MemoryLayerView layer) {
    _emit(_state.copyWith(selectedLayer: layer));
  }

  void setTraceVisible(bool visible) {
    _emit(_state.copyWith(traceVisible: visible));
  }

  Future<void> setIncludeWorking(bool value) async {
    if (toggles.includeWorking == value) return;
    toggles.setIncludeWorking(value);
    _emit(_state.copyWith(includeWorking: value));
    await _refreshTrace();
  }

  Future<void> setIncludeLongTerm(bool value) async {
    if (toggles.includeLongTerm == value) return;
    toggles.setIncludeLongTerm(value);
    _emit(_state.copyWith(includeLongTerm: value));
    await _refreshTrace();
  }

  Future<void> setQuery(String query) async {
    _query = query;
    await _refreshTrace();
  }

  Future<void> confirmCandidate(MemoryCandidate candidate) async {
    if (_state.busy) return;
    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    final now = _nowMicros();
    try {
      final accepted = candidate.confirm(updatedAtMicros: now);
      final repository = repositories.entryRepository(candidate.layer);
      if (candidate.operation == MemoryProposalOperation.update) {
        final targetId = candidate.targetEntryId;
        final target = targetId == null
            ? null
            : await repository.load(targetId, cancellation: cancellation);
        if (target == null) {
          throw MemoryException(sanitizedMemoryNotFoundError());
        }
        final sourceValues = target.sourceIds
            .map((source) => source.value)
            .toSet();
        final entry = target.revise(
          content: accepted.content,
          kind: accepted.kind,
          sourceIds: <MemorySourceId>[
            ...target.sourceIds,
            ...accepted.sourceIds.where(
              (source) => sourceValues.add(source.value),
            ),
          ],
          updatedAtMicros: now,
        );
        await repository.save(
          entry,
          expectedRevision: target.revision,
          cancellation: cancellation,
        );
      } else {
        final entry = memoryEntryFromCandidate(
          candidate: accepted,
          entryId: MemoryEntryId(
            entryIds?.call() ?? 'memory-entry-${candidate.id.value}',
          ),
          revision: 0,
          createdAtMicros: now,
          updatedAtMicros: now,
        );
        await _saveCreatedEntry(repository, entry, cancellation: cancellation);
      }
      await repositories.candidateRepository.save(
        accepted,
        expectedRevision: candidate.revision,
        cancellation: cancellation,
      );
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      _emit(_state.copyWith(busy: false, error: error.error.message));
    } on Object {
      _emit(
        _state.copyWith(
          busy: false,
          error: sanitizedMemoryPersistenceError().message,
        ),
      );
    }
  }

  Future<void> rejectCandidate(MemoryCandidate candidate) async {
    if (_state.busy) return;
    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    try {
      final rejected = candidate.reject(updatedAtMicros: _nowMicros());
      await repositories.candidateRepository.save(
        rejected,
        expectedRevision: candidate.revision,
        cancellation: cancellation,
      );
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      _emit(_state.copyWith(busy: false, error: error.error.message));
    } on Object {
      _emit(
        _state.copyWith(
          busy: false,
          error: sanitizedMemoryPersistenceError().message,
        ),
      );
    }
  }

  Future<void> editCandidate(
    MemoryCandidate candidate, {
    String? content,
    MemoryKind? kind,
  }) async {
    if (_state.busy) return;
    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    try {
      final edited = candidate.edit(
        content: content,
        kind: kind,
        updatedAtMicros: _nowMicros(),
      );
      await repositories.candidateRepository.save(
        edited,
        expectedRevision: candidate.revision,
        cancellation: cancellation,
      );
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      _emit(_state.copyWith(busy: false, error: error.error.message));
    } on Object {
      _emit(
        _state.copyWith(
          busy: false,
          error: sanitizedMemoryPersistenceError().message,
        ),
      );
    }
  }

  Future<void> forgetEntry(MemoryEntry entry) async {
    if (_state.busy) return;
    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    try {
      final forgotten = entry.forget(updatedAtMicros: _nowMicros());
      await repositories
          .entryRepository(entry.layer)
          .save(
            forgotten,
            expectedRevision: entry.revision,
            cancellation: cancellation,
          );
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      _emit(_state.copyWith(busy: false, error: error.error.message));
    } on Object {
      _emit(
        _state.copyWith(
          busy: false,
          error: sanitizedMemoryPersistenceError().message,
        ),
      );
    }
  }

  Future<void> editEntry(
    MemoryEntry entry, {
    String? content,
    MemoryKind? kind,
  }) async {
    if (_state.busy) return;
    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    try {
      final revised = entry.revise(
        content: content,
        kind: kind,
        updatedAtMicros: _nowMicros(),
      );
      await repositories
          .entryRepository(entry.layer)
          .save(
            revised,
            expectedRevision: entry.revision,
            cancellation: cancellation,
          );
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      _emit(_state.copyWith(busy: false, error: error.error.message));
    } on Object {
      _emit(
        _state.copyWith(
          busy: false,
          error: sanitizedMemoryPersistenceError().message,
        ),
      );
    }
  }

  /// Clears one persistent inspector surface while preserving append-only
  /// audit history. Entries are forgotten; pending candidates are rejected.
  Future<void> clearLayer(MemoryLayerView layer) async {
    if (_state.busy || layer == MemoryLayerView.shortTerm) return;
    final entries = switch (layer) {
      MemoryLayerView.working => _state.working,
      MemoryLayerView.longTerm => _state.longTerm,
      MemoryLayerView.shortTerm ||
      MemoryLayerView.candidates => const <MemoryEntry>[],
    };
    final candidates = layer == MemoryLayerView.candidates
        ? _state.candidates
        : const <MemoryCandidate>[];
    if (entries.isEmpty && candidates.isEmpty) return;

    _emit(_state.copyWith(busy: true, error: null));
    final cancellation = CancellationSource().token;
    try {
      for (final entry in entries) {
        final forgotten = entry.forget(updatedAtMicros: _nowMicros());
        await repositories
            .entryRepository(entry.layer)
            .save(
              forgotten,
              expectedRevision: entry.revision,
              cancellation: cancellation,
            );
      }
      for (final candidate in candidates) {
        final rejected = candidate.reject(updatedAtMicros: _nowMicros());
        await repositories.candidateRepository.save(
          rejected,
          expectedRevision: candidate.revision,
          cancellation: cancellation,
        );
      }
      _emit(_state.copyWith(busy: false));
      await refresh();
    } on MemoryException catch (error) {
      await _refreshAfterClearFailure(error.error.message);
    } on Object {
      await _refreshAfterClearFailure(
        sanitizedMemoryPersistenceError().message,
      );
    }
  }

  Future<void> _refreshAfterClearFailure(String message) async {
    _emit(_state.copyWith(busy: false));
    await refresh();
    _emit(_state.copyWith(error: message, busy: false));
  }

  /// Manual `Analyze now` over the current session transcript.
  Future<void> analyzeNow() async {
    final coordinator = extraction;
    final session = _session;
    final projectId = _projectId;
    if (coordinator == null ||
        session == null ||
        projectId == null ||
        _state.analysisBusy) {
      return;
    }
    _emit(_state.copyWith(analysisBusy: true, error: null));
    try {
      final result = await coordinator.analyzeNow(
        sessionId: session.id,
        projectId: projectId,
        completedSources: _extractionSources(session),
      );
      _emit(
        _state.copyWith(analysisBusy: false, extractionStatus: result.status),
      );
      await refresh();
    } on Object {
      _emit(
        _state.copyWith(
          analysisBusy: false,
          extractionStatus: MemoryExtractionStatus.failed,
        ),
      );
    }
  }

  /// Records one successfully completed chat turn without delaying the chat
  /// command that produced it.
  Future<void> recordCompletedTurn(AgentSessionSnapshot session) async {
    final coordinator = extraction;
    final projectId =
        session.projectId ?? (_session?.id == session.id ? _projectId : null);
    if (coordinator == null || projectId == null || _disposed) return;
    if (_session?.id == session.id) {
      _session = session;
      _emit(_state.copyWith(shortTerm: _shortTermPreviews(session)));
    }
    try {
      final result = await coordinator.onCompletedTurn(
        sessionId: session.id,
        projectId: projectId,
        completedSources: _extractionSources(session),
      );
      if (_session?.id == session.id && _projectId == projectId) {
        _emit(_state.copyWith(extractionStatus: result.status));
        await refresh();
      }
    } on Object {
      if (_session?.id == session.id && _projectId == projectId) {
        _emit(_state.copyWith(extractionStatus: MemoryExtractionStatus.failed));
      }
    }
  }

  /// Pauses foreground extraction (mobile lifecycle).
  void pauseExtraction() {
    final coordinator = extraction;
    final session = _session;
    if (coordinator == null || session == null) return;
    coordinator.pause(session.id);
  }

  /// Resumes extraction and flushes anything overdue in the foreground.
  Future<void> resumeExtraction() async {
    final coordinator = extraction;
    final session = _session;
    final projectId = _projectId;
    if (coordinator == null || session == null || projectId == null) return;
    try {
      final result = await coordinator.resume(
        sessionId: session.id,
        projectId: projectId,
        completedSources: _extractionSources(session),
      );
      _emit(_state.copyWith(extractionStatus: result.status));
      await refresh();
    } on Object {
      _emit(_state.copyWith(extractionStatus: MemoryExtractionStatus.failed));
    }
  }

  Future<void> _refreshTrace() async {
    final generation = ++_traceGeneration;
    final projectId = _projectId;
    try {
      final trace = await _planTrace(projectId);
      if (generation != _traceGeneration || projectId != _projectId) return;
      _emit(_state.copyWith(trace: trace, error: null));
    } on MemoryException catch (error) {
      if (generation != _traceGeneration || projectId != _projectId) return;
      _emit(_state.copyWith(error: error.error.message));
    } on Object {
      if (generation != _traceGeneration || projectId != _projectId) return;
      _emit(_state.copyWith(error: sanitizedMemoryPersistenceError().message));
    }
  }

  Future<void> _resumeAttachedSession(
    AgentSessionSnapshot session,
    ProjectId projectId,
  ) async {
    final coordinator = extraction;
    if (coordinator == null || _disposed) return;
    try {
      final result = await coordinator.resume(
        sessionId: session.id,
        projectId: projectId,
        completedSources: _extractionSources(session),
      );
      if (_session?.id == session.id && _projectId == projectId) {
        _emit(_state.copyWith(extractionStatus: result.status));
        if (result.isExtracted) await refresh();
      }
    } on Object {
      if (_session?.id == session.id && _projectId == projectId) {
        _emit(_state.copyWith(extractionStatus: MemoryExtractionStatus.failed));
      }
    }
  }

  Future<void> _saveCreatedEntry(
    MemoryEntryRepository repository,
    MemoryEntry entry, {
    required CancellationToken cancellation,
  }) async {
    try {
      await repository.save(
        entry,
        expectedRevision: 0,
        cancellation: cancellation,
      );
    } on MemoryException catch (error) {
      if (error.error.kind != MemoryErrorKind.conflict) rethrow;
      final existing = await repository.load(
        entry.id,
        cancellation: cancellation,
      );
      if (existing == null || !_sameCreatedEntry(existing, entry)) rethrow;
    }
  }

  bool _sameCreatedEntry(MemoryEntry existing, MemoryEntry expected) {
    return existing.revision == 0 &&
        existing.isActive &&
        existing.layer == expected.layer &&
        existing.scope == expected.scope &&
        existing.kind == expected.kind &&
        existing.content == expected.content &&
        existing.projectId == expected.projectId &&
        listEquals(existing.sourceIds, expected.sourceIds);
  }

  bool _isCurrentRefresh(
    int generation,
    AgentSessionId? sessionId,
    ProjectId? projectId,
  ) {
    return !_disposed &&
        generation == _refreshGeneration &&
        _session?.id == sessionId &&
        _projectId == projectId;
  }

  Future<MemoryContextTrace?> _planTrace(ProjectId? projectId) async {
    if (projectId == null) {
      return null;
    }
    final plan = await retrieval.planRead(
      MemoryReadRequest(
        projectId: projectId,
        query: _query,
        includeWorking: toggles.includeWorking,
        includeLongTerm: toggles.includeLongTerm,
      ),
    );
    return MemoryContextTrace(
      records: plan.trace,
      renderedCharacters: renderMemoryBlock(plan).runes.length,
      budgetCharacters: plan.budgetCharacters,
      truncated: plan.truncated,
    );
  }

  List<MemorySourcePreview> _shortTermPreviews(AgentSessionSnapshot? session) {
    if (session == null) {
      return const <MemorySourcePreview>[];
    }
    final messages = session.transcript.messages;
    final ids = session.transcript.messageIds;
    final previews = <MemorySourcePreview>[];
    for (var index = 0; index < messages.length; index += 1) {
      final message = messages[index];
      if (message.role == LlmMessageRole.tool) {
        continue;
      }
      final text = _messageText(message);
      if (text.isEmpty) {
        continue;
      }
      previews.add(
        MemorySourcePreview(
          id: index < ids.length ? ids[index]?.value : null,
          role: message.role == LlmMessageRole.assistant
              ? MemoryTranscriptRole.assistant
              : MemoryTranscriptRole.user,
          text: text,
        ),
      );
    }
    return previews;
  }

  List<MemoryExtractionSource> _extractionSources(
    AgentSessionSnapshot session,
  ) {
    final messages = session.transcript.messages;
    final ids = session.transcript.messageIds;
    final sources = <MemoryExtractionSource>[];
    for (var index = 0; index < messages.length; index += 1) {
      final message = messages[index];
      if (message.role == LlmMessageRole.tool) {
        continue;
      }
      final text = _messageText(message);
      if (text.isEmpty) {
        continue;
      }
      final id = index < ids.length ? ids[index]?.value : null;
      sources.add(
        MemoryExtractionSource(
          id: MemorySourceId(id ?? 'index-$index'),
          role: message.role == LlmMessageRole.assistant
              ? MemoryTranscriptRole.assistant
              : MemoryTranscriptRole.user,
          text: text,
        ),
      );
    }
    return sources;
  }

  String _messageText(LlmMessage message) {
    final buffer = StringBuffer();
    for (final part in message.parts) {
      if (part is LlmTextPart) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(part.text);
      }
    }
    return buffer.toString().trim();
  }

  void _emit(MemoryInspectorState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _refreshGeneration += 1;
    _traceGeneration += 1;
    extraction?.dispose();
    super.dispose();
  }
}
