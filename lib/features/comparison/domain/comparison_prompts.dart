import '../../prompt/domain/agent.dart';
import 'chat_model_profile.dart';

const String kComparisonStarterPrompt =
    'Напиши достаточно полную реализацию Entity-Component-System (ECS) на языке '
    'Dart, основанную на sparse sets.\n\n'
    'Включи структуру данных и инварианты, в том числе sparse/dense отображение '
    'сущностей; операции создания и удаления сущностей, добавления и получения '
    'компонентов, а также query по компонентам; поведение swap-remove при '
    'удалении; оценку сложности ключевых операций, включая O(1) там, где это '
    'даёт sparse set; хранение компонентов (component storage); рабочий пример '
    'кода в блоке Dart.\n\n'
    'Не используй внешние пакеты. Код должен быть самодостаточным.';

AgentInput buildComparisonLaneInput(String prompt) {
  return AgentInput(prompt, thinking: ThinkingMode.disabled);
}

String comparisonLaneTitle(ChatModelProfile profile) {
  return '${comparisonTierLabel(profile.tier)} · ${profile.label}';
}
