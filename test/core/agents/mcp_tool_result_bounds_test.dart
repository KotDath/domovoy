import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mapper = McpToolResultMapper(
    maxBlockCharacters: 128,
    maxResultCharacters: 4000,
    maxStructuredCharacters: 256,
    maxErrorSummaryCharacters: 64,
    maxFieldCharacters: 64,
    maxBlockEntries: 8,
  );

  // Budget plus the bounded overshoot of the last entry and its keys.
  const encodedBound = 4000 + 4 * 64 + 4096;

  test('bounds resource fields, entries and omission markers', () {
    final huge = 'u' * 100000;
    final content = <McpContentBlock>[
      McpResourceLinkBlock(uri: huge, name: huge, mimeType: 'm/$huge'),
      McpEmbeddedResourceBlock(
        uri: huge,
        embeddedText: huge,
        data: huge,
        mimeType: huge,
      ),
      McpUnsupportedBlock(label: huge, text: huge),
      for (var index = 0; index < 5000; index += 1)
        McpTextBlock('block $index ${'x' * 200}'),
    ];
    final result = mapper.map(
      McpToolCallResult(
        isError: false,
        content: content,
        structuredContent: <String, Object?>{'blob': 'y' * 100000},
      ),
      toolName: 'mcp_alpha__big',
    );
    expect(result.success, isTrue);
    final encoded = jsonEncode(result.output);
    // A hostile response cannot grow the transcript past the budget.
    expect(encoded.length, lessThanOrEqualTo(encodedBound));

    final payload = result.output! as Map<String, Object?>;
    expect(payload['contentTruncated'], isTrue);
    final structured = payload['structuredContent']! as Map<String, Object?>;
    expect(structured['omitted'], isTrue);
    expect(structured['characters'], greaterThan(256));

    final blocks = (payload['content']! as List<Object?>)
        .cast<Map<String, Object?>>();
    // At most maxBlockEntries real entries plus one aggregate marker.
    expect(blocks.length, lessThanOrEqualTo(9));

    final link = blocks.first;
    expect(link['type'], 'resource_link');
    expect(link['uriTruncated'], isTrue);
    expect(link['uriCharacters'], 100000);
    expect((link['uri']! as String).length, lessThanOrEqualTo(64));
    expect(link['nameTruncated'], isTrue);
    expect(link['mimeTypeTruncated'], isTrue);

    final embedded = blocks[1];
    expect(embedded['uriTruncated'], isTrue);
    expect(embedded['mimeTypeTruncated'], isTrue);
    expect(embedded['dataOmitted'], isTrue);

    final unsupported = blocks[2];
    expect(unsupported['type'], 'unsupported');
    expect(unsupported['labelTruncated'], isTrue);

    final marker = blocks.last;
    expect(marker['type'], 'omitted');
    expect(marker['blocks'], isA<int>());
    final omittedCount = marker['blocks']! as int;
    // One counted marker, never one marker per dropped block.
    expect(omittedCount, content.length - (blocks.length - 1));
    expect(omittedCount, greaterThan(4000));
    expect(encoded.contains('u' * 130), isFalse);
  });

  test('bounds an error result and its summary', () {
    final result = mapper.map(
      McpToolCallResult(
        isError: true,
        content: <McpContentBlock>[
          McpTextBlock('e' * 100000),
          for (var index = 0; index < 5000; index += 1)
            McpTextBlock('block $index ${'z' * 200}'),
        ],
        structuredContent: <String, Object?>{'blob': 'y' * 100000},
      ),
      toolName: 'mcp_alpha__big',
    );
    expect(result.success, isFalse);
    expect(result.errorMessage, contains('reported an error'));
    expect(result.errorMessage!.length, lessThanOrEqualTo(64 + 64));
    final encoded = jsonEncode(result.errorDetails);
    expect(encoded.length, lessThanOrEqualTo(encodedBound));
    expect(encoded.contains('e' * 130), isFalse);
    expect(encoded.contains('z' * 130), isFalse);
  });
}
