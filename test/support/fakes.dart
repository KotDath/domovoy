import 'dart:async';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/settings/domain/api_key_credentials.dart';

final class MemoryApiKeyOverrideStore implements ApiKeyOverrideStore {
  MemoryApiKeyOverrideStore([this.value]);

  String? value;
  int readCount = 0;
  int writeCount = 0;
  int deleteCount = 0;

  @override
  Future<String?> read() async {
    readCount++;
    return value;
  }

  @override
  Future<void> write(String value) async {
    writeCount++;
    this.value = value;
  }

  @override
  Future<void> delete() async {
    deleteCount++;
    value = null;
  }
}

final class ControlledAgentRuntime implements AgentRuntime {
  final List<AgentDefinition> definitions = <AgentDefinition>[];
  final List<String> inputs = <String>[];
  final List<ControlledAgentRun> runs = <ControlledAgentRun>[];
  final List<AgentRunOptions?> options = <AgentRunOptions?>[];

  ControlledAgentRun get latest => runs.last;

  List<StreamController<AgentRunEvent>> get controllers =>
      runs.map((run) => run.controller).toList();

  @override
  Agent agent(AgentDefinition definition) {
    definitions.add(definition);
    return _FakeBoundAgent(this, definition);
  }

  @override
  Future<void> close() async {}
}

final class ControlledAgentRun implements AgentRun {
  ControlledAgentRun() : id = RunId('controlled-${_nextId++}');

  static var _nextId = 1;

  @override
  final RunId id;

  final StreamController<AgentRunEvent> controller =
      StreamController<AgentRunEvent>();

  var cancelled = false;

  void add(AgentRunEvent event) => controller.add(event);

  Future<void> close() async {
    if (!controller.isClosed) {
      await controller.close();
    }
  }

  @override
  Stream<AgentRunEvent> get events => controller.stream;

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

final class ScriptedAgentRuntime implements AgentRuntime {
  ScriptedAgentRuntime(this.script);

  final List<AgentRunEvent> script;
  final List<String> inputs = <String>[];
  final List<AgentDefinition> definitions = <AgentDefinition>[];

  @override
  Agent agent(AgentDefinition definition) {
    definitions.add(definition);
    return _ScriptedBoundAgent(definition, script, inputs);
  }

  @override
  Future<void> close() async {}
}

final class QueueScriptedAgentRuntime implements AgentRuntime {
  QueueScriptedAgentRuntime(this.scripts);

  final List<List<AgentRunEvent>> scripts;
  final List<String> inputs = <String>[];
  final List<AgentDefinition> definitions = <AgentDefinition>[];
  var _index = 0;

  @override
  Agent agent(AgentDefinition definition) {
    definitions.add(definition);
    final events = _index < scripts.length
        ? scripts[_index++]
        : const <AgentRunEvent>[AgentRunCompleted()];
    return _ScriptedBoundAgent(definition, events, inputs);
  }

  @override
  Future<void> close() async {}
}

final class _FakeBoundAgent implements Agent {
  _FakeBoundAgent(this._runtime, this.definition);

  final ControlledAgentRuntime _runtime;

  @override
  final AgentDefinition definition;

  @override
  AgentRun run(String input, {AgentRunOptions? options}) {
    _runtime.inputs.add(input);
    _runtime.options.add(options);
    final run = ControlledAgentRun();
    _runtime.runs.add(run);
    return run;
  }

  @override
  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options}) {
    throw UnimplementedError();
  }

  @override
  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AgentSession> restoreSession(AgentSessionId id) {
    throw UnimplementedError();
  }
}

final class _ScriptedBoundAgent implements Agent {
  _ScriptedBoundAgent(this.definition, this._script, this._inputs);

  final List<AgentRunEvent> _script;
  final List<String> _inputs;

  @override
  final AgentDefinition definition;

  @override
  AgentRun run(String input, {AgentRunOptions? options}) {
    _inputs.add(input);
    return _ScriptedAgentRun(_script);
  }

  @override
  AgentRun runTyped(LlmMessage input, {AgentRunOptions? options}) {
    throw UnimplementedError();
  }

  @override
  Future<AgentSession> createSession({
    AgentSessionId? id,
    SessionPersistence persistence = SessionPersistence.transient,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<AgentSession> restoreSession(AgentSessionId id) {
    throw UnimplementedError();
  }
}

final class _ScriptedAgentRun implements AgentRun {
  _ScriptedAgentRun(this._script) : id = RunId('scripted-${_nextId++}');

  static var _nextId = 1;

  final List<AgentRunEvent> _script;

  @override
  final RunId id;

  @override
  Stream<AgentRunEvent> get events =>
      Stream<AgentRunEvent>.fromIterable(_script);

  @override
  Future<void> cancel() async {}
}
