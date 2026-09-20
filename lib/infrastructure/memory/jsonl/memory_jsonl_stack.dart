import '../../../core/memory/enums.dart';
import '../../../core/memory/extraction.dart';
import '../../../core/memory/repository.dart';
import '../../agents/jsonl/jsonl_replay.dart';
import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_memory_candidate_repository.dart';
import 'jsonl_memory_entry_repository.dart';
import 'jsonl_memory_extraction_checkpoint_repository.dart';
import 'memory_jsonl_store.dart';

/// Independent working, long-term, candidate, and extraction-state streams
/// sharing one durable storage backend and one serialized append coordinator.
final class MemoryJsonlStack {
  MemoryJsonlStack({required this.storage, JsonlStorageLimits? limits})
    : store = MemoryJsonlStore(storage: storage, limits: limits);

  final JsonlStreamStorage storage;
  final MemoryJsonlStore store;

  late final MemoryEntryRepository workingRepository =
      JsonlMemoryEntryRepository(layer: MemoryLayer.working, store: store);

  late final MemoryEntryRepository longTermRepository =
      JsonlMemoryEntryRepository(layer: MemoryLayer.longTerm, store: store);

  late final MemoryCandidateRepository candidateRepository =
      JsonlMemoryCandidateRepository(store: store);

  late final MemoryExtractionCheckpointRepository
  extractionCheckpointRepository = JsonlMemoryExtractionCheckpointRepository(
    store: store,
  );

  MemoryEntryRepository entryRepository(MemoryLayer layer) => switch (layer) {
    MemoryLayer.working => workingRepository,
    MemoryLayer.longTerm => longTermRepository,
  };
}
