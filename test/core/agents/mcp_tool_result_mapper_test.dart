import 'dart:convert';

import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Uses only the shipped default configuration, so this test compiles and
  // runs against the pre-fix mapper: before the fix the resource fields and
  // the per-block omission markers were unbounded and this fails on size.
  test('default mapper still bounds a hostile response', () {
    const defaults = McpToolResultMapper();
    final huge = 'u' * 1000000;
    final result = defaults.map(
      McpToolCallResult(
        isError: false,
        content: <McpContentBlock>[
          McpResourceLinkBlock(uri: huge, name: huge, mimeType: huge),
          for (var index = 0; index < 5000; index += 1)
            McpTextBlock('block $index'),
          McpUnsupportedBlock(label: huge, text: huge),
        ],
      ),
      toolName: 'mcp_alpha__big',
    );
    final encoded = jsonEncode(result.output);
    expect(encoded.length, lessThanOrEqualTo(120000 + 4 * 4096 + 8192));
    final blocks =
        ((result.output! as Map<String, Object?>)['content']! as List<Object?>)
            .cast<Map<String, Object?>>();
    expect(blocks.length, lessThanOrEqualTo(65));
    expect(blocks.last['type'], 'omitted');
    expect(blocks.last['blocks'], greaterThan(4000));
  });
}
