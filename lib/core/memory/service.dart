import 'candidate.dart';
import 'context.dart';
import 'entry.dart';

/// Result of confirming a candidate: the accepted candidate and the active
/// entry revision it produced.
final class MemoryConfirmationResult {
  const MemoryConfirmationResult({
    required this.candidate,
    required this.entry,
  });

  final MemoryCandidate candidate;
  final MemoryEntry entry;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryConfirmationResult &&
          other.candidate == candidate &&
          other.entry == entry;

  @override
  int get hashCode => Object.hash(candidate, entry);
}

/// Deterministic read contract. Planning performs no provider call and never
/// mutates stored memory.
abstract interface class MemoryRetrievalService {
  Future<MemoryReadPlan> planRead(MemoryReadRequest request);
}

/// Write contract for the user-confirmation boundary.
abstract interface class MemoryConfirmationService {
  /// Accepts a pending candidate and publishes a working or long-term entry.
  ///
  /// A noop candidate cannot be confirmed. [editedContent] overrides the
  /// candidate content before it becomes a record.
  Future<MemoryConfirmationResult> confirmCandidate(
    MemoryCandidate candidate, {
    String? editedContent,
    required int nowMicros,
  });

  /// Terminal rejection that keeps the audit record.
  Future<MemoryCandidate> rejectCandidate(
    MemoryCandidate candidate, {
    required int nowMicros,
  });
}
