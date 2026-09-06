import 'package:flutter/foundation.dart';

@immutable
final class StructuralChecklistEvidence {
  const StructuralChecklistEvidence({
    required this.hasDartCode,
    required this.hasSparseDenseMapping,
    required this.hasSwapRemove,
    required this.hasConstantTime,
    required this.hasComponentStorage,
    required this.hasQuery,
  });

  final bool hasDartCode;
  final bool hasSparseDenseMapping;
  final bool hasSwapRemove;
  final bool hasConstantTime;
  final bool hasComponentStorage;
  final bool hasQuery;

  int get matchedCount => [
    hasDartCode,
    hasSparseDenseMapping,
    hasSwapRemove,
    hasConstantTime,
    hasComponentStorage,
    hasQuery,
  ].where((matched) => matched).length;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StructuralChecklistEvidence &&
          other.hasDartCode == hasDartCode &&
          other.hasSparseDenseMapping == hasSparseDenseMapping &&
          other.hasSwapRemove == hasSwapRemove &&
          other.hasConstantTime == hasConstantTime &&
          other.hasComponentStorage == hasComponentStorage &&
          other.hasQuery == hasQuery;

  @override
  int get hashCode => Object.hash(
    hasDartCode,
    hasSparseDenseMapping,
    hasSwapRemove,
    hasConstantTime,
    hasComponentStorage,
    hasQuery,
  );
}

StructuralChecklistEvidence evaluateStructuralChecklist(String answer) {
  final text = answer.toLowerCase();
  return StructuralChecklistEvidence(
    hasDartCode: _hasDartCode(answer),
    hasSparseDenseMapping: _containsAny(text, const [
      'sparse',
      'dense',
      'sparse/dense',
      'sparse-dense',
    ]),
    hasSwapRemove: _containsAny(text, const [
      'swap-remove',
      'swap remove',
      'swapremove',
      'swap_remove',
    ]),
    hasConstantTime: _containsAny(text, const [
      'o(1)',
      'o (1)',
      'constant time',
    ]),
    hasComponentStorage: _containsAny(text, const [
      'component storage',
      'componentstore',
      'component_store',
      'хранение компонент',
      'хранилищ компонент',
    ]),
    hasQuery: _containsAny(text, const [
      'query',
      'запрос по компонент',
      'запросы по компонент',
    ]),
  );
}

bool _hasDartCode(String answer) {
  final fence = RegExp(r'```\s*dart\b', caseSensitive: false);
  if (fence.hasMatch(answer)) {
    return true;
  }
  final genericFence = RegExp(r'```');
  if (genericFence.hasMatch(answer) && answer.toLowerCase().contains('dart')) {
    return true;
  }
  return false;
}

bool _containsAny(String haystack, List<String> needles) {
  for (final needle in needles) {
    if (haystack.contains(needle)) {
      return true;
    }
  }
  return false;
}
