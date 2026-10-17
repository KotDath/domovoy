import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/features/chat/application/chat_run_preparer.dart';
import 'package:domovoy/features/projects/application/project_files_preparer.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_filesystem_storage_io.dart';
import 'package:domovoy/infrastructure/runtime/production_agent_stack.dart';
import 'package:domovoy/infrastructure/tools/local_workspace_executor_io.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/project_files_smoke.dart' as probe;
import '../../support/recording_http_client.dart';

void main() {
  for (final editExisting in [false, true]) {
    test(
      'native ${editExisting ? 'edit' : 'create'} commit is acknowledged before watcher cancellation during cleanup and survives fresh JSONL replay',
      () async {
        final enteredCleanup = Completer<void>();
        final releaseCleanup = Completer<void>();
        final cleaned = Completer<void>();
        final fixture = await _Fixture.create(
          cleanup: (directory) async {
            enteredCleanup.complete();
            await releaseCleanup.future;
            await directory.delete(recursive: true);
            cleaned.complete();
          },
        );
        addTearDown(fixture.close);
        if (editExisting) {
          await File('${fixture.root.path}/note.md').writeAsString('before\n');
        }
        fixture.calls = [
          if (editExisting)
            _call('save', 'edit', {
              'path': 'note.md',
              'edits': [
                {'oldText': 'before', 'newText': 'after'},
              ],
            })
          else
            _call('save', 'write', {'path': 'note.md', 'content': 'after\n'}),
          _call('must-not-run', 'write', {
            'path': 'unrelated.md',
            'content': 'bad',
          }),
        ];
        final observedCommit = Completer<void>();
        AgentRun? run;
        Future<void>? cancelling;
        final watcher = fixture.root.watch().listen((event) {
          final file = File('${fixture.root.path}/note.md');
          if (!observedCommit.isCompleted &&
              event.path.endsWith('/note.md') &&
              file.existsSync() &&
              file.readAsStringSync() == 'after\n') {
            // Actual filesystem observation; no fake save, tool result or rename.
            cancelling = run!.cancel();
            observedCommit.complete();
          }
        });
        addTearDown(watcher.cancel);
        run = await fixture.start();
        final eventsFuture = run.events.toList();
        try {
          await enteredCleanup.future;
          await observedCommit.future;
          // The real rename happened, but executor completion is still blocked.
          expect(
            await File('${fixture.root.path}/note.md').readAsString(),
            'after\n',
          );
          final events = await eventsFuture;
          await cancelling;
          expect(events.last, isA<AgentRunCancelled>());
          final finished = events.whereType<AgentToolFinished>().toList();
          expect(finished, hasLength(1));
          expect(finished.single.success, true);
          expect(events.indexOf(finished.single), lessThan(events.length - 1));
          expect(fixture.client.requests, hasLength(1));
          expect(
            await File('${fixture.root.path}/unrelated.md').exists(),
            false,
          );
          expect(fixture.results.single['change'], {
            'path': 'note.md',
            'kind': editExisting ? 'modified' : 'created',
            'before': editExisting ? 'before\n' : null,
            'after': 'after\n',
          });
          await fixture.verifyFreshReplay(expectedChanges: 1);
        } finally {
          releaseCleanup.complete();
          await cleaned.future;
        }
      },
    );
  }

  test(
    'cancellation before the second commit preserves the first receipt and original bytes, with no later tool or provider work',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.close);
      await File(
        '${fixture.root.path}/protected.md',
      ).writeAsString('original\n');
      fixture.calls = [
        _call('first', 'write', {'path': 'first.md', 'content': 'saved\n'}),
        _call('second', 'edit', {
          'path': 'protected.md',
          'edits': [
            {'oldText': 'original', 'newText': 'bad'},
          ],
        }),
        _call('third', 'write', {'path': 'later.md', 'content': 'bad'}),
      ];
      var validations = 0;
      Future<void>? cancelling;
      fixture.onValidate = () {
        if (++validations == 4) cancelling = fixture.run!.cancel();
      };
      final run = await fixture.start();
      final events = await run.events.toList();
      await cancelling;
      expect(validations, 4);
      expect(events.last, isA<AgentRunCancelled>());
      expect(events.whereType<AgentToolFinished>(), hasLength(1));
      expect(fixture.client.requests, hasLength(1));
      expect(
        await File('${fixture.root.path}/first.md').readAsString(),
        'saved\n',
      );
      expect(
        await File('${fixture.root.path}/protected.md').readAsString(),
        'original\n',
      );
      expect(await File('${fixture.root.path}/later.md').exists(), false);
      expect(fixture.results.single['path'], 'first.md');
      await fixture.verifyFreshReplay(expectedChanges: 1);
    },
  );

  test(
    'cancellation at a later real commit retains all prior partial file outcomes exactly once',
    () async {
      var cleanups = 0;
      final entered = Completer<void>(),
          release = Completer<void>(),
          cleaned = Completer<void>();
      final fixture = await _Fixture.create(
        cleanup: (directory) async {
          if (++cleanups == 2) {
            entered.complete();
            await release.future;
          }
          await directory.delete(recursive: true);
          if (cleanups == 2) cleaned.complete();
        },
      );
      addTearDown(fixture.close);
      fixture.calls = [
        for (var i = 1; i <= 3; i++)
          _call('$i', 'write', {'path': '$i.md', 'content': 'saved $i'}),
      ];
      final run = await fixture.start();
      final eventsFuture = run.events.toList();
      try {
        await entered.future;
        // Pause is after the genuine second rename and its synchronous receipt.
        expect(
          await File('${fixture.root.path}/2.md').readAsString(),
          'saved 2',
        );
        await run.cancel();
        final events = await eventsFuture;
        expect(events.last, isA<AgentRunCancelled>());
        expect(events.whereType<AgentToolFinished>(), hasLength(2));
        expect(fixture.results.map((r) => r['path']), ['1.md', '2.md']);
        expect(await File('${fixture.root.path}/3.md').exists(), false);
        expect(fixture.client.requests, hasLength(1));
        await fixture.verifyFreshReplay(expectedChanges: 2);
      } finally {
        release.complete();
        await cleaned.future;
      }
    },
  );

  test(
    'post-commit cleanup failure cannot replace saved success or duplicate its result; future probe composition is durable',
    () async {
      var cleanupAttempted = false;
      final fixture = await _Fixture.create(
        cleanup: (_) async {
          cleanupAttempted = true;
          throw const FileSystemException(
            'controlled temporary cleanup failure',
          );
        },
      );
      addTearDown(fixture.close);
      fixture.calls = [
        _call('save', 'write', {'path': 'note.md', 'content': 'actual bytes'}),
      ];
      final run = await fixture.start();
      final events = await run.events.toList();
      expect(cleanupAttempted, true);
      expect(events.last, isA<AgentRunCompleted>());
      expect(events.whereType<AgentToolFinished>().single.success, true);
      expect(fixture.results, hasLength(1));
      expect(fixture.results.single['change'], {
        'path': 'note.md',
        'kind': 'created',
        'before': null,
        'after': 'actual bytes',
      });
      expect(
        await File('${fixture.root.path}/note.md').readAsString(),
        'actual bytes',
      );
      expect(fixture.client.requests, hasLength(2));
      await fixture.verifyFreshReplay(expectedChanges: 1);
    },
  );
}

Map<String, Object?> _call(String id, String name, Map<String, Object?> args) =>
    {
      'index': 0,
      'id': id,
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
    };

final class _Fixture {
  _Fixture(this.temp, this.root);
  final Directory temp, root;
  late final RecordingClient client;
  late final ProductionAgentStack stack;
  late final AgentSession session;
  AgentRun? run;
  void Function()? onValidate;
  List<Map<String, Object?>> calls = [];

  JsonlFilesystemStreamStorage get freshStorage => JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: () async =>
        Directory('${temp.path}/state'),
  );

  static Future<_Fixture> create({
    Future<void> Function(Directory)? cleanup,
  }) async {
    final temp = await Directory.systemTemp.createTemp('workspace-commit-ack-');
    final fixture = _Fixture(
      temp,
      await Directory('${temp.path}/root').create(),
    );
    final executor = LocalWorkspaceToolExecutor(
      resolveRoot: (_) async => fixture.root.path,
      resolveWritableRoot: (_) async {
        fixture.onValidate?.call();
        return fixture.root.path;
      },
      cleanupTemporary:
          cleanup ??
          (directory) async {
            if (await directory.exists()) {
              await directory.delete(recursive: true);
            }
          },
    );
    final tools = AgentToolRegistry();
    for (final d in WorkspaceFileTools.descriptors) {
      tools.register(AgentTool(descriptor: d, executor: executor));
    }
    fixture.client = RecordingClient((_) {
      final first = fixture.client.requests.length == 1;
      final delta = first
          ? {
              'tool_calls': [
                for (final (index, call) in fixture.calls.indexed)
                  {...call, 'index': index},
              ],
            }
          : {'content': 'Saved.'};
      final body =
          'data: ${jsonEncode({
            'id': 'offline',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': null},
            ],
          })}\n\n'
          'data: ${jsonEncode({
            'id': 'offline',
            'choices': [
              {'index': 0, 'delta': {}, 'finish_reason': first ? 'tool_calls' : 'stop'},
            ],
          })}\n\n'
          'data: [DONE]\n\n';
      return sseResponse(body);
    });
    fixture.stack = buildProductionAgentStack(
      httpClient: fixture.client,
      credentials: DefaultProviderCredentialResolver(
        store: MemoryProviderCredentialStore(),
        readEnvironment: (_) => 'offline-test-only',
      ),
      tools: tools,
      enabledTools: WorkspaceFileTools.ids,
      storage: fixture.freshStorage,
    );
    fixture.session = await probe.createProjectFileProbeSession(
      fixture.stack,
      ProjectId('authorized'),
    );
    return fixture;
  }

  Future<AgentRun> start() async {
    final prepared = await ProjectFilesPreparer(fallback: _Fallback()).prepare(
      session.snapshot,
      '/files Save the requested local notes.',
      CancellationSource().token,
    );
    return run = session.run(
      '/files Save the requested local notes.',
      options: prepared!.options,
    );
  }

  List<Map<String, dynamic>> get results => session.snapshot.transcript.messages
      .expand((m) => m.parts)
      .whereType<LlmToolResultPart>()
      .map((r) => jsonDecode(r.content) as Map<String, dynamic>)
      .toList();

  Future<void> verifyFreshReplay({required int expectedChanges}) async {
    final replay = await probe.verifyProjectFileProbeReplay(
      freshStorage,
      session,
    );
    expect(replay['fresh_store_transcript_matches'], true);
    expect(replay['change_result_count'], expectedChanges);
    final fresh = await JsonlAgentSessionStore(
      storage: freshStorage,
    ).load(session.id);
    expect(fresh, isNotNull);
    expect(fresh!.transcript.toJson(), session.snapshot.transcript.toJson());
    // Close the original runtime and replay again from a new repository/storage,
    // rather than checking an in-memory record returned by the original store.
    await session.close();
    await stack.runtime.close();
    final afterRestart = await JsonlAgentSessionStore(
      storage: freshStorage,
    ).load(session.id);
    expect(afterRestart!.transcript.toJson(), fresh.transcript.toJson());
  }

  Future<void> close() async {
    await session.close();
    await stack.runtime.close();
    client.close();
    await temp.delete(recursive: true);
  }
}

final class _Fallback implements ChatRunPreparer {
  @override
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  ) async => null;
}
