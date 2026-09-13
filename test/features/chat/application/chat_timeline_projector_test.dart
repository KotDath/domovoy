import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/features/chat/application/chat_timeline_projector.dart';
import 'package:domovoy/features/chat/application/chat_workspace_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/agent_harness.dart';

void main() {
  const projector = ChatTimelineProjector();

  test(
    'restored parts preserve order, identities, and correlated tool body',
    () {
      final call = LlmToolCallPart(
        callId: ToolCallId('call-a'),
        name: 'workspace.inspect',
        arguments: '{"target":"linux"}',
      );
      final transcript = AgentTranscript(
        messages: <LlmMessage>[
          LlmMessage(
            role: LlmMessageRole.user,
            parts: <LlmContentPart>[LlmTextPart('Question')],
          ),
          LlmMessage(
            role: LlmMessageRole.assistant,
            parts: <LlmContentPart>[
              LlmReasoningPart('Private chain'),
              LlmTextPart('Answer'),
              call,
            ],
          ),
          LlmMessage(
            role: LlmMessageRole.tool,
            parts: <LlmContentPart>[
              LlmToolResultPart(
                callId: call.callId,
                content: '{"status":"ready"}',
              ),
            ],
          ),
        ],
        messageIds: <AgentTranscriptMessageId?>[
          AgentTranscriptMessageId('message-user'),
          AgentTranscriptMessageId('message-assistant'),
          AgentTranscriptMessageId('message-tool'),
        ],
      );
      final first = projector.project(snapshot: _snapshot(transcript));
      final second = projector.project(
        snapshot: _snapshot(transcript, revision: 9),
      );

      expect(first.items, <Matcher>[
        isA<ChatUserItem>(),
        isA<ChatReasoningItem>(),
        isA<ChatAssistantItem>(),
        isA<ChatToolItem>(),
      ]);
      expect(
        first.items.map((item) => item.key),
        second.items.map((item) => item.key),
      );
      final tool = first.items.whereType<ChatToolItem>().single;
      expect(tool.status, ChatToolStatus.succeeded);
      expect(tool.displayArguments, contains('\n'));
      expect(tool.displayResult, contains('ready'));
      expect(first.items.whereType<ChatUnsupportedPartItem>(), isEmpty);
    },
  );

  test(
    'fragmented live response is ordered and replaced by persisted content',
    () {
      final call = LlmToolCallPart(
        callId: ToolCallId('call-live'),
        name: 'read.file',
        arguments: 'not-json',
      );
      var live = ChatLiveRunState(
        runId: RunId('run-live'),
        sessionId: AgentSessionId('chat'),
      );
      for (final event in <AgentRunEvent>[
        const AgentReasoningDelta('rea'),
        const AgentReasoningDelta('son'),
        const AgentAnswerDelta('hel'),
        const AgentAnswerDelta('lo'),
        AgentToolAssembled(<LlmToolCallPart>[call]),
        AgentToolStarted(callId: call.callId, name: call.name),
        AgentToolProgress(callId: call.callId, detail: 'half'),
        AgentToolFinished(callId: call.callId, success: true),
      ]) {
        live = live.fold(event);
      }

      final liveProjection = projector.project(
        snapshot: _snapshot(
          AgentTranscript(
            messages: <LlmMessage>[
              LlmMessage(
                role: LlmMessageRole.user,
                parts: <LlmContentPart>[LlmTextPart('Question')],
              ),
            ],
          ),
        ),
        liveRun: live,
      );
      expect(
        liveProjection.items.whereType<ChatReasoningItem>().single.text,
        'reason',
      );
      expect(
        liveProjection.items.whereType<ChatAssistantItem>().single.text,
        'hello',
      );
      final liveTool = liveProjection.items.whereType<ChatToolItem>().single;
      expect(liveTool.displayArguments, 'not-json');
      expect(liveTool.progress, 'half');

      final committed = AgentTranscript(
        messages: <LlmMessage>[
          LlmMessage(
            role: LlmMessageRole.user,
            parts: <LlmContentPart>[LlmTextPart('Question')],
          ),
          LlmMessage(
            role: LlmMessageRole.assistant,
            parts: <LlmContentPart>[
              LlmReasoningPart('reason'),
              LlmTextPart('hello'),
              call,
            ],
          ),
          LlmMessage(
            role: LlmMessageRole.tool,
            parts: <LlmContentPart>[
              LlmToolResultPart(callId: call.callId, content: 'result body'),
            ],
          ),
        ],
      );
      final replaced = projector.project(
        snapshot: _snapshot(committed),
        liveRun: live,
      );
      expect(replaced.items.whereType<ChatReasoningItem>(), hasLength(1));
      expect(replaced.items.whereType<ChatAssistantItem>(), hasLength(1));
      expect(replaced.items.whereType<ChatToolItem>(), hasLength(1));
      expect(
        replaced.items.whereType<ChatAssistantItem>().single.text,
        'hello',
      );
      expect(
        replaced.items.whereType<ChatToolItem>().single.result,
        'result body',
      );
    },
  );

  test('partial failure stays visible and raw error detail is excluded', () {
    var live = ChatLiveRunState(
      runId: RunId('run-failed'),
      sessionId: AgentSessionId('chat'),
    );
    live = live.fold(const AgentAnswerDelta('partial'));
    live = live.fold(
      AgentRunFailed(
        AgentError(
          kind: AgentErrorKind.provider,
          message: 'sk-secret /private/provider-payload',
        ),
      ),
    );

    final projection = projector.project(
      snapshot: _snapshot(AgentTranscript()),
      liveRun: live,
    );
    expect(
      projection.items.whereType<ChatAssistantItem>().single.text,
      'partial',
    );
    final error = projection.items.whereType<ChatErrorItem>().single;
    expect(error.message, isNot(contains('secret')));
    expect(error.message, isNot(contains('/private')));
  });

  test(
    'multiple tool calls correlate distinct outcomes without orphan cards',
    () {
      final firstCall = LlmToolCallPart(
        callId: ToolCallId('call-first'),
        name: 'first.tool',
        arguments: '{"value":1}',
      );
      final secondCall = LlmToolCallPart(
        callId: ToolCallId('call-second'),
        name: 'second.tool',
        arguments: '{"value":2}',
      );
      var live = ChatLiveRunState(
        runId: RunId('run-tools'),
        sessionId: AgentSessionId('chat'),
      );
      for (final event in <AgentRunEvent>[
        AgentToolAssembled(<LlmToolCallPart>[firstCall, secondCall]),
        AgentToolFinished(callId: firstCall.callId, success: true),
        AgentToolFinished(callId: secondCall.callId, success: false),
      ]) {
        live = live.fold(event);
      }
      final transcript = AgentTranscript(
        messages: <LlmMessage>[
          LlmMessage(
            role: LlmMessageRole.assistant,
            parts: <LlmContentPart>[firstCall, secondCall],
          ),
          LlmMessage(
            role: LlmMessageRole.tool,
            parts: <LlmContentPart>[
              LlmToolResultPart(
                callId: firstCall.callId,
                content: '{"ok":true}',
              ),
            ],
          ),
          LlmMessage(
            role: LlmMessageRole.tool,
            parts: <LlmContentPart>[
              LlmToolResultPart(
                callId: secondCall.callId,
                content: '{"error":"denied"}',
              ),
            ],
          ),
        ],
      );

      final tools = projector
          .project(snapshot: _snapshot(transcript), liveRun: live)
          .items
          .whereType<ChatToolItem>()
          .toList();
      expect(tools, hasLength(2));
      expect(tools.map((tool) => tool.callId), <ToolCallId>[
        firstCall.callId,
        secondCall.callId,
      ]);
      expect(tools.map((tool) => tool.status), <ChatToolStatus>[
        ChatToolStatus.succeeded,
        ChatToolStatus.failed,
      ]);
      expect(tools.every((tool) => tool.result != null), isTrue);
    },
  );

  test('unknown future part projects to a stable safe fallback', () {
    final item = projector.projectContentPart(
      part: Object(),
      key: 'unknown-key',
      responseKey: 'response-key',
    );
    expect(item, isA<ChatUnsupportedPartItem>());
    expect(item.key, 'unknown-key');
  });

  test('orphan result remains visible as unsupported rather than crashing', () {
    final transcript = AgentTranscript(
      messages: <LlmMessage>[
        LlmMessage(
          role: LlmMessageRole.tool,
          parts: <LlmContentPart>[
            LlmToolResultPart(
              callId: ToolCallId('orphan'),
              content: 'opaque result',
            ),
          ],
        ),
      ],
    );
    final projection = projector.project(snapshot: _snapshot(transcript));
    expect(projection.items.whereType<ChatUnsupportedPartItem>(), hasLength(1));
  });
}

AgentSessionSnapshot _snapshot(
  AgentTranscript transcript, {
  int revision = 1,
}) => AgentSessionSnapshot(
  id: AgentSessionId('chat'),
  definition: testDefinition(),
  lifecycle: AgentSessionLifecycle.idle,
  transcript: transcript,
  usage: LlmUsage(),
  modelTurns: 0,
  toolAttempts: 0,
  revision: revision,
  compactionState: null,
);
