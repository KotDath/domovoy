import 'dart:convert';
import 'package:flutter/services.dart';
import '../../core/rag/models.dart';
import '../../core/support/manual.dart';
export '../../core/support/manual.dart';

abstract final class BundledSupportManual {
  static Future<SupportManual> load({
    Future<String> Function(String)? read,
  }) async {
    final reader = read ?? rootBundle.loadString;
    final manifest =
        jsonDecode(await reader('assets/support/manifest.json'))
            as Map<String, dynamic>;
    if (manifest['version'] != 1) {
      throw const FormatException('Unsupported manual');
    }
    final revision = manifest['revision'] as String;
    final documents = <RagDocument>[];
    final seen = <String>{};
    for (final raw in manifest['documents'] as List) {
      final entry = raw as Map<String, dynamic>;
      final asset = entry['asset'] as String;
      if (!RegExp(r'^assets/support/[a-z-]+\.md$').hasMatch(asset) ||
          !seen.add(asset)) {
        throw const FormatException('Invalid manual entry');
      }
      final text = await reader(asset);
      if (ragHash(text) != entry['sha256'] ||
          (entry['provenance'] as List).isEmpty) {
        throw const FormatException('Manual integrity failed');
      }
      documents.add(
        RagDocument(
          source: entry['source'] as String,
          title: text.split('\n').first.replaceFirst('# ', ''),
          text: text,
          sourceRevision: revision,
        ),
      );
    }
    if (documents.isEmpty) throw const FormatException('Empty manual');
    // Includes content hashes, so changing bytes without bumping the human
    // revision still invalidates an old index rather than silently reusing it.
    return SupportManual(
      '$revision:${ragHash(documents.map((d) => '${d.source}:${d.revision}').join('|'))}',
      List.unmodifiable(documents),
      packageVersion: manifest['packageVersion'] as String,
    );
  }
}
