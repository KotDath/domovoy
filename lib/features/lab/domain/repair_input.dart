import '../../prompt/domain/agent.dart';

AgentInput buildFormatRepairInput({
  required String originalTask,
  required FormatControl control,
  required String invalidAnswer,
  required List<String> diagnostics,
  ThinkingMode thinking = ThinkingMode.enabled,
}) {
  final task = originalTask.trim();
  if (task.isEmpty) {
    throw ArgumentError.value(
      originalTask,
      'originalTask',
      'Original task must not be empty.',
    );
  }
  final buffer = StringBuffer()
    ..writeln('Исходная задача:')
    ..writeln(task)
    ..writeln()
    ..writeln('Требуемый формат:');
  final formatKind = control.kind == ResponseFormatKind.json
      ? 'JSON'
      : 'Markdown';
  buffer.writeln('($formatKind) ${control.contractText.trim()}');
  final example = control.exampleText?.trim();
  if (example != null && example.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('Пример:')
      ..writeln(example);
  }
  buffer
    ..writeln()
    ..writeln('Невалидный ответ:')
    ..writeln(invalidAnswer.trim().isEmpty ? '(пусто)' : invalidAnswer.trim())
    ..writeln()
    ..writeln('Замечания проверки:');
  if (diagnostics.isEmpty) {
    buffer.writeln('- (нет деталей)');
  } else {
    for (final diagnostic in diagnostics) {
      buffer.writeln('- $diagnostic');
    }
  }
  buffer
    ..writeln()
    ..writeln(
      'Исправь ответ строго по требуемому формату без пояснений вне формата.',
    );
  return AgentInput(
    buffer.toString(),
    thinking: thinking,
    control: FormatControl(
      kind: control.kind,
      contractText: control.contractText,
      exampleText: control.exampleText,
    ),
  );
}
