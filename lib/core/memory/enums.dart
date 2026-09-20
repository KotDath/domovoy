import 'errors.dart';

/// The two durable memory layers. The short-term layer is the agent transcript
/// and deliberately has no record type here.
enum MemoryLayer { working, longTerm }

/// Ownership scope of a memory record.
enum MemoryScope { project, global }

/// Semantic kind of a confirmed memory record.
enum MemoryKind {
  requirement,
  decision,
  fact,
  preference,
  procedure,
  profile,
  policy,
}

/// Lifecycle of a confirmed memory entry.
enum MemoryEntryStatus { active, forgotten }

/// Lifecycle of an untrusted extraction candidate.
enum MemoryCandidateStatus { pending, accepted, rejected }

/// Operation proposed by an extraction candidate.
enum MemoryProposalOperation { create, update, noop }

/// Whether a considered record was supplied to the provider.
enum MemoryReadDisposition { included, excluded }

/// Deterministic reason a record was included or excluded from a read plan.
enum MemoryReadReason {
  workingPriority,
  confirmedPreference,
  lexicalMatch,
  budgetExceeded,
  layerDisabled,
  forgotten,
  projectMismatch,
  notSelected,
}

T parseMemoryEnum<T extends Enum>(List<T> values, String name, String label) {
  final match = values.where((value) => value.name == name).firstOrNull;
  if (match == null) {
    throwMemory(MemoryErrorKind.protocol, 'Unknown $label "$name".');
  }
  return match;
}

extension MemoryLayerCodec on MemoryLayer {
  static MemoryLayer parse(String name) =>
      parseMemoryEnum(MemoryLayer.values, name, 'memory layer');
}

extension MemoryScopeCodec on MemoryScope {
  static MemoryScope parse(String name) =>
      parseMemoryEnum(MemoryScope.values, name, 'memory scope');
}

extension MemoryKindCodec on MemoryKind {
  static MemoryKind parse(String name) =>
      parseMemoryEnum(MemoryKind.values, name, 'memory kind');
}

extension MemoryEntryStatusCodec on MemoryEntryStatus {
  static MemoryEntryStatus parse(String name) =>
      parseMemoryEnum(MemoryEntryStatus.values, name, 'memory entry status');
}

extension MemoryCandidateStatusCodec on MemoryCandidateStatus {
  static MemoryCandidateStatus parse(String name) => parseMemoryEnum(
    MemoryCandidateStatus.values,
    name,
    'memory candidate status',
  );
}

extension MemoryProposalOperationCodec on MemoryProposalOperation {
  static MemoryProposalOperation parse(String name) => parseMemoryEnum(
    MemoryProposalOperation.values,
    name,
    'memory proposal operation',
  );
}

extension MemoryReadReasonCodec on MemoryReadReason {
  static MemoryReadReason parse(String name) =>
      parseMemoryEnum(MemoryReadReason.values, name, 'memory read reason');
}

extension MemoryLayerPolicy on MemoryLayer {
  /// Working records are project-owned; long-term records are user-global.
  MemoryScope get requiredScope => switch (this) {
    MemoryLayer.working => MemoryScope.project,
    MemoryLayer.longTerm => MemoryScope.global,
  };

  bool get isWorking => this == MemoryLayer.working;

  bool get isLongTerm => this == MemoryLayer.longTerm;
}

extension MemoryScopePolicy on MemoryScope {
  bool get isProject => this == MemoryScope.project;

  bool get isGlobal => this == MemoryScope.global;

  bool get requiresProjectId => isProject;
}

extension MemoryKindPolicy on MemoryKind {
  /// Layers in which the kind may appear. Requirements and decisions are
  /// project working state; preferences, procedures, profiles and policies are
  /// user-global; facts may be either.
  Set<MemoryLayer> get allowedLayers => switch (this) {
    MemoryKind.requirement ||
    MemoryKind.decision => const <MemoryLayer>{MemoryLayer.working},
    MemoryKind.fact => const <MemoryLayer>{
      MemoryLayer.working,
      MemoryLayer.longTerm,
    },
    MemoryKind.preference ||
    MemoryKind.procedure ||
    MemoryKind.profile ||
    MemoryKind.policy => const <MemoryLayer>{MemoryLayer.longTerm},
  };

  bool allowsLayer(MemoryLayer layer) => allowedLayers.contains(layer);
}

extension MemoryEntryStatusPolicy on MemoryEntryStatus {
  bool get isActive => this == MemoryEntryStatus.active;

  bool get isForgotten => this == MemoryEntryStatus.forgotten;
}

extension MemoryCandidateStatusPolicy on MemoryCandidateStatus {
  bool get isPending => this == MemoryCandidateStatus.pending;

  bool get isAccepted => this == MemoryCandidateStatus.accepted;

  bool get isRejected => this == MemoryCandidateStatus.rejected;

  bool get isTerminal => !isPending;
}

extension MemoryProposalOperationPolicy on MemoryProposalOperation {
  bool get requiresContent => this != MemoryProposalOperation.noop;

  bool get requiresTargetEntry => this == MemoryProposalOperation.update;

  bool get allowsTargetEntry => this != MemoryProposalOperation.create;
}
