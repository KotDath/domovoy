import 'enums.dart';
import 'errors.dart';
import 'validation.dart';

/// A deterministic candidate proposed by an explicit remember phrase. No LLM
/// call is involved.
final class MemoryPhraseProposal {
  const MemoryPhraseProposal({
    required this.layer,
    required this.scope,
    required this.kind,
    required this.content,
  });

  final MemoryLayer layer;
  final MemoryScope scope;
  final MemoryKind kind;
  final String content;
}

final _englishRemember = RegExp(
  r'^[ \t]*remember(?:[ \t]+(project|global(?:ly)?))?(?:[ \t]*[:\-][ \t]*|[ \t]*,?[ \t]+that[ \t]+)(.+)$',
  caseSensitive: false,
  multiLine: true,
);
final _russianRemember = RegExp(
  r'^[ \t]*запомни(?:[ \t]+(проект|глобально))?(?:[ \t]*[:\-][ \t]*|[ \t]*,?[ \t]+что[ \t]+)(.+)$',
  caseSensitive: false,
  multiLine: true,
);

/// Parses explicit project/global remember phrases.
///
/// Invalid or secret-bearing phrase content is dropped rather than surfaced, so
/// a phrase can never persist a credential as memory.
List<MemoryPhraseProposal> parseMemoryRememberPhrases(String text) {
  final proposals = <MemoryPhraseProposal>[];
  for (final match in _englishRemember.allMatches(text)) {
    _collect(proposals, match.group(1), match.group(2));
  }
  for (final match in _russianRemember.allMatches(text)) {
    _collect(proposals, match.group(1), match.group(2));
  }
  return List<MemoryPhraseProposal>.unmodifiable(proposals);
}

void _collect(
  List<MemoryPhraseProposal> proposals,
  String? scopeToken,
  String? rawContent,
) {
  if (rawContent == null) {
    return;
  }
  final normalizedScope = scopeToken?.toLowerCase();
  final isGlobal =
      normalizedScope == 'global' ||
      normalizedScope == 'globally' ||
      normalizedScope == 'глобально';
  final isProject =
      normalizedScope == null ||
      normalizedScope == 'project' ||
      normalizedScope == 'проект';
  if (!isGlobal && !isProject) {
    return;
  }
  final String content;
  try {
    content = normalizeMemoryContent(rawContent);
  } on MemoryException {
    return;
  }
  proposals.add(
    MemoryPhraseProposal(
      layer: isGlobal ? MemoryLayer.longTerm : MemoryLayer.working,
      scope: isGlobal ? MemoryScope.global : MemoryScope.project,
      kind: MemoryKind.fact,
      content: content,
    ),
  );
}
