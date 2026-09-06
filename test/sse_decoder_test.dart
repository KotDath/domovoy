import 'dart:convert';

import 'package:domovoy/features/prompt/data/sse_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const decoder = SseDecoder();

  test('reassembles UTF-8 and line fragments', () async {
    final bytes = utf8.encode('data: {"text":"привет"}\n\ndata: [DONE]\n\n');
    final stream = Stream<List<int>>.fromIterable(
      bytes.map((byte) => <int>[byte]),
    );

    expect(await decoder.decode(stream).toList(), <String>[
      '{"text":"привет"}',
      '[DONE]',
    ]);
  });

  test(
    'supports CRLF, comments, ignored fields, and multiple data lines',
    () async {
      final source =
          ': keep-alive\r\n'
          'event: message\r\n'
          'data: first\r\n'
          'data: second\r\n'
          '\r\n';

      expect(
        await decoder.decode(Stream.value(utf8.encode(source))).toList(),
        <String>['first\nsecond'],
      );
    },
  );

  test('dispatches a final buffered event at EOF', () async {
    expect(
      await decoder
          .decode(Stream.value(utf8.encode('data: final payload')))
          .toList(),
      <String>['final payload'],
    );
  });
}
