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
    );
  }

  final Uri endpoint;
  final String model;
  final String reasoningDeltaField;
  final String answerDeltaField;
  final Map<String, Object?> requestExtensions;

  Map<String, Object?> requestBody(AgentInput input) {
    final body = <String, Object?>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': userContent(input)},
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

    final control = input.control;
    if (control is FormatControl) {
      if (control.useJsonModeResolved) {
        body['response_format'] = const <String, String>{'type': 'json_object'};
      }
    } else if (control is LengthControl) {
      body['max_tokens'] = control.maxTokens;
    } else if (control is StopControl) {
      body['stop'] = <String>[control.marker];
    }

    body.addAll(requestExtensions);
    return body;
  }

  String userContent(AgentInput input) {
    final control = input.control;
    if (control is FormatControl) {
      final buffer = StringBuffer(input.text);
      buffer.writeln();
      buffer.writeln();
      buffer.writeln('---');
      if (control.kind == ResponseFormatKind.json) {
        buffer.writeln('Ответь строго в формате JSON.');
      }
      buffer.writeln('Требуемый формат:');
      buffer.writeln(control.contractText.trim());
      final example = control.exampleText?.trim();
      if (example != null && example.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('Пример:');
        buffer.writeln(example);
      }
      return buffer.toString().trim();
    }
    if (control is LengthControl) {
      return '${input.text}\n\nОграничение: ответ должен содержать '
          'не более ${control.maxChars} символов.';
    }
    return input.text;
  }
}
