import 'dart:async';
import 'dart:io';

import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart';
import 'package:domovoy/infrastructure/rag/jsonl_task_state_repository.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/rag_task_state_fixture.dart';

void main() {
  test(
    'cancel after preparing bytes, before atomic pointer publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'domovoy-state-cancel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final entered = Completer<void>(), release = Completer<void>();
      var gate = false;
      final storage = JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => directory,
        namespaceDirectoryName: 'task-state-test-v1',
        stageHook: (stage, _) async {
          if (gate && stage == JsonlFilesystemStage.beforePointerPublication) {
            entered.complete();
            await release.future;
          }
        },
      );
      final repo = JsonlRagTaskStateRepository(storage);
      final first = changedTaskState(
        RagTaskState(project: 'p', session: 's'),
        '09:00',
      );
      await repo.save(
        first,
        expectedRevision: 0,
        cancellation: CancellationSource().token,
      );
      gate = true;
      final cancellation = CancellationSource();
      final writing = repo.save(
        changedTaskState(first, '08:30'),
        expectedRevision: 1,
        cancellation: cancellation.token,
      );
      final failure = expectLater(writing, throwsA(anything));
      await entered.future;
      cancellation.cancel();
      release.complete();
      await failure;
      expect((await repo.load('p', 's')).toJson(), first.toJson());
      expect(
        (await JsonlRagTaskStateRepository(
          storage,
        ).load('p', 's')).facts.single.quote,
        '09:00',
      );
    },
  );
}
