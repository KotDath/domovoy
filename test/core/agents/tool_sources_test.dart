import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/mcp_agent_harness.dart';

void main() {
  group('dynamic agent tool sources', () {
    test('merges atomically, hides collisions and detaches cleanly', () {
      final first = _FakeSource('first', <String, AgentTool>{
        'x': staticAgentTool('x'),
      });
      final second = _FakeSource('second', <String, AgentTool>{
        'x': staticAgentTool('x'),
        'y': staticAgentTool('y'),
        'broken': AgentTool(
          descriptor: LlmToolDescriptor(name: 'broken'),
          unavailableReason: 'schema is not representable',
          executor: _NeverExecutor(),
        ),
      });
      final registry = AgentToolRegistry()
        ..attachSource(first)
        ..attachSource(second);

      expect(registry.lookup('x'), same(first.view.tools['x']));
      expect(registry.lookup('y'), isNotNull);
      expect(
        registry.unavailableReason('x'),
        contains('already owned by "first"'),
      );
      expect(registry.lookup('broken'), isNotNull);

      final view = registry.view(<ToolId>[
        ToolId('x'),
        ToolId('y'),
        ToolId('broken'),
        ToolId('missing'),
      ]);
      expect(view.descriptors.map((descriptor) => descriptor.name), <String>[
        'x',
        'y',
      ]);
      expect(view.unavailable.single.id, ToolId('broken'));
      expect(view.unavailable.single.reason, 'schema is not representable');

      registry.detachSource('second');
      expect(registry.lookup('y'), isNull);
      expect(registry.lookup('x'), same(first.view.tools['x']));

      registry.detachSource('first');
      expect(registry.lookup('x'), isNull);
      expect(registry.view(<ToolId>[ToolId('x')]).descriptors, isEmpty);
    });

    test('registry rebuilds when a source view changes', () {
      final source = _FakeSource('dynamic', <String, AgentTool>{
        'x': staticAgentTool('x'),
      });
      final registry = AgentToolRegistry()..attachSource(source);
      expect(registry.lookup('y'), isNull);

      source.setTools(<String, AgentTool>{'y': staticAgentTool('y')});
      expect(registry.lookup('y'), isNotNull);
      expect(registry.lookup('x'), isNull);
      expect(registry.sourceRevision, greaterThan(1));
    });

    test('built-in names win over a dynamic source', () {
      final registry = AgentToolRegistry()
        ..register(staticAgentTool('read'))
        ..attachSource(
          _FakeSource('mcp', <String, AgentTool>{
            'read': staticAgentTool('read'),
          }),
        );
      expect(registry.unavailableReason('read'), contains('built-in tool'));
      expect(
        registry.view(<ToolId>[ToolId('read')]).descriptors.single.name,
        'read',
      );
    });
  });
}

final class _FakeSource implements AgentToolSource {
  _FakeSource(this.sourceId, Map<String, AgentTool> tools)
    : _view = AgentToolSourceView(tools: tools);

  @override
  final String sourceId;

  final List<void Function()> _listeners = <void Function()>[];
  AgentToolSourceView _view;

  @override
  AgentToolSourceView get view => _view;

  void setTools(Map<String, AgentTool> tools) {
    _view = AgentToolSourceView(tools: tools);
    for (final listener in List<void Function()>.from(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(void Function() listener) => _listeners.add(listener);

  @override
  void removeListener(void Function() listener) => _listeners.remove(listener);

  @override
  void dispose() => _listeners.clear();
}

final class _NeverExecutor implements AgentToolExecutor {
  @override
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  }) {
    throw StateError('unavailable tools must never execute');
  }
}
