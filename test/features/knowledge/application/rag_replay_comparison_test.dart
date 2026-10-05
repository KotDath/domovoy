import 'dart:convert';

import 'package:domovoy/core/rag/task_state.dart';
import 'package:domovoy/features/knowledge/application/rag_replay_comparison.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/rag_task_state_fixture.dart';

void main() {
  final state = changedTaskState(
    RagTaskState(project: 'A', session: 'one'),
    '08:30',
  );
  Map<String, Object?> row(bool on) => {
    'tail_message_ids': ['user-1', 'assistant-1'],
    'source_question_message_id': 'user-2',
    'traces': [
      {
        'protocol': 'm1',
        'answer_attempt_ordinal': 0,
        'task_state_used': on,
        'project': 'A',
        'session': 'one',
        'corpus': 'domovoy',
        'strategy': 'fixed',
        'generation': 'original',
        'fingerprint': 'embedding',
        'context': 'original document',
        'final_evidence_ids': ['chunk-1'],
        'candidates': [
          {
            'sent': true,
            'chunk': {'id': 'chunk-1', 'text': 'original document'},
          },
        ],
        'request': {
          'model': 'same-model',
          'generation': {'temperature': 0},
          'messages': ['actual-user', 'actual-assistant', 'last-question'],
          'tools_count': 0,
          'continuation_count': 0,
          'max_utf8_bytes': 100000,
          'system_prompt':
              'instruction\n\n${on ? '${state.context}\n\n' : ''}original document',
        },
      },
      // Repair requests are isolated and need not have the original history.
      {'protocol': 'm1', 'answer_attempt_ordinal': 1},
    ],
  };

  test(
    'matching initial requests differ only in separately serialized state',
    () {
      expect(
        () => validateRagReplayComparison(row(false), row(true), state),
        returnsNormally,
      );
    },
  );

  for (final change in [
    'generation',
    'context',
    'messages',
    'model',
    'settings',
  ]) {
    test('changed $change invalidates the paired replay', () {
      final on = row(true);
      final trace = (on['traces'] as List).first as Map;
      final request = trace['request'] as Map;
      switch (change) {
        case 'generation':
          trace['generation'] = 'published-between-requests';
        case 'context':
          trace['context'] = 'different budget-selected document';
        case 'messages':
          request['messages'] = [
            'different user',
            'same assistant',
            'last-question',
          ];
        case 'model':
          request['model'] = 'other-model';
        case 'settings':
          request['generation'] = {'temperature': 1};
      }
      expect(
        () => validateRagReplayComparison(row(false), on, state),
        throwsStateError,
      );
      expect(jsonEncode(on), isNotEmpty);
    });
  }
}
