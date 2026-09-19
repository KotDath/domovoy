import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  group('session Project membership', () {
    test('v1 and v2 decode as null without rewrite', () {
      const codec = AgentSessionCodec();
      final current = codec.encode(_record(projectId: ProjectId('p1')));
      expect(current['version'], 3);
      expect(current['projectId'], isNotNull);

      final v2 = Map<String, Object?>.from(current)
        ..['version'] = AgentSessionRecord.v2JsonVersion
        ..remove('projectId');
      final decodedV2 = codec.decode(v2);
      expect(decodedV2.projectId, isNull);
      expect(decodedV2.transcript, _record().transcript);

      final v1 = Map<String, Object?>.from(v2)
        ..['version'] = AgentSessionRecord.legacyJsonVersion
        ..remove('selection')
        ..remove('title');
      final decodedV1 = codec.decode(v1);
      expect(decodedV1.projectId, isNull);
    });

    test('membership successor preserves other fields and conflicts', () async {
      final repo = InMemoryAgentSessionRepository();
      final initial = _record(projectId: ProjectId('p1'));
      await repo.save(
        initial,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final cleared = initial.copyWith(
        revision: 1,
        projectId: null,
        updatedAtMicros: 9,
      );
      await repo.save(
        cleared,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      final restored = await repo.load(initial.id);
      expect(restored!.projectId, isNull);
      expect(restored.transcript, initial.transcript);
      expect(restored.title, initial.title);
      expect(restored.selection, initial.selection);
      await expectLater(
        repo.save(
          initial.copyWith(revision: 1, projectId: ProjectId('p2')),
          expectedRevision: 0,
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<AgentException>()),
      );
      expect((await repo.load(initial.id))!.title, initial.title);
      final json = repo.codec.encode(restored).toString();
      expect(json, isNot(contains('bookmark')));
      expect(json, isNot(contains('/tmp')));
    });

    test('createSession can persist projectId in one record', () async {
      final repo = InMemoryAgentSessionRepository();
      final runtime = testRuntime(
        provider: QueueScriptedLlmProvider(
          id: BuiltInLlmCatalog.deepSeek,
          wireFamily: LlmWireFamily.openaiChatCompletions,
          turns: const <List<LlmEvent>>[],
        ),
        repository: repo,
      );
      final session = await runtime
          .agent(testDefinition())
          .createSession(
            persistence: SessionPersistence.repository,
            projectId: ProjectId('fresh'),
          );
      expect(session.snapshot.projectId, ProjectId('fresh'));
      final stored = await repo.load(session.id);
      expect(stored!.projectId, ProjectId('fresh'));
      expect(stored.revision, 0);
      await session.close();
      await runtime.close();
    });
  });
}

AgentSessionRecord _record({ProjectId? projectId}) {
  return AgentSessionRecord(
    id: AgentSessionId('s1'),
    revision: 0,
    definition: testDefinition(),
    transcript: AgentTranscript(
      messages: [
        LlmMessage(role: LlmMessageRole.user, parts: [LlmTextPart('hello')]),
      ],
    ),
    usage: LlmUsage(totalTokens: 1),
    modelTurns: 0,
    toolAttempts: 0,
    createdAtMicros: 1,
    updatedAtMicros: 2,
    title: 'Hello',
    projectId: projectId,
  );
}
