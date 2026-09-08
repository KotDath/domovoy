import '../domain/agent.dart';

final class ChatCompletionsProviderProfile {
  const ChatCompletionsProviderProfile({
    required this.endpoint,
    required this.model,
    required this.reasoningDeltaField,
    this.answerDeltaField = 'content',
  });

  factory ChatCompletionsProviderProfile.deepSeekV4Flash() {
    return ChatCompletionsProviderProfile(
      endpoint: Uri.parse('https://api.deepseek.com/chat/completions'),
      model: 'deepseek-v4-flash',
      reasoningDeltaField: 'reasoning_content',
    );
  }

  final Uri endpoint;
  final String model;
  final String reasoningDeltaField;
  final String answerDeltaField;

  Map<String, Object?> requestBody(AgentInput input) {
    final body = <String, Object?>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': input.text},
      ],
      'stream': true,
      'stream_options': const <String, Object?>{'include_usage': true},
    };
    if (input.thinking == ThinkingMode.enabled) {
      body['thinking'] = const <String, String>{'type': 'enabled'};
      body['reasoning_effort'] = 'high';
    } else {
      body['thinking'] = const <String, String>{'type': 'disabled'};
    }

    return body;
  }
}
