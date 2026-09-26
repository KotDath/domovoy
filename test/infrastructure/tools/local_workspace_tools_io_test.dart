import 'dart:io';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/infrastructure/projects/platform_projects.dart';
import 'package:domovoy/infrastructure/tools/local_workspace_tools_io.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  late Directory temporary;
  late Directory workspace;
  late LocalWorkspaceToolExecutor executor;
  final project = ProjectId('local-test');

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('domovoy-tools-');
    workspace = await Directory('${temporary.path}/workspace').create();
    executor = LocalWorkspaceToolExecutor(
      resolveRoot: (_) async => workspace.path,
    );
  });

  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  Future<ToolExecutionResult> invoke(
    String name,
    Map<String, Object?> arguments, {
    ProjectId? projectId,
  }) => executor.execute(
    ToolInvocation(
      callId: 'test-call',
      name: name,
      arguments: arguments,
      projectId: projectId ?? project,
    ),
    cancellation: CancellationSource().token,
    liveness: _NoopLiveness(),
  );

  test('native composition registers every default Pi tool', () {
    final tools = createLocalWorkspaceTools(createPlatformProjectStack());
    expect(tools.enabled.map((id) => id.value), <String>[
      'read',
      'write',
      'edit',
      'bash',
    ]);
    for (final id in tools.enabled) {
      expect(tools.registry.contains(id), isTrue);
    }
  });

  test('write, read, and edit use the selected project workspace', () async {
    final written = await invoke('write', <String, Object?>{
      'path': 'notes/today.txt',
      'content': 'first\nsecond\nthird',
    });
    expect(written.success, isTrue);

    final read = await invoke('read', <String, Object?>{
      'path': 'notes/today.txt',
      'offset': 2,
      'limit': 1,
    });
    expect(read.success, isTrue);
    expect((read.output as Map<String, Object?>)['content'], 'second');

    final edited = await invoke('edit', <String, Object?>{
      'path': 'notes/today.txt',
      'edits': <Map<String, Object?>>[
        <String, Object?>{'oldText': 'first', 'newText': 'FIRST'},
        <String, Object?>{'oldText': 'third', 'newText': 'THIRD'},
      ],
    });
    expect(edited.success, isTrue);
    expect(
      await File('${workspace.path}/notes/today.txt').readAsString(),
      'FIRST\nsecond\nTHIRD',
    );
  });

  test('rejects traversal and symbolic links outside the workspace', () async {
    final outside = File('${temporary.path}/outside.txt');
    await outside.writeAsString('keep');
    final traversal = await invoke('write', <String, Object?>{
      'path': '../outside.txt',
      'content': 'replace',
    });
    expect(traversal.success, isFalse);

    await Link('${workspace.path}/outside.txt').create(outside.path);
    final link = await invoke('write', <String, Object?>{
      'path': 'outside.txt',
      'content': 'replace',
    });
    expect(link.success, isFalse);
    expect(await outside.readAsString(), 'keep');
  });

  test(
    'edit rejects ambiguous replacements without changing the file',
    () async {
      final file = File('${workspace.path}/repeat.txt');
      await file.writeAsString('same same');
      final result = await invoke('edit', <String, Object?>{
        'path': 'repeat.txt',
        'edits': <Map<String, Object?>>[
          <String, Object?>{'oldText': 'same', 'newText': 'other'},
        ],
      });
      expect(result.success, isFalse);
      expect(await file.readAsString(), 'same same');
    },
  );

  test('bash runs with the project as its working directory', () async {
    if (!(Platform.isLinux || Platform.isMacOS)) return;
    final result = await invoke('bash', <String, Object?>{
      'command': 'printf "local-ok"',
    });
    expect(result.success, isTrue);
    final output = result.output as Map<String, Object?>;
    expect(output['exitCode'], 0);
    expect(output['stdout'], 'local-ok');
  });

  test('bash does not inherit the application API key', () async {
    if (!(Platform.isLinux || Platform.isMacOS)) return;
    final result = await invoke('bash', <String, Object?>{
      'command': r'printf "%s" "${DEEPSEEK_API_KEY-unset}"',
    });
    expect(result.success, isTrue);
    expect((result.output as Map<String, Object?>)['stdout'], 'unset');
  });

  test('agent receives the result of a local tool call', () async {
    final registry = AgentToolRegistry()
      ..register(
        AgentTool(
          descriptor: PiDefaultTools.descriptors.firstWhere(
            (descriptor) => descriptor.name == 'write',
          ),
          executor: executor,
        ),
      );
    final provider = QueueScriptedLlmProvider(
      id: BuiltInLlmCatalog.deepSeek,
      wireFamily: LlmWireFamily.openaiChatCompletions,
      turns: <List<LlmEvent>>[
        toolTurn(
          name: 'write',
          callId: 'write-1',
          arguments: jsonObject(<String, Object?>{
            'path': 'result.txt',
            'content': 'saved locally',
          }),
        ),
        textTurn('Saved.'),
      ],
    );
    final runtime = testRuntime(provider: provider, tools: registry);
    final session = await runtime
        .agent(testDefinition(tools: <ToolId>[ToolId('write')]))
        .createSession(projectId: project);
    final events = await session.run('save the result').events.toList();
    expect(events.last, isA<AgentRunCompleted>());
    expect(
      await File('${workspace.path}/result.txt').readAsString(),
      'saved locally',
    );
    final toolResults = provider.requests[1].context.messages
        .expand((message) => message.parts)
        .whereType<LlmToolResultPart>()
        .toList();
    expect(toolResults, hasLength(1));
    expect(toolResults.single.content, contains('bytesWritten'));
    await session.close();
    await runtime.close();
  });
}

final class _NoopLiveness implements ToolExecutionLiveness {
  @override
  void reportProgress({String? detail}) {}
}
