import '../../../core/agents/agents.dart';

/// One controller-issued, identity-bound confirmation payload.
final class ChatDeletionIntent {
  ChatDeletionIntent({
    required this.chatId,
    required String displayTitle,
    required String token,
  }) : displayTitle = displayTitle.trim(),
       token = token.trim() {
    if (this.displayTitle.isEmpty || this.token.isEmpty) {
      throw ArgumentError('Deletion intent metadata must not be blank.');
    }
  }

  final AgentSessionId chatId;
  final String displayTitle;
  final String token;
}
