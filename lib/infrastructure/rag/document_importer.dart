import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:http/http.dart' as http;
import 'package:pdfrx/pdfrx.dart';

import '../../core/rag/contracts.dart';
import '../../core/rag/models.dart';
import '../../core/research/arxiv_id.dart';
import '../mcp/servers/arxiv/arxiv_client.dart';
import '../mcp/servers/arxiv/arxiv_http.dart';

final class NativeRagDocumentImporter implements RagDocumentImporter {
  NativeRagDocumentImporter(this.client)
    : metadata = ArxivClient(
        http: HttpArxivHttpAdapter(client: client),
        requestTimeout: const Duration(seconds: 10),
      );
  final ArxivClient metadata;
  final http.Client client;
  static const maxBytes = 32 * 1024 * 1024;

  @override
  Future<List<RagDocument>> selectFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Документы',
          extensions: ['md', 'txt', 'pdf'],
          mimeTypes: ['text/plain', 'text/markdown', 'application/pdf'],
        ),
      ],
    );
    final docs = <RagDocument>[];
    for (final file in files) {
      if (await file.length() > maxBytes) throw StateError('Файл больше 32 МБ');
      final bytes = await file.readAsBytes();
      if (bytes.length > maxBytes) throw StateError('Файл больше 32 МБ');
      final source = 'file:${file.path}';
      docs.add(
        source.toLowerCase().endsWith('.pdf')
            ? await extractPdf(bytes, source, file.name)
            : RagDocument(
                source: source,
                title: file.name,
                text: _decodeText(bytes, file.name),
              ),
      );
    }
    return docs;
  }

  String _decodeText(List<int> bytes, String name) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw FormatException(
        'Файл $name должен быть в UTF-8. Пакетный импорт отменён без изменения корпуса.',
      );
    }
  }

  @override
  Future<RagDocument> importArxiv(String input) async {
    var raw = input.trim();
    if (raw.contains('://')) {
      final uri = Uri.parse(raw);
      if (uri.scheme != 'https' ||
          !{'arxiv.org', 'www.arxiv.org'}.contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !(uri.path.startsWith('/abs/') || uri.path.startsWith('/pdf/'))) {
        throw const FormatException(
          'Введите arXiv ID или HTTPS-ссылку arxiv.org',
        );
      }
      raw = uri.path.substring(5).replaceFirst(RegExp(r'\.pdf$'), '');
    }
    final id = ArxivId(raw);
    final version = versionFromArxivInput(raw);
    final reference = id.withVersion(version);
    var uri = Uri.parse('https://arxiv.org/pdf/$reference');
    http.StreamedResponse? downloaded;
    for (var attempt = 0; attempt < 4; attempt++) {
      final request = http.Request('GET', uri)..followRedirects = false;
      request.headers['User-Agent'] = 'Domovoy-RAG/1.0 (local PDF import)';
      final result = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      if ({301, 302, 303, 307, 308}.contains(result.statusCode)) {
        final next = uri.resolve(result.headers['location'] ?? '');
        if (next.scheme != 'https' ||
            !{'arxiv.org', 'www.arxiv.org'}.contains(next.host) ||
            next.userInfo.isNotEmpty ||
            next.hasQuery ||
            next.hasFragment ||
            !next.path.startsWith('/pdf/')) {
          throw const FormatException('Unsafe arXiv redirect');
        }
        final redirectedId = ArxivId(
          next.path.substring(5).replaceFirst(RegExp(r'\.pdf$'), ''),
        );
        if (redirectedId != id) {
          throw const FormatException(
            'arXiv redirected to a different document',
          );
        }
        await result.stream.drain<void>();
        uri = next;
        continue;
      }
      downloaded = result;
      break;
    }
    if (downloaded == null) {
      throw StateError('Слишком много перенаправлений arXiv');
    }
    final response = downloaded;
    if (response.statusCode != 200) {
      throw StateError('arXiv: HTTP ${response.statusCode}');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final block in response.stream.timeout(
      const Duration(seconds: 45),
    )) {
      bytes.add(block);
      if (bytes.length > maxBytes) throw StateError('PDF больше 32 МБ');
    }
    final disposition = response.headers['content-disposition'] ?? '';
    final filename = RegExp(
      r'filename="([^";]+)"',
    ).firstMatch(disposition)?.group(1);
    var resolved = reference;
    if (filename != null && filename.endsWith('.pdf')) {
      final candidate = filename.substring(0, filename.length - 4);
      if (ArxivId(candidate) == id) resolved = candidate;
    }
    var title = 'arXiv $resolved (название недоступно)';
    try {
      final paper = await metadata.getPaper(resolved);
      title = paper.title;
    } on Object {
      // A metadata outage must not turn a successfully downloaded PDF into
      // invented bibliographic metadata. Keep an explicit unknown title.
    }
    final doc = await extractPdf(
      bytes.takeBytes(),
      'https://arxiv.org/pdf/$resolved',
      title,
    );
    return RagDocument(
      source: doc.source,
      title: doc.title,
      text: doc.text,
      pageStarts: doc.pageStarts,
      pdfBase64: doc.pdfBase64,
      pdfSize: doc.pdfSize,
      sourceRevision: resolved,
    );
  }

  Future<RagDocument> extractPdf(
    Uint8List bytes,
    String source,
    String title,
  ) async {
    if (bytes.length > maxBytes ||
        !ascii
            .decode(bytes.take(5).toList(), allowInvalid: true)
            .startsWith('%PDF-')) {
      throw const FormatException('Неверный PDF');
    }
    await pdfrxFlutterInitialize();
    final pdf = await PdfDocument.openData(bytes);
    try {
      if (pdf.pages.length > 300) throw StateError('PDF больше 300 страниц');
      final buffer = StringBuffer();
      final starts = <int>[];
      for (final page in pdf.pages) {
        starts.add(buffer.length);
        final text = await page.loadText();
        buffer.write(RagDocument.normalize(text?.fullText ?? ''));
        buffer.write('\n\n');
      }
      if (buffer.toString().trim().isEmpty) {
        throw StateError('В PDF нет текстового слоя. OCR не поддерживается.');
      }
      return RagDocument(
        source: source,
        title: title,
        text: buffer.toString(),
        pageStarts: starts,
        pdfBase64: base64Encode(bytes),
        pdfSize: bytes.length,
      );
    } finally {
      await pdf.dispose();
    }
  }
}
