import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/contracts.dart';
import 'package:domovoy/core/rag/models.dart';

final class FakeRagModels implements RagModelProvider {
  @override
  Future<RagModelInfo> health(CancellationToken token) async =>
      const RagModelInfo('fake-v1', 2, 'TEST');
  @override
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken token, {
    bool reranker = false,
  }) async {
    checkRagCancellation(token.isCancelled);
    var position = 0;
    return [
      for (final rune in text.runes)
        RagToken(position, (position += rune > 0xffff ? 2 : 1)),
    ];
  }

  @override
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken token, {
    bool query = false,
  }) async => [
    for (final _ in texts) [1, 0],
  ];
}

final class FakeRagImporter implements RagDocumentImporter {
  @override
  Future<RagDocument> importArxiv(String input) async =>
      RagDocument(source: 'arxiv:$input', title: input, text: 'TEST paper');
  @override
  Future<List<RagDocument>> selectFiles() async => [];
}
