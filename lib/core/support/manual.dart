import '../rag/models.dart';

final class SupportManual {
  const SupportManual(
    this.revision,
    this.documents, {
    this.packageVersion = 'Неизвестна',
  });
  final String revision;
  final String packageVersion;
  final List<RagDocument> documents;
}

typedef SupportManualLoader = Future<SupportManual> Function();
