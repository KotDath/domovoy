import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart'
    show JsonlFilesystemStreamStorage;
import 'package:domovoy/infrastructure/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_fixtures.dart';

final class _UnusedExtractor implements MemoryBatchExtractor {
  @override
  Future<List<MemoryCandidateDraft>> extract(
    MemoryExtractionInput input, {
    required CancellationToken cancellation,
  }) async => const <MemoryCandidateDraft>[];
}

JsonlFilesystemStreamStorage _memoryStorage(Directory applicationSupport) {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: () async => applicationSupport,
    namespaceDirectoryName: 'memory-jsonl-v1',
  );
}

void main() {
  final open = CancellationSource().token;

  test(
    'native memory streams round-trip in an independent namespace',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'domovoy-memory-jsonl-',
      );
      addTearDown(() => temporary.delete(recursive: true));

      final first = MemoryJsonlStack(storage: _memoryStorage(temporary));
      final entry = workingEntry(createdAtMicros: 1, updatedAtMicros: 1);
      await first.workingRepository.save(
        entry,
        expectedRevision: 0,
        cancellation: open,
      );

      final restarted = MemoryJsonlStack(storage: _memoryStorage(temporary));
      expect(
        await restarted.workingRepository.load(entry.id, cancellation: open),
        entry,
      );

      final memoryRoot = Directory(
        '${temporary.path}/ru.kotdath.domovoy/memory-jsonl-v1',
      );
      expect(memoryRoot.existsSync(), isTrue);

      final agentStorage = JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => temporary,
      );
      await agentStorage.publish('session-v1_abc', utf8.encode('{}\n'));
      final memoryKeys = await _memoryStorage(temporary).listKeys();
      final agentKeys = await agentStorage.listKeys();
      expect(memoryKeys, isNotEmpty);
      expect(agentKeys, <String>['session-v1_abc']);
      expect(agentKeys.any(memoryKeys.contains), isFalse);
      expect(
        Directory(
          '${temporary.path}/ru.kotdath.domovoy/'
          '${JsonlFilesystemStreamStorage.projectStorageDirectoryName}',
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'memory storage isolates a shared id across namespaces on disk',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'domovoy-memory-namespace-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final stack = MemoryJsonlStack(storage: _memoryStorage(temporary));
      final working = workingEntry(id: 'shared');
      final longTerm = longTermEntry(id: 'shared');
      await stack.workingRepository.save(
        working,
        expectedRevision: 0,
        cancellation: open,
      );
      await stack.longTermRepository.save(
        longTerm,
        expectedRevision: 0,
        cancellation: open,
      );

      final rebuilt = MemoryJsonlStack(storage: _memoryStorage(temporary));
      expect(
        await rebuilt.workingRepository.load(working.id, cancellation: open),
        working,
      );
      expect(
        await rebuilt.longTermRepository.load(longTerm.id, cancellation: open),
        longTerm,
      );
    },
  );

  test('explicit extraction persists production-length runtime ids', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'domovoy-memory-runtime-id-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final storage = _memoryStorage(temporary);
    final stack = MemoryJsonlStack(storage: storage);
    final coordinator = MemoryExtractionCoordinator(
      extractor: _UnusedExtractor(),
      repositories: MemoryRepositories(
        workingRepository: stack.workingRepository,
        longTermRepository: stack.longTermRepository,
        candidateRepository: stack.candidateRepository,
      ),
      checkpoints: stack.extractionCheckpointRepository,
      clock: FakeAgentClock(startMicros: 1000),
      ids: MemoryExtractionIdFactory(namespace: 'extract'),
    );
    addTearDown(coordinator.dispose);
    final sessionId = AgentSessionId(
      'runtime-hmh2876gs5-as2j9s-6ki29g-akesu3-f1o267-session-1',
    );
    final sourceId = MemorySourceId(
      'runtime-hmh2876gs5-as2j9s-6ki29g-akesu3-f1o267-message-3',
    );

    final result = await coordinator.onCompletedTurn(
      sessionId: sessionId,
      projectId: ProjectId('default'),
      completedSources: <MemoryExtractionSource>[
        MemoryExtractionSource(
          id: sourceId,
          role: MemoryTranscriptRole.user,
          text: 'Запомни, что деплоим мы через kubernetes',
        ),
      ],
    );

    expect(result.isExtracted, isTrue);
    final candidates = await stack.candidateRepository.list(cancellation: open);
    expect(candidates, hasLength(1));
    expect(candidates.single.content, 'деплоим мы через kubernetes');
    expect(
      (await storage.listKeys()).every((key) => key.length <= 255),
      isTrue,
    );
  });
}
