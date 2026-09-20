import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('memory enum codecs', () {
    test('parse every value by name', () {
      for (final value in MemoryLayer.values) {
        expect(MemoryLayerCodec.parse(value.name), value);
      }
      for (final value in MemoryScope.values) {
        expect(MemoryScopeCodec.parse(value.name), value);
      }
      for (final value in MemoryKind.values) {
        expect(MemoryKindCodec.parse(value.name), value);
      }
      for (final value in MemoryEntryStatus.values) {
        expect(MemoryEntryStatusCodec.parse(value.name), value);
      }
      for (final value in MemoryCandidateStatus.values) {
        expect(MemoryCandidateStatusCodec.parse(value.name), value);
      }
      for (final value in MemoryProposalOperation.values) {
        expect(MemoryProposalOperationCodec.parse(value.name), value);
      }
      for (final value in MemoryReadReason.values) {
        expect(MemoryReadReasonCodec.parse(value.name), value);
      }
    });

    test('unknown names are protocol errors', () {
      expect(
        () => MemoryLayerCodec.parse('episodic'),
        throwsA(
          isA<MemoryException>().having(
            (error) => error.error.kind,
            'kind',
            MemoryErrorKind.protocol,
          ),
        ),
      );
      expect(
        () => MemoryKindCodec.parse('rumour'),
        throwsA(isA<MemoryException>()),
      );
    });
  });

  group('memory layer policy', () {
    test('working is project-scoped and long-term is global', () {
      expect(MemoryLayer.working.requiredScope, MemoryScope.project);
      expect(MemoryLayer.longTerm.requiredScope, MemoryScope.global);
      expect(MemoryLayer.working.isWorking, isTrue);
      expect(MemoryLayer.longTerm.isLongTerm, isTrue);
      expect(MemoryScope.project.requiresProjectId, isTrue);
      expect(MemoryScope.global.requiresProjectId, isFalse);
    });

    test('kinds restrict their allowed layers', () {
      expect(MemoryKind.requirement.allowedLayers, {MemoryLayer.working});
      expect(MemoryKind.decision.allowedLayers, {MemoryLayer.working});
      expect(MemoryKind.fact.allowedLayers, {
        MemoryLayer.working,
        MemoryLayer.longTerm,
      });
      for (final kind in <MemoryKind>[
        MemoryKind.preference,
        MemoryKind.procedure,
        MemoryKind.profile,
        MemoryKind.policy,
      ]) {
        expect(kind.allowedLayers, {MemoryLayer.longTerm});
      }
      expect(MemoryKind.requirement.allowsLayer(MemoryLayer.working), isTrue);
      expect(MemoryKind.requirement.allowsLayer(MemoryLayer.longTerm), isFalse);
    });

    test('status and operation policies', () {
      expect(MemoryEntryStatus.active.isActive, isTrue);
      expect(MemoryEntryStatus.active.isForgotten, isFalse);
      expect(MemoryEntryStatus.forgotten.isForgotten, isTrue);
      expect(MemoryCandidateStatus.pending.isPending, isTrue);
      expect(MemoryCandidateStatus.pending.isTerminal, isFalse);
      expect(MemoryCandidateStatus.accepted.isTerminal, isTrue);
      expect(MemoryCandidateStatus.rejected.isTerminal, isTrue);
      expect(MemoryProposalOperation.create.requiresContent, isTrue);
      expect(MemoryProposalOperation.create.requiresTargetEntry, isFalse);
      expect(MemoryProposalOperation.update.requiresTargetEntry, isTrue);
      expect(MemoryProposalOperation.noop.requiresContent, isFalse);
      expect(MemoryProposalOperation.noop.allowsTargetEntry, isTrue);
      expect(MemoryProposalOperation.create.allowsTargetEntry, isFalse);
    });
  });
}
