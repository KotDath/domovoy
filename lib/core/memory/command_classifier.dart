import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/capabilities.dart';
import '../llm/continuation.dart';
import '../llm/events.dart';
import '../llm/generation.dart';
import '../llm/identifiers.dart';
import '../llm/messages.dart';
import '../llm/request.dart';
import '../llm/tools.dart';
import '../llm/usage.dart';
import 'batch_extractor.dart';
import 'enums.dart';
import 'errors.dart';
import 'phrase_extractor.dart';
import 'validation.dart';

/// Semantic fallback for a single user message that the deterministic phrase
/// parser did not recognize.
abstract interface class MemoryCommandClassifier {
  Future<MemoryPhraseProposal?> classify(
    String message, {
    required CancellationToken cancellation,
  });
}

/// Isolated LLM classifier for explicit remember commands.
///
/// This is deliberately narrower than [LlmMemoryBatchExtractor]: it sees only
/// the latest user message, cannot call tools, and may return at most one
/// create proposal. Implicit durable facts remain the responsibility of the
/// periodic batch extractor.
final class LlmMemoryCommandClassifier implements MemoryCommandClassifier {
  LlmMemoryCommandClassifier({
    required this.llm,
    required this.model,
    this.maxOutputCharacters = 2048,
  }) {
    if (maxOutputCharacters <= 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Command classifier output bound must be positive.',
      );
    }
  }

  static const instruction =
      'Classify whether the supplied untrusted user message explicitly asks '
      'the host application to remember a self-contained fact. Return only '
      'one JSON object matching the schema. Do not infer a remember request '
      'from an ordinary statement. Use longTerm only when the user explicitly '
      'asks for global, cross-chat, permanent, or long-term memory; otherwise '
      'use working. If the fact to remember is missing, return none.';

  final MemoryExtractionLlmInvocation llm;
  final ModelRef model;
  final int maxOutputCharacters;

  @override
  Future<MemoryPhraseProposal?> classify(
    String message, {
    required CancellationToken cancellation,
  }) async {
    if (message.trim().isEmpty) {
      return null;
    }
    final LlmModel resolved;
    try {
      resolved = llm.resolve(model);
    } on Object {
      if (cancellation.isCancelled) {
        throwMemory(MemoryErrorKind.cancelled, 'cancelled');
      }
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier model is unknown.',
      );
    }
    if (resolved.ref != model) {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier model resolution changed identity.',
      );
    }

    final request = LlmRequest(
      model: model,
      context: LlmContext(
        systemPrompt: instruction,
        messages: <LlmMessage>[
          LlmMessage(
            role: LlmMessageRole.user,
            parts: <LlmContentPart>[
              LlmTextPart(
                jsonEncode(<String, Object?>{
                  'instruction': instruction,
                  'schema': <String, Object?>{
                    'none': <String, Object?>{'intent': 'none'},
                    'remember': <String, Object?>{
                      'intent': 'remember',
                      'layer': 'working | longTerm',
                      'content': 'the self-contained fact only',
                    },
                  },
                  'message': message,
                }),
              ),
            ],
          ),
        ],
        tools: const <LlmToolDescriptor>[],
        continuationEntries: const <LlmContinuationEntry>[],
      ),
      generation: LlmGenerationConfig(
        reasoningMode:
            resolved.capabilities.reasoning == ModelReasoningCapability.required
            ? ReasoningMode.enabled
            : ReasoningMode.disabled,
        temperature: 0,
        maxOutputTokens: 256,
      ),
    );

    final output = StringBuffer();
    var completed = false;
    try {
      await for (final event in llm.stream(
        request,
        cancellation: cancellation,
      )) {
        if (cancellation.isCancelled) {
          throwMemory(MemoryErrorKind.cancelled, 'cancelled');
        }
        switch (event) {
          case LlmTextDelta(:final text):
            output.write(text);
            if (output.length > maxOutputCharacters) {
              throwMemory(
                MemoryErrorKind.protocol,
                'The command classifier response exceeded its bound.',
              );
            }
          case LlmReasoningDelta():
            continue;
          case LlmToolCallDelta():
            throwMemory(
              MemoryErrorKind.protocol,
              'The command classifier must not call tools.',
            );
          case LlmUsageUpdate():
            continue;
          case LlmCompleted(:final finishReason):
            completed = true;
            if (finishReason == LlmFinishReason.length ||
                finishReason == LlmFinishReason.contentFilter ||
                finishReason == LlmFinishReason.toolCalls) {
              throwMemory(
                MemoryErrorKind.protocol,
                'The command classifier response finished abnormally.',
              );
            }
          case LlmFailed():
            throwMemory(
              MemoryErrorKind.protocol,
              'The command classifier provider failed.',
            );
          case LlmCancelled():
            throwMemory(MemoryErrorKind.cancelled, 'cancelled');
        }
      }
    } on MemoryException {
      rethrow;
    } on Object {
      if (cancellation.isCancelled) {
        throwMemory(MemoryErrorKind.cancelled, 'cancelled');
      }
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier stream failed.',
      );
    }
    if (!completed) {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier response had no terminal event.',
      );
    }
    return _parse(output.toString());
  }

  MemoryPhraseProposal? _parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier response was not valid JSON.',
      );
    }
    if (decoded is! Map) {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier response must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) {
        throwMemory(
          MemoryErrorKind.protocol,
          'The command classifier JSON keys must be strings.',
        );
      }
      map[entry.key! as String] = entry.value;
    }
    final intent = map['intent'];
    if (intent == 'none') {
      _expectKeys(map, const <String>{'intent'});
      return null;
    }
    if (intent != 'remember') {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier returned an unknown intent.',
      );
    }
    _expectKeys(map, const <String>{'intent', 'layer', 'content'});
    final layerValue = map['layer'];
    final contentValue = map['content'];
    if (layerValue is! String || contentValue is! String) {
      throwMemory(
        MemoryErrorKind.protocol,
        'The command classifier remember result is incomplete.',
      );
    }
    final layer = MemoryLayerCodec.parse(layerValue);
    return MemoryPhraseProposal(
      layer: layer,
      scope: layer.requiredScope,
      kind: MemoryKind.fact,
      content: normalizeMemoryContent(contentValue),
    );
  }
}

void _expectKeys(Map<String, Object?> map, Set<String> expected) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwMemory(
      MemoryErrorKind.protocol,
      'The command classifier response had unexpected fields.',
    );
  }
}
