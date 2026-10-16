import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/index_builder.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_agent_session_store.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_filesystem_storage_io.dart';
import 'package:domovoy/infrastructure/headless/cli_options.dart';
import 'package:domovoy/infrastructure/headless/headless_cli_io.dart';
import 'package:domovoy/infrastructure/headless/project_sources_io.dart';
import 'package:domovoy/infrastructure/headless/read_only_tools_io.dart';
import 'package:domovoy/infrastructure/headless/review_context.dart';
import 'package:domovoy/infrastructure/llm/discovery/provider_model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../../support/rag_fakes.dart';
import '../../support/recording_http_client.dart';

void main() {
  late Directory sandbox;
  late Directory project;
  late Directory state;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('headless-test-');
    project = await Directory('${sandbox.path}/project').create();
    state = Directory('${sandbox.path}/state');
    await File(
      '${project.path}/README.md',
    ).writeAsString('Project design and usage.');
    await File(
      '${project.path}/value.py',
    ).writeAsString('def value(): return 1\n');
  });
  tearDown(() => sandbox.delete(recursive: true));

  final credentials = DefaultProviderCredentialResolver(
    store: MemoryProviderCredentialStore(),
    readEnvironment: (_) => 'test-only',
  );

  HeadlessOptions options([List<String> extra = const []]) =>
      HeadlessOptions.parse([
        'exec',
        '--project',
        project.path,
        '--prompt',
        'Inspect the project',
        '--state-dir',
        state.path,
        ...extra,
      ]);

  test('parsing enforces review admission and prompt/output contracts', () {
    expect(HeadlessOptions.parse(['--help']).help, isTrue);
    expect(
      () => HeadlessOptions.parse([
        'exec',
        '--project',
        '.',
        '--prompt',
        'x',
        '--prompt-file',
        'x',
      ]),
      throwsFormatException,
    );
    expect(
      () => HeadlessOptions.parse(['review', '--project', '.']),
      throwsFormatException,
    );
    expect(() => options(['--max-tool-calls', '0']), throwsFormatException);
    expect(() => options(['--output-format', 'yaml']), throwsFormatException);
    expect(options().model, 'deepseek-flash');
  });

  test(
    'production tool loop reads actual file then persists final JSONL',
    () async {
      final events = <Map<String, Object?>>[];
      final outputs = <String>[];
      final resultFile = '${sandbox.path}/answer.md';
      var calls = 0;
      final client = RecordingClient((request) {
        expect(request.header('authorization'), 'Bearer test-only');
        expect(request.jsonBody['thinking'], {'type': 'disabled'});
        if (calls++ == 0) {
          return sseResponse(
            _sse({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'read-1',
                  'type': 'function',
                  'function': {
                    'name': 'read',
                    'arguments': '{"path":"value.py"}',
                  },
                },
              ],
            }, 'tool_calls'),
          );
        }
        expect(request.body, contains('def value(): return 1'));
        return sseResponse(_sse({'content': 'Observed actual file.'}, 'stop'));
      });
      addTearDown(client.close);
      final code = await executeHeadless(
        options([
          '--output-last-message',
          resultFile,
          '--reasoning',
          'disabled',
        ]),
        cancellation: CancellationSource(),
        emit: events.add,
        emitText: outputs.add,
        httpClient: client,
        credentialResolver: credentials,
      );
      expect(code, 0);
      expect(calls, 2);
      expect(await File(resultFile).readAsString(), 'Observed actual file.\n');
      expect(outputs, ['Observed actual file.']);
      expect(
        events.where((e) => e['type'] == 'tool_completed').single['success'],
        true,
      );
      final store = JsonlAgentSessionStore(
        storage: JsonlFilesystemStreamStorage(
          applicationSupportDirectoryResolver: () async => state,
        ),
      );
      final record = await store.load(
        AgentSessionId(events.last['session_id'] as String),
      );
      expect(record, isNotNull);
      expect(events.last['success'], true);
    },
  );

  test(
    'provider failure and cancellation produce no success file or result',
    () async {
      for (final cancel in [false, true]) {
        final cancellation = CancellationSource();
        final events = <Map<String, Object?>>[];
        final client = RecordingClient((_) {
          if (cancel) cancellation.cancel();
          return cancel
              ? sseResponse(_sse({'content': 'draft'}, 'stop'))
              : sseResponse('provider error', status: 503);
        });
        final path = '${sandbox.path}/failure-$cancel.md';
        final code = await executeHeadless(
          options(['--output-last-message', path]),
          cancellation: cancellation,
          emit: events.add,
          emitText: (_) {},
          httpClient: client,
          credentialResolver: credentials,
        );
        client.close();
        expect(code, cancel ? 130 : 1);
        expect(events.any((e) => e['type'] == 'result'), false);
        expect(await File(path).exists(), false);
        expect(cancellation.registrationCount, 0);
      }
    },
  );

  test(
    'review executor independently denies mutation, shell, secret, traversal and symlink',
    () async {
      await File(
        '${project.path}/credentials.json',
      ).writeAsString('test credential fixture');
      await File('${sandbox.path}/outside.py').writeAsString('outside');
      await Link(
        '${project.path}/link.py',
      ).create('${sandbox.path}/outside.py');
      final executor = ReadOnlyWorkspaceExecutor(
        root: project.path,
        allowedPaths: {'value.py', 'credentials.json', 'link.py'},
      );
      for (final (name, path) in [
        ('bash', 'value.py'),
        ('write', 'value.py'),
        ('edit', 'value.py'),
        ('read', '../outside.py'),
        ('read', 'credentials.json'),
        ('read', 'link.py'),
      ]) {
        final result = await executor.execute(
          ToolInvocation(
            callId: 'x',
            name: name,
            arguments: {'path': path, 'command': 'touch mutated'},
          ),
          cancellation: CancellationSource().token,
          liveness: _Liveness(),
        );
        expect(result.success, false, reason: '$name $path');
      }
      expect(
        await File('${project.path}/value.py').readAsString(),
        'def value(): return 1\n',
      );
      expect(await File('${project.path}/mutated').exists(), false);
    },
  );

  test(
    'scanner includes code/docs/credential implementation/dot configs; excludes exact stores and caches',
    () async {
      for (final path in [
        'lib/credentials/credential_resolver.dart',
        'lib/secret_service.dart',
        'docs/credentials.md',
        '.github/workflows/review.yml',
        '.config/lint.json',
        '.editorconfig',
        '.env',
        '.aws/config',
        '.config/gh/hosts.yml',
        'credentials.json',
        'build/generated.dart',
      ]) {
        final file = File('${project.path}/$path');
        await file.parent.create(recursive: true);
        await file.writeAsString('source fixture');
      }
      final snapshot = await scanProjectSources(
        project.path,
        CancellationSource().token,
      );
      final paths = snapshot.documents.map((d) => d.source).toList();
      expect(
        paths,
        containsAll([
          'lib/credentials/credential_resolver.dart',
          'lib/secret_service.dart',
          'docs/credentials.md',
          '.github/workflows/review.yml',
          '.config/lint.json',
          '.editorconfig',
        ]),
      );
      for (final path in [
        '.env',
        '.aws/config',
        '.config/gh/hosts.yml',
        'credentials.json',
        'build/generated.dart',
      ]) {
        expect(paths, isNot(contains(path)));
      }
    },
  );

  test(
    'real shared index builder retains docs/code and invalidates content/model/revision/config',
    () async {
      final docs = (await scanProjectSources(
        project.path,
        CancellationSource().token,
      )).documents;
      final model = const RagModelInfo('fake-v1', 2, 'TEST');
      final index = await buildRagIndex(
        models: FakeRagModels(),
        model: model,
        documents: docs,
        strategy: ChunkStrategy.structure,
        cancellation: CancellationSource().token,
        revisionScope: 'repo:base:head',
      );
      expect(index.chunks.map((c) => c.source).toSet(), {
        'README.md',
        'value.py',
      });
      expect(
        index.generation,
        ragIndexIdentity(
          docs,
          model,
          ChunkStrategy.structure,
          'repo:base:head',
        ),
      );
      expect(
        index.generation,
        isNot(
          ragIndexIdentity(
            docs,
            model,
            ChunkStrategy.structure,
            'other:base:head',
          ),
        ),
      );
      expect(
        index.generation,
        isNot(
          ragIndexIdentity(
            docs,
            const RagModelInfo('new-model', 2, 'TEST'),
            ChunkStrategy.structure,
            'repo:base:head',
          ),
        ),
      );
      expect(
        index.generation,
        isNot(
          ragIndexIdentity(docs, model, ChunkStrategy.fixed, 'repo:base:head'),
        ),
      );
      await File(
        '${project.path}/value.py',
      ).writeAsString('def value(): return 2');
      final changed = (await scanProjectSources(
        project.path,
        CancellationSource().token,
      )).documents;
      expect(
        index.generation,
        isNot(
          ragIndexIdentity(
            changed,
            model,
            ChunkStrategy.structure,
            'repo:base:head',
          ),
        ),
      );
    },
  );

  test(
    'review context fails malformed/oversize/changed snapshot coverage',
    () async {
      final snapshot = await scanProjectSources(
        project.path,
        CancellationSource().token,
      );
      final data = _context(snapshot);
      final context = ReviewContext.parse(jsonEncode(data));
      context.verifySources(snapshot);
      expect(() => ReviewContext.parse('{}'), throwsFormatException);
      expect(
        () => ReviewContext.parse(jsonEncode(data), maxBytes: 2),
        throwsFormatException,
      );
      expect(
        () => ReviewContext.parse(jsonEncode({...data, 'head_sha': 'wrong'})),
        throwsFormatException,
      );
      expect(
        () => ReviewContext.parse(
          jsonEncode({
            ...data,
            'changed_files': ['.env'],
          }),
        ),
        throwsFormatException,
      );
      await File('${project.path}/value.py').writeAsString('changed');
      final changed = await scanProjectSources(
        project.path,
        CancellationSource().token,
      );
      expect(() => context.verifySources(changed), throwsStateError);
    },
  );

  test(
    'review uses vector docs/code, readonly registry, trusted template and cache; RAG failure blocks model',
    () async {
      await File('${project.path}/empty.py').writeAsString('');
      final snapshot = await scanProjectSources(
        project.path,
        CancellationSource().token,
      );
      final contextFile = File('${sandbox.path}/review.json');
      await contextFile.writeAsString(jsonEncode(_context(snapshot)));
      final template = File('${sandbox.path}/prompt.md');
      await template.writeAsString('Generic trusted review instructions');
      var llmCalls = 0;
      var embeddingCalls = 0;
      var ragFailure = false;
      final client = RecordingClient((request) {
        if (request.url.host == 'api.deepseek.com') {
          llmCalls++;
          final body = request.jsonBody;
          expect((body['tools'] as List).map((t) => t['function']['name']), [
            'read',
          ]);
          expect(request.body, contains('Generic trusted review instructions'));
          expect(request.body, contains('trusted base rule'));
          expect(request.body, contains('def value(): return 1'));
          expect(request.body, contains('Project design and usage.'));
          return sseResponse(_sse({'content': 'No verified defects.'}, 'stop'));
        }
        if (ragFailure) return sseResponse('error', status: 503);
        Object response;
        if (request.url.path == '/health') {
          response = {
            'ready': true,
            'offset_unit': 'codepoint',
            'dimension': 2,
            'fingerprint': 'test-vector-model',
            'embedding': {'model': 'TEST'},
          };
        } else if (request.url.path == '/v1/tokenize') {
          final text = request.jsonBody['text'] as String;
          response = {
            'offset_unit': 'codepoint',
            'offsets': [
              [0, text.length],
            ],
          };
        } else {
          embeddingCalls++;
          response = {
            'fingerprint': 'test-vector-model',
            'dimension': 2,
            'normalized': true,
            'truncated': false,
            'outputs': [
              for (final input in request.jsonBody['inputs'] as List)
                {
                  'id': input['id'],
                  'vector': [1, 0],
                },
            ],
          };
        }
        return http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode(response))),
          200,
        );
      });
      final opts = HeadlessOptions.parse([
        'review',
        '--project',
        project.path,
        '--review-context',
        contextFile.path,
        '--system-prompt-file',
        template.path,
        '--state-dir',
        state.path,
        '--rag-url',
        'http://127.0.0.1:8765',
        '--output-format',
        'jsonl',
      ]);
      for (final cached in [false, true]) {
        final events = <Map<String, Object?>>[];
        final code = await executeHeadless(
          opts,
          cancellation: CancellationSource(),
          emit: events.add,
          emitText: (_) => fail('JSONL emitted text'),
          httpClient: client,
          credentialResolver: credentials,
        );
        expect(code, 0);
        expect(events.singleWhere((e) => e['type'] == 'rag')['cached'], cached);
        expect(events.last['head_sha'], 'b' * 40);
      }
      expect(embeddingCalls, 3); // One passage batch, query for each run.
      ragFailure = true;
      await expectLater(
        executeHeadless(
          opts,
          cancellation: CancellationSource(),
          emit: (_) {},
          emitText: (_) {},
          httpClient: client,
          credentialResolver: credentials,
        ),
        throwsStateError,
      );
      expect(llmCalls, 2);
      client.close();
    },
  );

  for (final deadline in [false, true]) {
    test(
      'dynamic catalog ${deadline ? 'deadline' : 'cancellation'} aborts HTTP and dispatches no later requests',
      () async {
        final client = _HeldCatalogClient();
        final cancellation = CancellationSource();
        final events = <Map<String, Object?>>[];
        final output = '${sandbox.path}/cancelled-catalog.md';
        final pending = executeHeadless(
          options([
            '--provider',
            'anthropic',
            '--model',
            'claude-sonnet-4-5',
            '--catalog-file',
            File('assets/models_fallback.json').absolute.path,
            '--output-last-message',
            output,
          ]),
          cancellation: cancellation,
          emit: events.add,
          emitText: (_) {},
          httpClient: client,
          credentialResolver: DefaultProviderCredentialResolver(
            store: MemoryProviderCredentialStore(),
            readEnvironment: (_) => null,
          ),
        );
        final outcome = expectLater(pending, throwsA(isA<CatalogCancelled>()));
        await client.started.future.timeout(const Duration(seconds: 2));
        final clock = Stopwatch()..start();
        Timer? timer;
        if (deadline) {
          timer = Timer(const Duration(milliseconds: 20), cancellation.cancel);
        } else {
          cancellation.cancel();
        }
        await outcome.timeout(const Duration(seconds: 1));
        timer?.cancel();
        expect(clock.elapsed, lessThan(const Duration(seconds: 1)));
        await client.aborted.future.timeout(const Duration(seconds: 1));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.urls, [Uri.parse('https://models.dev/api.json')]);
        expect(
          events.any(
            (e) => e['type'] == 'model_selected' || e['type'] == 'result',
          ),
          false,
        );
        expect(await File(output).exists(), false);
        expect(cancellation.registrationCount, 0);
        expect(client.closed, false); // Injected clients remain caller-owned.
        client.close();
      },
    );
  }

  test(
    'catalog cancellation during bundled loading cannot fall back or dispatch HTTP',
    () async {
      final cancellation = CancellationSource();
      final loading = Completer<String>();
      final started = Completer<void>();
      final client = _HeldCatalogClient();
      final catalog = ProviderModelCatalog(
        client: client,
        credentials: credentials,
        publishModels: (_) {},
        loadBundled: () {
          started.complete();
          return loading.future;
        },
      );
      final pending = catalog.refresh(cancellation: cancellation.token);
      final outcome = expectLater(pending, throwsA(isA<CatalogCancelled>()));
      await started.future;
      cancellation.cancel();
      await outcome.timeout(const Duration(seconds: 1));
      loading.complete('{}');
      await Future<void>.delayed(Duration.zero);
      expect(client.urls, isEmpty);
      expect(cancellation.registrationCount, 0);
      await catalog.close();
      client.close();
    },
  );

  test(
    'empty and whitespace text remain hashable/readable sources without empty vector passages',
    () async {
      final contents = {
        'pkg/__init__.py': '',
        'cleared.py': '',
        'whitespace.txt': '  \t\n',
      };
      for (final entry in contents.entries) {
        final file = File('${project.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
      }
      final snapshot = await scanProjectSources(
        project.path,
        CancellationSource().token,
      );
      final data = _context(snapshot)
        ..['changed_files'] = contents.keys.toList();
      ReviewContext.parse(jsonEncode(data)).verifySources(snapshot);
      final executor = ReadOnlyWorkspaceExecutor(
        root: project.path,
        allowedPaths: snapshot.documents.map((d) => d.source).toSet(),
      );
      for (final entry in contents.entries) {
        final doc = snapshot.documents.singleWhere(
          (d) => d.source == entry.key,
        );
        expect(doc.text, entry.value);
        expect((data['source_hashes'] as Map)[entry.key], ragHash(entry.value));
        final read = await executor.execute(
          ToolInvocation(
            callId: 'empty',
            name: 'read',
            arguments: {'path': entry.key},
          ),
          cancellation: CancellationSource().token,
          liveness: _Liveness(),
        );
        expect(read.success, true);
        if (entry.value.isEmpty) {
          expect((read.output as Map)['content'], '');
        }
      }
      final index = await buildRagIndex(
        models: FakeRagModels(),
        model: const RagModelInfo('fake-v1', 2, 'TEST'),
        documents: snapshot.documents,
        strategy: ChunkStrategy.structure,
        cancellation: CancellationSource().token,
      );
      expect(index.documents.map((d) => d.source), containsAll(contents.keys));
      expect(index.chunks.any((c) => contents.containsKey(c.source)), false);
    },
  );

  test(
    'entrypoint transitive local imports do not reach Flutter/platform plugins',
    () async {
      final seen = <String>{};
      Future<void> visit(String path) async {
        path = File(path).absolute.uri.normalizePath().toFilePath();
        if (!seen.add(path)) return;
        final source = await File(path).readAsString();
        for (final match in RegExp(
          r'''(?:import|export)\s+['"]([^'"]+)['"]''',
        ).allMatches(source)) {
          final uri = match[1]!;
          expect(uri, isNot(startsWith('package:flutter')), reason: path);
          expect(uri, isNot(startsWith('package:path_provider')), reason: path);
          if (uri.startsWith('package:domovoy/')) {
            await visit('lib/${uri.substring(16)}');
          } else if (!uri.contains(':')) {
            await visit(File(path).parent.uri.resolve(uri).toFilePath());
          }
        }
      }

      await visit('bin/domovoy.dart');
      expect(seen.length, greaterThan(50));
    },
  );
}

String _sse(Map<String, Object?> delta, String finish) =>
    'data: ${jsonEncode({
      'id': 'test',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': null},
      ],
    })}\n\n'
    'data: ${jsonEncode({
      'id': 'test',
      'choices': [
        {'index': 0, 'delta': {}, 'finish_reason': finish},
      ],
    })}\n\n'
    'data: [DONE]\n\n';

Map<String, Object?> _context(ProjectSourceSnapshot snapshot) => {
  'version': 1,
  'repository': 'owner/repo',
  'base_sha': 'a' * 40,
  'head_sha': 'b' * 40,
  'changed_files': ['value.py'],
  'diff': 'diff --git a/value.py b/value.py\n+def value(): return 1',
  'trusted_rules': {'AGENTS.md': 'trusted base rule'},
  'rag_paths': snapshot.documents.map((d) => d.source).toList(),
  'source_hashes': {
    for (final d in snapshot.documents) d.source: ragHash(d.text),
  },
};

final class _Liveness implements ToolExecutionLiveness {
  @override
  void reportProgress({String? detail}) {}
}

/// Benign stalled HTTP boundary: no sockets, network or credentials.
final class _HeldCatalogClient extends http.BaseClient {
  final urls = <Uri>[];
  final started = Completer<void>();
  final aborted = Completer<void>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    urls.add(request.url);
    final pending = Completer<http.StreamedResponse>();
    if (!started.isCompleted) started.complete();
    if (request is! http.AbortableRequest) {
      throw StateError('Expected abortable catalog request');
    }
    request.abortTrigger!.then((_) {
      if (!aborted.isCompleted) aborted.complete();
      if (!pending.isCompleted) {
        pending.completeError(http.RequestAbortedException(request.url));
      }
    });
    return pending.future;
  }

  @override
  void close() {
    closed = true;
  }
}
