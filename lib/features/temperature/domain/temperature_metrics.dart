import 'package:characters/characters.dart';

final RegExp _wordRunPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);

int unicodeCharacterCount(String text) => text.characters.length;

List<String> normalizedWords(String text) {
  return [
    for (final match in _wordRunPattern.allMatches(text.toLowerCase()))
      ?match.group(0),
  ];
}

double? uniqueWordRatio(String text) {
  final words = normalizedWords(text);
  if (words.isEmpty) {
    return null;
  }
  return words.toSet().length / words.length;
}

double? pairwiseJaccardSimilarity(String left, String right) {
  if (left.trim().isEmpty || right.trim().isEmpty) {
    return null;
  }
  final leftWords = normalizedWords(left).toSet();
  final rightWords = normalizedWords(right).toSet();
  if (leftWords.isEmpty || rightWords.isEmpty) {
    return null;
  }
  final union = leftWords.union(rightWords).length;
  if (union == 0) {
    return null;
  }
  return leftWords.intersection(rightWords).length / union;
}

String? formatLexicalRatio(double? value) {
  if (value == null) {
    return null;
  }
  return value.toStringAsFixed(2);
}
