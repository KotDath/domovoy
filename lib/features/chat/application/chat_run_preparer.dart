import '../../../core/agents/agents.dart';
import '../../../core/llm/cancellation.dart';

final class ChatPreparedRun {
  const ChatPreparedRun({
    required this.options,
    this.onSettled,
    this.recordCompletedTurn = true,
  });
  final AgentRunOptions options;
  final bool recordCompletedTurn;
  final Future<void> Function(
    AgentSessionSnapshot snapshot,
    AgentRunEvent? terminal,
  )?
  onSettled;
}

abstract interface class ChatRunPreparer {
  Future<ChatPreparedRun?> prepare(
    AgentSessionSnapshot snapshot,
    String input,
    CancellationToken cancellation,
  );
}
