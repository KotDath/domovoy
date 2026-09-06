import '../domain/agent.dart';

final class ChatCompletionsProviderProfile {
  const ChatCompletionsProviderProfile({
    required this.endpoint,
    required this.model,
    required this.reasoningDeltaField,
    this.answerDeltaField = 'content',
    this.requestExtensions = const <String, Object?>{},
  });

  factory ChatCompletionsProviderProfile.deepSeekV4Flash() {
    return ChatCompletionsProviderProfile(
      endpoint: Uri.parse('https://api.deepseek.com/chat/completions'),
      model: 'deepseek-v4-flash',
      reasoningDeltaField: 'reasoning_content',
      requestExtensions: const <String, Object?>{
        'thinking': <String, String>{'type': 'enabled'},
        'reasoning_effort': 'high',
      },
    );
  }

  final Uri endpoint;
  final String model;
  final String reasoningDeltaField;
  final String answerDeltaField;
  final Map<String, Object?> requestExtensions;

  Map<String, Object?> requestBody(AgentInput input) => <String, Object?>{
    'model': model,
    'messages': <Map<String, String>>[
      <String, String>{'role': 'user', 'content': input.text},
    ],
    'stream': true,
    ...requestExtensions,
  };
}
