import '../llm/cancellation.dart';
import 'models.dart';

final class RagModelInfo {
  const RagModelInfo(this.fingerprint, this.dimension, this.label);
  final String fingerprint;
  final int dimension;
  final String label;
}

final class RagToken {
  const RagToken(this.start, this.end);
  final int start;
  final int end;
}

abstract interface class RagModelProvider {
  Future<RagModelInfo> health(CancellationToken cancellation);
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken cancellation, {
    bool reranker = false,
  });
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken cancellation, {
    bool query = false,
  });
}

abstract interface class RagRepository {
  Future<List<RagDocument>> documents(String project, String corpus);
  Future<void> saveDocuments(
    String project,
    String corpus,
    List<RagDocument> docs,
  );
  Future<RagIndex?> loadIndex(
    String project,
    String corpus,
    ChunkStrategy strategy,
  );
  Future<RagIndex?> loadGeneration(
    String project,
    String corpus,
    String generation,
  );
  Future<List<int>?> originalPdf(
    String project,
    String corpus,
    RagDocument document,
  );
  Future<void> publishIndex(String project, String corpus, RagIndex index);
}

abstract interface class RagDocumentImporter {
  Future<List<RagDocument>> selectFiles();
  Future<RagDocument> importArxiv(String input);
}
