import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/memory/memory.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/memory_fixtures.dart';

Matcher _memoryError(MemoryErrorKind kind) => throwsA(
  isA<MemoryException>().having((error) => error.error.kind, 'kind', kind),
);

CancellationToken _token() => CancellationSource().token;

final class _ScriptedInvocation implements MemoryExtractionLlmInvocation {
  _ScriptedInvocation({
    required this.model,
    required this.turns,
    this.closeWithoutTerminal = false,
  });

  final LlmModel model;
  final List<List<LlmEvent>> turns;
  final bool closeWithoutTerminal;
  final List<LlmRequest> requests = <LlmRequest>[];
  var _index = 0;

  @override
  LlmModel resolve(ModelRef ref) => model;

  @override
  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  }) async* {
    requests.add(request);
    final events = _index < turns.length ? turns[_index++] : const <LlmEvent>[];
    for (final event in events) {
      yield event;
      if (event.isTerminal) {
        return;
      }
    }
    if (closeWithoutTerminal) {
      return;
    }
    yield const LlmCompleted(finishReason: LlmFinishReason.stop);
  }
}

List<LlmEvent> _reply(String text) => <LlmEvent>[
  LlmTextDelta(text),
  const LlmCompleted(finishReason: LlmFinishReason.stop),
];

MemoryExtractionInput _input({
  List<MemoryExtractionSource>? sources,
  List<MemoryEntry> activeEntries = const <MemoryEntry>[],
}) {
  return MemoryExtractionInput(
    projectId: ProjectId('project-1'),
    sources:
        sources ??
        <MemoryExtractionSource>[
          MemoryExtractionSource(
            id: MemorySourceId('source-1'),
            role: MemoryTranscriptRole.user,
            text: 'Deployment uses kubernetes.',
          ),
        ],
    activeEntries: activeEntries,
  );
}

LlmMemoryBatchExtractor _extractor(
  _ScriptedInvocation llm, {
  int maxOutputCharacters = 16384,
}) {
  return LlmMemoryBatchExtractor(
    llm: llm,
    model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
    maxOutputCharacters: maxOutputCharacters,
  );
}

void main() {
  final model = BuiltInLlmCatalog.deepSeekV4FlashModel;

  group('LlmMemoryBatchExtractor strict parsing', () {
    test('maps create, update, and noop proposals', () async {
      final llm = _ScriptedInvocation(
        model: model,
        turns: <List<LlmEvent>>[
          _reply(
            '{"proposals":['
            '{"operation":"create","layer":"working","scope":"project",'
            '"kind":"fact","content":"Deployment uses kubernetes."},'
            '{"operation":"update","layer":"longTerm","scope":"global",'
            '"kind":"fact","content":"Prefers dark mode.",'
            '"targetEntryId":"entry-1"},'
            '{"operation":"noop"}'
            ']}',
          ),
        ],
      );
      final drafts = await _extractor(
        llm,
      ).extract(_input(), cancellation: _token());

      expect(drafts, hasLength(2));
      expect(drafts[0].operation, MemoryProposalOperation.create);
      expect(drafts[0].layer, MemoryLayer.working);
      expect(drafts[0].scope, MemoryScope.project);
      expect(drafts[0].kind, MemoryKind.fact);
      expect(drafts[0].content, 'Deployment uses kubernetes.');
      expect(drafts[0].targetEntryId, isNull);
      expect(drafts[1].operation, MemoryProposalOperation.update);
      expect(drafts[1].targetEntryId, MemoryEntryId('entry-1'));
    });

    test('rejects malformed or non-conforming JSON', () async {
      Future<void> expectProtocol(String text) async {
        final llm = _ScriptedInvocation(
          model: model,
          turns: <List<LlmEvent>>[_reply(text)],
        );
        await expectLater(
          _extractor(llm).extract(_input(), cancellation: _token()),
          _memoryError(MemoryErrorKind.protocol),
        );
      }

      await expectProtocol('not json');
      await expectProtocol('[1,2,3]');
      await expectProtocol('{"proposals":{},"extra":true}');
      await expectProtocol(
        '{"proposals":[{"operation":"create","layer":"working",'
        '"scope":"project","kind":"fact","content":"x","extra":1}]}',
      );
      await expectProtocol(
        '{"proposals":[{"operation":"create","layer":"working",'
        '"scope":"project","kind":"fact"}]}',
      );
      await expectProtocol(
        '{"proposals":[{"operation":"invent","layer":"working",'
        '"scope":"project","kind":"fact","content":"x"}]}',
      );
    });

    test(
      'rejects tool calls, provider failures, and unterminated output',
      () async {
        final toolCall = _ScriptedInvocation(
          model: model,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              LlmToolCallDelta(
                callId: ToolCallId('call-1'),
                index: 0,
                name: 'search',
                argumentsFragment: '{}',
              ),
            ],
          ],
        );
        await expectLater(
          _extractor(toolCall).extract(_input(), cancellation: _token()),
          _memoryError(MemoryErrorKind.protocol),
        );

        final failed = _ScriptedInvocation(
          model: model,
          turns: <List<LlmEvent>>[
            <LlmEvent>[
              LlmFailed(LlmError(kind: LlmErrorKind.provider, message: 'boom')),
            ],
          ],
        );
        await expectLater(
          _extractor(failed).extract(_input(), cancellation: _token()),
          _memoryError(MemoryErrorKind.protocol),
        );

        final unterminated = _ScriptedInvocation(
          model: model,
          turns: const <List<LlmEvent>>[
            <LlmEvent>[LlmTextDelta('{"proposals":[]}')],
          ],
          closeWithoutTerminal: true,
        );
        await expectLater(
          _extractor(unterminated).extract(_input(), cancellation: _token()),
          _memoryError(MemoryErrorKind.protocol),
        );
      },
    );

    test('enforces the output bound', () async {
      final llm = _ScriptedInvocation(
        model: model,
        turns: <List<LlmEvent>>[_reply('{"proposals":[]}')],
      );
      await expectLater(
        _extractor(
          llm,
          maxOutputCharacters: 4,
        ).extract(_input(), cancellation: _token()),
        _memoryError(MemoryErrorKind.protocol),
      );
    });
  });

  group('LlmMemoryBatchExtractor isolation', () {
    test('carries no tools, continuations, or transcript history', () async {
      final active = workingEntry(id: 'entry-active');
      final llm = _ScriptedInvocation(
        model: model,
        turns: <List<LlmEvent>>[_reply('{"proposals":[]}')],
      );
      await _extractor(llm).extract(
        _input(
          sources: <MemoryExtractionSource>[
            MemoryExtractionSource(
              id: MemorySourceId('source-1'),
              role: MemoryTranscriptRole.user,
              text: 'Deployment uses kubernetes.',
            ),
          ],
          activeEntries: <MemoryEntry>[active],
        ),
        cancellation: _token(),
      );

      final request = llm.requests.single;
      expect(request.context.tools, isEmpty);
      expect(request.context.continuationEntries, isEmpty);
      expect(request.context.messages, hasLength(1));
      expect(request.context.systemPrompt, LlmMemoryBatchExtractor.instruction);
      final payload =
          (request.context.messages.single.parts.single as LlmTextPart).text;
      expect(payload, contains('Deployment uses kubernetes.'));
      expect(payload, contains(active.content));
      expect(payload, contains('project-1'));
      expect(payload, contains('untrusted'));
    });

    test('registry adapter extracts through a scripted provider', () async {
      final provider = QueueScriptedLlmProvider(
        id: BuiltInLlmCatalog.deepSeek,
        wireFamily: LlmWireFamily.openaiChatCompletions,
        turns: <List<LlmEvent>>[
          _reply(
            '{"proposals":[{"operation":"create","layer":"longTerm",'
            '"scope":"global","kind":"preference","content":"Prefers tea."}]}',
          ),
        ],
      );
      final registry = LlmProviderRegistry();
      BuiltInLlmCatalog.registerInto(registry);
      registry.registerProvider(provider);
      final extractor = LlmMemoryBatchExtractor(
        llm: RegistryMemoryExtractionLlmInvocation(registry),
        model: BuiltInLlmCatalog.deepSeekV4FlashModel.ref,
      );

      final drafts = await extractor.extract(_input(), cancellation: _token());
      expect(drafts, hasLength(1));
      expect(drafts.single.layer, MemoryLayer.longTerm);
      expect(drafts.single.kind, MemoryKind.preference);
      expect(provider.requests, hasLength(1));
    });
  });
}
