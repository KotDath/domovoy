import 'package:domovoy/core/llm/llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('reasoning capability and continuation', () {
    test('rejects mode/effort combinations that models do not declare', () {
      expect(
        () => validateRequestAgainstModel(
          LlmRequest(
            model: BuiltInLlmCatalog.gpt4oMiniModel.ref,
            generation: LlmGenerationConfig(
              reasoningMode: ReasoningMode.enabled,
            ),
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
          ),
          BuiltInLlmCatalog.gpt4oMiniModel,
        ),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => validateRequestAgainstModel(
          LlmRequest(
            model: BuiltInLlmCatalog.kimiK26Model.ref,
            generation: LlmGenerationConfig(
              reasoningEffort: ReasoningEffort.high,
            ),
            context: LlmContext(
              messages: <LlmMessage>[
                LlmMessage(
                  role: LlmMessageRole.user,
                  parts: <LlmContentPart>[LlmTextPart('hi')],
                ),
              ],
            ),
          ),
          BuiltInLlmCatalog.kimiK26Model,
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('turn state round-trips and hides payload from toString', () {
      final state = LlmProviderTurnState(
        origin: BuiltInLlmCatalog.gpt54Model.ref,
        wireFamily: LlmWireFamily.openaiResponses,
        format: openaiResponsesOutputItemsV1,
        payload: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'reasoning',
            'id': 'rs_1',
            'encrypted_content': 'secret-blob',
          },
          <String, Object?>{
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_1',
            'name': 'lookup',
            'arguments': '{}',
          },
        ],
      );
      expect(LlmProviderTurnState.fromJson(state.toJson()), state);
      expect(state.toString(), isNot(contains('secret-blob')));
      expect(
        state.diagnosticSummary().toString(),
        isNot(contains('secret-blob')),
      );
      final completed = LlmCompleted(turnState: state);
      expect(completed.toString(), isNot(contains('secret-blob')));
    });

    test('continuation entries must match assistant indexes and origin', () {
      final messages = <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.user,
          parts: <LlmContentPart>[LlmTextPart('q')],
        ),
        LlmMessage(
          role: LlmMessageRole.assistant,
          parts: <LlmContentPart>[
            LlmToolCallPart(
              callId: ToolCallId('call_1'),
              name: 'lookup',
              arguments: '{}',
            ),
          ],
        ),
      ];
      final state = LlmProviderTurnState(
        origin: BuiltInLlmCatalog.gpt54Model.ref,
        wireFamily: LlmWireFamily.openaiResponses,
        format: openaiResponsesOutputItemsV1,
        payload: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_1',
            'name': 'lookup',
            'arguments': '{}',
          },
        ],
      );
      expect(
        () => validateContinuationEntries(
          messages: messages,
          entries: <LlmContinuationEntry>[
            LlmContinuationEntry(assistantMessageIndex: 0, state: state),
          ],
          origin: BuiltInLlmCatalog.gpt54Model.ref,
          wireFamily: LlmWireFamily.openaiResponses,
        ),
        throwsA(isA<LlmException>()),
      );
      validateContinuationEntries(
        messages: messages,
        entries: <LlmContinuationEntry>[
          LlmContinuationEntry(assistantMessageIndex: 1, state: state),
        ],
        origin: BuiltInLlmCatalog.gpt54Model.ref,
        wireFamily: LlmWireFamily.openaiResponses,
      );
    });

    test('rejects extra fields and mismatched function-call payloads', () {
      expect(
        () => LlmProviderTurnState(
          origin: BuiltInLlmCatalog.gpt54Model.ref,
          wireFamily: LlmWireFamily.openaiResponses,
          format: openaiResponsesOutputItemsV1,
          payload: <Map<String, Object?>>[
            <String, Object?>{
              'type': 'reasoning',
              'id': 'rs_1',
              'extra': 'nope',
            },
          ],
        ),
        throwsA(isA<LlmException>()),
      );
    });

    test('accepts official reasoning_text and output_text annotations', () {
      final state = LlmProviderTurnState(
        origin: BuiltInLlmCatalog.gpt54Model.ref,
        wireFamily: LlmWireFamily.openaiResponses,
        format: openaiResponsesOutputItemsV1,
        payload: <Map<String, Object?>>[
          <String, Object?>{
            'type': 'reasoning',
            'id': 'rs_1',
            'status': 'completed',
            'content': <Map<String, Object?>>[
              <String, Object?>{'type': 'reasoning_text', 'text': 'think'},
            ],
            'encrypted_content': 'enc',
          },
          <String, Object?>{
            'type': 'message',
            'id': 'msg_1',
            'status': 'completed',
            'role': 'assistant',
            'phase': 'final_answer',
            'content': <Map<String, Object?>>[
              <String, Object?>{
                'type': 'output_text',
                'text': 'ans',
                'annotations': <Map<String, Object?>>[
                  <String, Object?>{
                    'type': 'url_citation',
                    'url': 'https://example.com',
                    'title': 'Example',
                    'start_index': 0,
                    'end_index': 3,
                  },
                ],
              },
            ],
          },
        ],
      );
      expect(state.itemCount, 2);
    });

    test('accepts each official output_text annotation variant', () {
      void accept(Map<String, Object?> annotation) {
        validateOpenAiResponsesOutputItem(<String, Object?>{
          'type': 'message',
          'id': 'msg_1',
          'content': <Map<String, Object?>>[
            <String, Object?>{
              'type': 'output_text',
              'text': 'ans',
              'annotations': <Map<String, Object?>>[annotation],
            },
          ],
        });
      }

      accept(<String, Object?>{
        'type': 'url_citation',
        'url': 'https://example.com/doc',
        'title': 'Doc',
        'start_index': 0,
        'end_index': 3,
      });
      accept(<String, Object?>{
        'type': 'file_citation',
        'file_id': 'file_1',
        'index': 0,
        'filename': 'notes.txt',
      });
      accept(<String, Object?>{
        'type': 'container_file_citation',
        'container_id': 'ctr_1',
        'file_id': 'file_2',
        'start_index': 1,
        'end_index': 4,
        'filename': 'blob.bin',
      });
      accept(<String, Object?>{
        'type': 'file_path',
        'file_id': 'file_3',
        'index': 2,
      });
    });

    test('rejects malformed output_text annotation variants', () {
      void reject(Map<String, Object?> annotation) {
        expect(
          () => validateOpenAiResponsesOutputItem(<String, Object?>{
            'type': 'message',
            'id': 'msg_1',
            'content': <Map<String, Object?>>[
              <String, Object?>{
                'type': 'output_text',
                'text': 'ans',
                'annotations': <Map<String, Object?>>[annotation],
              },
            ],
          }),
          throwsA(isA<LlmException>()),
        );
      }

      reject(<String, Object?>{
        'type': 'url_citation',
        'url': 'https://example.com',
        'start_index': 0,
        'end_index': 3,
      });
      reject(<String, Object?>{
        'type': 'url_citation',
        'url': 'https://example.com',
        'title': 'Doc',
        'start_index': '0',
        'end_index': 3,
      });
      reject(<String, Object?>{
        'type': 'url_citation',
        'url': 'https://example.com',
        'title': 'Doc',
        'start_index': 0,
        'end_index': 3,
        'extra': true,
      });
      reject(<String, Object?>{'type': 'file_citation', 'file_id': 'file_1'});
      reject(<String, Object?>{
        'type': 'file_citation',
        'file_id': 'file_1',
        'index': 0,
      });
      reject(<String, Object?>{
        'type': 'file_citation',
        'file_id': 'file_1',
        'index': 0,
        'filename': 1,
      });
      reject(<String, Object?>{
        'type': 'file_citation',
        'file_id': 'file_1',
        'index': -1,
      });
      reject(<String, Object?>{
        'type': 'container_file_citation',
        'file_id': 'file_2',
        'start_index': 0,
        'end_index': 1,
      });
      reject(<String, Object?>{
        'type': 'container_file_citation',
        'container_id': 'ctr_1',
        'file_id': 'file_2',
        'start_index': 0,
        'end_index': 1,
      });
      reject(<String, Object?>{
        'type': 'container_file_citation',
        'container_id': 'ctr_1',
        'file_id': 'file_2',
        'start_index': 0,
        'end_index': 1,
        'filename': 1,
      });
      reject(<String, Object?>{
        'type': 'file_path',
        'file_id': 'file_3',
        'index': '2',
      });
    });

    test('rejects unofficial reasoning content types and statuses', () {
      expect(
        () => validateOpenAiResponsesOutputItem(<String, Object?>{
          'type': 'reasoning',
          'id': 'rs_1',
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'output_text', 'text': 'nope'},
          ],
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => validateOpenAiResponsesOutputItem(<String, Object?>{
          'type': 'message',
          'id': 12,
          'content': <Map<String, Object?>>[
            <String, Object?>{'type': 'output_text', 'text': 'ans'},
          ],
        }),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => validateOpenAiResponsesOutputItem(<String, Object?>{
          'type': 'function_call',
          'id': 'fc_1',
          'call_id': 'call_1',
          'name': 'lookup',
          'arguments': '{}',
          'status': 'bogus',
        }),
        throwsA(isA<LlmException>()),
      );
    });
  });
}
