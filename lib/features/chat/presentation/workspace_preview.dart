import 'package:flutter/material.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../application/chat_timeline_projector.dart';
import '../application/chat_token_presenter.dart';
import '../application/chat_workspace_state.dart';
import 'chat_composer.dart';
import 'chat_timeline.dart';

/// Deterministic visual fixture composed from the production H4 widgets.
class WorkspacePreviewTimeline extends StatelessWidget {
  const WorkspacePreviewTimeline({super.key});

  @override
  Widget build(BuildContext context) => ChatTimeline(
    projection: ChatTimelineProjection(<ChatTimelineItem>[
      const ChatUserItem(
        key: 'user-preview',
        text: 'Create a concise release checklist for Linux and web.',
      ),
      const ChatReasoningItem(
        key: 'reasoning-preview',
        responseKey: 'response-preview',
        text: 'Check the supported build targets and verification evidence.',
      ),
      ChatToolItem(
        key: 'tool-preview',
        callId: ToolCallId('preview-call'),
        name: 'workspace.inspect',
        arguments: '{"targets":["linux","web"],"mode":"read-only"}',
        displayArguments:
            '{\n  "targets": [\n    "linux",\n    "web"\n  ],\n'
            '  "mode": "read-only"\n}',
        status: ChatToolStatus.succeeded,
        result: '{"status":"ready"}',
        displayResult: '{\n  "status": "ready"\n}',
      ),
      const ChatAssistantItem(
        key: 'assistant-preview',
        text:
            'Release checklist\n\n• Run formatting, analysis, and tests.\n'
            '• Build Linux and web from one verified tree.\n'
            '• Record commands, outputs, and revision.',
      ),
    ]),
  );
}

ChatTokenProjection workspacePreviewTokenProjection() {
  final accounting = const AgentTokenAccountingProjector().project(
    state: AgentTokenAccountingState.legacy(
      transcriptMessageCount: 0,
      usage: LlmUsage(totalTokens: 8400),
    ),
    retainedContextMeasurement: AgentRetainedContextMeasurement(
      contextRevision: 0,
      estimatorId: Utf8FramingAgentContextEstimator.defaultId,
      estimatorVersion: Utf8FramingAgentContextEstimator.defaultVersion,
      estimate: 4200,
    ),
  );
  return const ChatTokenPresenter().present(
    accounting: accounting,
    selectedModel: BuiltInLlmCatalog.gpt54Model,
  );
}

class WorkspacePreviewComposer extends StatelessWidget {
  const WorkspacePreviewComposer({
    required this.groups,
    required this.selection,
    super.key,
  });

  final List<LlmProviderGroup> groups;
  final AgentSessionSelection selection;

  @override
  Widget build(BuildContext context) => ChatComposer(
    providerGroups: groups,
    selection: selection,
    onSend: (_) async => const ChatCommandResult.succeeded(),
    onStop: () async => const ChatCommandResult.succeeded(),
    onSelectionChanged: (_) async => const ChatCommandResult.unchanged(),
    running: false,
    enabled: true,
    initialDraft: 'Prepare the verified release evidence.',
    tokenProjection: workspacePreviewTokenProjection(),
  );
}
