import '../llm/messages.dart';
import 'errors.dart';

abstract interface class AgentSessionTitlePolicy {
  String deriveTitle(LlmMessage userMessage);
}

final class DeterministicAgentSessionTitlePolicy
    implements AgentSessionTitlePolicy {
  DeterministicAgentSessionTitlePolicy({this.maxGraphemes = 48}) {
    if (maxGraphemes < 2) {
      throwAgent(
        AgentErrorKind.configuration,
        'Title bound must allow text and an ellipsis.',
      );
    }
  }

  final int maxGraphemes;

  @override
  String deriveTitle(LlmMessage userMessage) {
    if (userMessage.role != LlmMessageRole.user) {
      throwAgent(
        AgentErrorKind.configuration,
        'A chat title can only be derived from user text.',
      );
    }
    final source = userMessage.parts
        .whereType<LlmTextPart>()
        .map((part) => part.text)
        .join(' ');
    final normalized = _normalizeTitleSource(source);
    if (normalized.isEmpty) {
      throwAgent(
        AgentErrorKind.configuration,
        'A chat title requires non-blank user text.',
      );
    }
    final graphemes = _graphemes(normalized);
    if (graphemes.length <= maxGraphemes) {
      return normalized;
    }
    return '${graphemes.take(maxGraphemes - 1).join()}…';
  }
}

String requireValidAgentSessionTitle(String value) {
  if (value.isEmpty || _normalizeTitleSource(value) != value) {
    throwAgent(
      AgentErrorKind.configuration,
      'Session title must be normalized and non-blank.',
    );
  }
  for (final rune in value.runes) {
    if (_isControl(rune)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session title must not contain control characters.',
      );
    }
  }
  return value;
}

String _normalizeTitleSource(String source) {
  final output = StringBuffer();
  var pendingSpace = false;
  var hasText = false;
  for (final rune in source.runes) {
    if (_isUnicodeWhitespace(rune)) {
      pendingSpace = hasText;
      continue;
    }
    if (_isControl(rune)) {
      continue;
    }
    if (pendingSpace) {
      output.write(' ');
      pendingSpace = false;
    }
    output.writeCharCode(rune);
    hasText = true;
  }
  return output.toString();
}

List<String> _graphemes(String value) {
  final runes = value.runes.toList(growable: false);
  final result = <String>[];
  var index = 0;
  while (index < runes.length) {
    final cluster = <int>[runes[index++]];
    var regionalCount = _isRegionalIndicator(cluster.first) ? 1 : 0;
    while (index < runes.length) {
      final rune = runes[index];
      if (_isExtend(rune) ||
          rune == 0x20E3 ||
          (_isRegionalIndicator(rune) && regionalCount == 1)) {
        cluster.add(rune);
        if (_isRegionalIndicator(rune)) {
          regionalCount += 1;
        }
        index += 1;
        continue;
      }
      if (rune == 0x200D && index + 1 < runes.length) {
        cluster
          ..add(rune)
          ..add(runes[index + 1]);
        index += 2;
        continue;
      }
      break;
    }
    result.add(String.fromCharCodes(cluster));
  }
  return result;
}

bool _isControl(int rune) =>
    rune <= 0x1F ||
    (rune >= 0x7F && rune <= 0x9F) ||
    rune == 0x061C ||
    rune == 0x00AD ||
    (rune >= 0x200B && rune <= 0x200F && rune != 0x200D) ||
    (rune >= 0x2028 && rune <= 0x202E) ||
    (rune >= 0x2060 && rune <= 0x206F) ||
    rune == 0xFEFF;

bool _isUnicodeWhitespace(int rune) =>
    rune == 0x20 ||
    (rune >= 0x09 && rune <= 0x0D) ||
    rune == 0x85 ||
    rune == 0xA0 ||
    rune == 0x1680 ||
    (rune >= 0x2000 && rune <= 0x200A) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    rune == 0x202F ||
    rune == 0x205F ||
    rune == 0x3000;

bool _isExtend(int rune) =>
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0xFE20 && rune <= 0xFE2F) ||
    (rune >= 0x1F3FB && rune <= 0x1F3FF) ||
    (rune >= 0xE0100 && rune <= 0xE01EF) ||
    (rune >= 0xE0020 && rune <= 0xE007F);

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;
