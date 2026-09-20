import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/memory/memory.dart';
import '../../../core/projects/ids.dart';

enum MemoryInspectorStatus { loading, ready, failed }

/// The four observable memory surfaces of the inspector.
enum MemoryLayerView { shortTerm, working, longTerm, candidates }

/// A read-only short-term transcript message preview.
final class MemorySourcePreview {
  const MemorySourcePreview({
    required this.id,
    required this.role,
    required this.text,
  });

  final String? id;
  final MemoryTranscriptRole role;
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemorySourcePreview &&
          other.id == id &&
          other.role == role &&
          other.text == text;

  @override
  int get hashCode => Object.hash(id, role, text);
}

final class MemoryInspectorState {
  MemoryInspectorState({
    required this.status,
    this.busy = false,
    this.error,
    this.selectedLayer = MemoryLayerView.shortTerm,
    List<MemorySourcePreview> shortTerm = const <MemorySourcePreview>[],
    List<MemoryEntry> working = const <MemoryEntry>[],
    List<MemoryEntry> longTerm = const <MemoryEntry>[],
    List<MemoryCandidate> candidates = const <MemoryCandidate>[],
    this.includeWorking = true,
    this.includeLongTerm = true,
    this.traceVisible = false,
    this.trace,
    this.extractionStatus,
    this.analysisBusy = false,
    this.projectId,
    this.sessionId,
  }) : shortTerm = List<MemorySourcePreview>.unmodifiable(shortTerm),
       working = List<MemoryEntry>.unmodifiable(working),
       longTerm = List<MemoryEntry>.unmodifiable(longTerm),
       candidates = List<MemoryCandidate>.unmodifiable(candidates);

  factory MemoryInspectorState.initial() =>
      MemoryInspectorState(status: MemoryInspectorStatus.loading);

  final MemoryInspectorStatus status;
  final bool busy;
  final String? error;
  final MemoryLayerView selectedLayer;
  final List<MemorySourcePreview> shortTerm;
  final List<MemoryEntry> working;
  final List<MemoryEntry> longTerm;
  final List<MemoryCandidate> candidates;
  final bool includeWorking;
  final bool includeLongTerm;
  final bool traceVisible;
  final MemoryContextTrace? trace;
  final MemoryExtractionStatus? extractionStatus;
  final bool analysisBusy;
  final ProjectId? projectId;
  final AgentSessionId? sessionId;

  bool get isEmpty => switch (selectedLayer) {
    MemoryLayerView.shortTerm => shortTerm.isEmpty,
    MemoryLayerView.working => working.isEmpty,
    MemoryLayerView.longTerm => longTerm.isEmpty,
    MemoryLayerView.candidates => candidates.isEmpty,
  };

  MemoryInspectorState copyWith({
    MemoryInspectorStatus? status,
    bool? busy,
    Object? error = _keep,
    MemoryLayerView? selectedLayer,
    List<MemorySourcePreview>? shortTerm,
    List<MemoryEntry>? working,
    List<MemoryEntry>? longTerm,
    List<MemoryCandidate>? candidates,
    bool? includeWorking,
    bool? includeLongTerm,
    bool? traceVisible,
    Object? trace = _keep,
    Object? extractionStatus = _keep,
    bool? analysisBusy,
    Object? projectId = _keep,
    Object? sessionId = _keep,
  }) {
    return MemoryInspectorState(
      status: status ?? this.status,
      busy: busy ?? this.busy,
      error: identical(error, _keep) ? this.error : error as String?,
      selectedLayer: selectedLayer ?? this.selectedLayer,
      shortTerm: shortTerm ?? this.shortTerm,
      working: working ?? this.working,
      longTerm: longTerm ?? this.longTerm,
      candidates: candidates ?? this.candidates,
      includeWorking: includeWorking ?? this.includeWorking,
      includeLongTerm: includeLongTerm ?? this.includeLongTerm,
      traceVisible: traceVisible ?? this.traceVisible,
      trace: identical(trace, _keep)
          ? this.trace
          : trace as MemoryContextTrace?,
      extractionStatus: identical(extractionStatus, _keep)
          ? this.extractionStatus
          : extractionStatus as MemoryExtractionStatus?,
      analysisBusy: analysisBusy ?? this.analysisBusy,
      projectId: identical(projectId, _keep)
          ? this.projectId
          : projectId as ProjectId?,
      sessionId: identical(sessionId, _keep)
          ? this.sessionId
          : sessionId as AgentSessionId?,
    );
  }

  static const _keep = Object();
}

final class MemoryReadTogglesController extends ChangeNotifier
    implements MemoryReadToggles {
  MemoryReadTogglesController({
    bool includeWorking = true,
    bool includeLongTerm = true,
  }) : _includeWorking = includeWorking,
       _includeLongTerm = includeLongTerm;

  bool _includeWorking;
  bool _includeLongTerm;

  @override
  bool get includeWorking => _includeWorking;

  @override
  bool get includeLongTerm => _includeLongTerm;

  void setIncludeWorking(bool value) {
    if (_includeWorking == value) return;
    _includeWorking = value;
    notifyListeners();
  }

  void setIncludeLongTerm(bool value) {
    if (_includeLongTerm == value) return;
    _includeLongTerm = value;
    notifyListeners();
  }
}
