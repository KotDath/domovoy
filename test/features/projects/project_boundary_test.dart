import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/features/projects/application/project_application_service.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';

void main() {
  test('AgentToolRegistry has no project filesystem tools', () {
    final tools = AgentToolRegistry();
    expect(tools.lookup('read_file'), isNull);
    expect(tools.lookup('write_file'), isNull);
    expect(tools.lookup('list_dir'), isNull);
    expect(tools.lookup('project_fs'), isNull);
  });

  test('active project performs no content file I/O', () async {
    final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
    fs.mount(components: ['home', 'work']);
    fs.bindHandle('h', ['home', 'work']);
    final picker = ScriptedProjectDirectoryPicker()
      ..enqueue(const ProjectPickedDirectory(handleId: 'h', safeLabel: 'work'));
    final grants = InMemoryProjectDirectoryGrantStore();
    final projects = InMemoryProjectRepository();
    final sessions = InMemoryAgentSessionRepository();
    final service = ProjectApplicationService(
      projects: projects,
      projectCatalog: projects,
      sessions: sessions,
      sessionCatalog: sessions,
      provisioner: DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: fs,
        picker: picker,
        grantStore: grants,
      ),
      grants: grants,
    );
    final result = await service.createProject(
      name: 'Alpha',
      desktopMode: ProjectDesktopRootMode.attachExisting,
      cancellation: CancellationSource().token,
    );
    expect(result.isSuccess, isTrue);
    expect(fs.opLog.hasContentIo, isFalse);
    expect(fs.opLog.hasUserFileMutation, isFalse);
    expect(
      fs.opLog.ops.any((op) => op.kind == ProjectFilesystemOpKind.read),
      isFalse,
    );
    expect(
      fs.opLog.ops.any((op) => op.kind == ProjectFilesystemOpKind.write),
      isFalse,
    );
  });

  test('production stack still has empty tool registry', () {
    // Composition is covered by app_composition_test; this guards Project tools.
    final runtime = testRuntime(
      provider: QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: const <List<LlmEvent>>[],
      ),
    );
    expect(runtime.tools.lookup('read_file'), isNull);
  });
}
