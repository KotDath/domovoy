import 'dart:async';

import 'package:domovoy/features/prompt/domain/agent.dart';
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

final class ControlledAgent implements Agent {
  final List<AgentInput> inputs = <AgentInput>[];
  final List<StreamController<AgentEvent>> controllers =
      <StreamController<AgentEvent>>[];

  @override
  Stream<AgentEvent> prompt(AgentInput input) {
    inputs.add(input);
    final controller = StreamController<AgentEvent>();
    controllers.add(controller);
    return controller.stream;
  }

  StreamController<AgentEvent> get latest => controllers.last;
}

final class ScriptedAgent implements Agent {
  ScriptedAgent(this.events);

  final List<AgentEvent> events;
  final List<AgentInput> inputs = <AgentInput>[];

  @override
  Stream<AgentEvent> prompt(AgentInput input) {
    inputs.add(input);
    return Stream<AgentEvent>.fromIterable(events);
  }
}
