import 'ids.dart';
import 'transcript.dart';

final class AgentHookContext {
  AgentHookContext({
    required this.sessionId,
    required this.runId,
    required this.turnId,
    this.callId,
    required this.snapshot,
  });

  final AgentSessionId sessionId;
  final RunId runId;
  final TurnId turnId;
  final String? callId;
  final AgentSessionSnapshot snapshot;
}

abstract interface class AgentLifecycleHook {
  Future<void> beforeModelTurn(AgentHookContext context);

  Future<void> afterModelTurn(AgentHookContext context);

  Future<void> beforeTool(AgentHookContext context);

  Future<void> afterTool(AgentHookContext context);
}

base class AgentLifecycleHookBase implements AgentLifecycleHook {
  const AgentLifecycleHookBase();

  @override
  Future<void> beforeModelTurn(AgentHookContext context) async {}

  @override
  Future<void> afterModelTurn(AgentHookContext context) async {}

  @override
  Future<void> beforeTool(AgentHookContext context) async {}

  @override
  Future<void> afterTool(AgentHookContext context) async {}
}
