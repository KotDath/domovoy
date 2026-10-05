import 'dart:convert';

import 'package:domovoy/core/rag/task_state.dart';

RagTaskState changedTaskState(
  RagTaskState before,
  String value, {
  String source = 'automatic_user_quote',
}) =>
    RagTaskPatch.parse(
      jsonEncode({
        'updates': [
          {'id': 'constraint.time', 'kind': 'constraint', 'quote': value},
        ],
      }),
      '🌙 Chosen time: $value',
      before,
    ).apply(
      before,
      userText: '🌙 Chosen time: $value',
      submissionId: 'submission-${before.revision + 1}',
      sourceKind: source,
    );
