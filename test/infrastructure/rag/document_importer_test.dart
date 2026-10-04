import 'dart:typed_data';

import 'package:domovoy/infrastructure/rag/document_importer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('arXiv inputs and redirect hosts/identifiers are allowlisted', () async {
    var sends = 0;
    var location = 'https://example.org/pdf/2310.08560';
    final importer = NativeRagDocumentImporter(
      MockClient((request) async {
        sends++;
        expect(request.followRedirects, isFalse);
        return http.Response('', 302, headers: {'location': location});
      }),
    );
    await expectLater(
      importer.importArxiv('https://example.org/pdf/2310.08560'),
      throwsFormatException,
    );
    expect(sends, 0);
    await expectLater(
      importer.importArxiv('2310.08560'),
      throwsFormatException,
    );
    location = 'https://arxiv.org/pdf/2305.10250';
    await expectLater(
      importer.importArxiv('2310.08560'),
      throwsFormatException,
    );
  });
  test('invalid PDF rejected before native extraction', () async {
    final importer = NativeRagDocumentImporter(
      MockClient((_) async => http.Response('', 404)),
    );
    await expectLater(
      importer.extractPdf(Uint8List.fromList([1, 2, 3]), 'bad.pdf', 'Bad'),
      throwsFormatException,
    );
  });
}
