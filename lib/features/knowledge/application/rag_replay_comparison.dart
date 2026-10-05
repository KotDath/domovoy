import 'dart:convert';

import '../../../core/rag/task_state.dart';

/// Compare initial physical requests, never the isolated repair requests.
/// A live index publication or budget-dependent source change must not be
/// presented as a comparison in which only task memory differed.
void validateRagReplayComparison(
  Map<String, Object?> off,
  Map<String, Object?> on,
  RagTaskState state,
) {
  Map signature(Map<String, Object?> row, bool enabled) {
    final trace = (row['traces'] as List).whereType<Map>().singleWhere(
      (t) => t['protocol'] == 'm1' && t['answer_attempt_ordinal'] == 0,
    );
    final request = trace['request'] as Map;
    final prompt = request['system_prompt'] as String? ?? '';
    if (trace['task_state_used'] != enabled ||
        (state.context.isNotEmpty &&
            prompt.contains(state.context) != enabled)) {
      throw StateError(
        'Сравнение недействительно: память задачи не соответствует выбранному варианту повтора.',
      );
    }
    return {
      for (final key in [
        'project',
        'session',
        'corpus',
        'strategy',
        'generation',
        'fingerprint',
        'context',
        'final_evidence_ids',
        'candidates',
      ])
        key: trace[key],
      for (final key in [
        'model',
        'generation',
        'messages',
        'tools_count',
        'continuation_count',
        'max_utf8_bytes',
      ])
        'request_$key': request[key],
      // Removing the separately serialized state leaves an empty separator.
      // Retain all nonempty lines exactly, including document whitespace.
      'nonstate_prompt': prompt
          .replaceAll(state.context, '')
          .split('\n')
          .where((line) => line.isNotEmpty)
          .join('\n'),
      'tail_message_ids': row['tail_message_ids'],
      'source_question_message_id': row['source_question_message_id'],
    };
  }

  if (jsonEncode(signature(off, false)) != jsonEncode(signature(on, true))) {
    throw StateError(
      'Сравнение недействительно: источники, история или настройки двух запросов различаются. Повторите диагностику после завершения обновлений базы знаний.',
    );
  }
}
