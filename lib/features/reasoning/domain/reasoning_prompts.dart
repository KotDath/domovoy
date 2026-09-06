import '../../prompt/domain/agent.dart';

String buildDirectPrompt(String task) => task.trim();

String buildStepByStepPrompt(String task) {
  final snapshot = task.trim();
  return '$snapshot\n\n'
      '---\n'
      'Решите задачу по шагам: выписывайте промежуточные выводы, '
      'проверяйте каждое допущение и в конце сверьте заключение со всеми условиями.\n'
      '---';
}

String buildPromptBuilderPrompt(String task) {
  final snapshot = task.trim();
  return 'Составьте самодостаточный промпт-решатель для следующей задачи.\n'
      'Промпт должен сохранять каждое условие, требовать проверить единственность '
      'решения и не ссылаться на этот служебный запрос.\n'
      'Верните только текст промпта, без пояснений и без обёртки.\n\n'
      'Задача:\n'
      '---\n'
      '$snapshot\n'
      '---';
}

String buildGeneratedSolverPrompt({
  required String generatedInstructions,
  required String originalTask,
}) {
  return 'Инструкции решателя:\n'
      '---\n'
      '${generatedInstructions.trim()}\n'
      '---\n\n'
      'Исходная задача (неизменяемый снимок; сохраните каждое условие):\n'
      '---\n'
      '${originalTask.trim()}\n'
      '---';
}

String buildExpertGroupPrompt(String task) {
  final snapshot = task.trim();
  return '$snapshot\n\n'
      '---\n'
      'Работают три эксперта. Каждый рассуждает независимо в своей секции:\n'
      '## Аналитик\n'
      '## Инженер\n'
      '## Критик\n'
      'Затем дайте синтез, который согласует разногласия и выдаёт итоговый ответ.\n'
      '---';
}

AgentInput day3AgentInput(String text) =>
    AgentInput(text, thinking: ThinkingMode.disabled);

AgentInput buildDirectInput(String task) =>
    day3AgentInput(buildDirectPrompt(task));

AgentInput buildStepByStepInput(String task) =>
    day3AgentInput(buildStepByStepPrompt(task));

AgentInput buildPromptBuilderInput(String task) =>
    day3AgentInput(buildPromptBuilderPrompt(task));

AgentInput buildGeneratedSolverInput({
  required String generatedInstructions,
  required String originalTask,
}) => day3AgentInput(
  buildGeneratedSolverPrompt(
    generatedInstructions: generatedInstructions,
    originalTask: originalTask,
  ),
);

AgentInput buildExpertGroupInput(String task) =>
    day3AgentInput(buildExpertGroupPrompt(task));
