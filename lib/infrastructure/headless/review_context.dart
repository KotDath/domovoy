import 'dart:convert';

import '../../core/rag/models.dart';
import 'project_sources_io.dart';

/// Versioned, host-collected data. Its serialized size is checked as a whole;
/// oversized diffs fail rather than dropping paths/hunks.
final class ReviewContext {
  ReviewContext._(this.data);
  final Map<String, dynamic> data;
  String get base => data['base_sha'] as String;
  String get head => data['head_sha'] as String;
  String get repository => data['repository'] as String;
  List<String> get paths => (data['changed_files'] as List).cast<String>();
  List<String> get ragPaths => (data['rag_paths'] as List).cast<String>();
  String get scope => '$repository:$base:$head:${ProjectSourcePolicy.version}';
  String get trustedRules => jsonEncode(data['trusted_rules']);
  String get input =>
      'PR METADATA (untrusted):\n${jsonEncode({
        for (final entry in data.entries)
          if (!{'trusted_rules', 'source_hashes', 'diff'}.contains(entry.key)) entry.key: entry.value,
      })}\n'
      'UNIFIED DIFF (untrusted; old merge-base -> head):\n${data['diff']}';

  static ReviewContext parse(String source, {int maxBytes = 400000}) {
    if (utf8.encode(source).length > maxBytes) {
      throw const FormatException(
        'Review context exceeds input budget; partition the PR or raise the explicit budget. No review was produced.',
      );
    }
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      throw const FormatException('Invalid review context version.');
    }
    for (final key in ['base_sha', 'head_sha']) {
      if (json[key] is! String ||
          !RegExp(r'^[0-9a-f]{40}$').hasMatch(json[key] as String)) {
        throw const FormatException('Invalid review revision.');
      }
    }
    if (json['repository'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$',
        ).hasMatch(json['repository'] as String) ||
        json['diff'] is! String ||
        (json['diff'] as String).isEmpty ||
        json['trusted_rules'] is! Map ||
        json['source_hashes'] is! Map) {
      throw const FormatException('Malformed review metadata.');
    }
    for (final key in ['changed_files', 'rag_paths']) {
      final list = json[key];
      if (list is! List ||
          list.isEmpty ||
          list.any((p) => p is! String || !ProjectSourcePolicy.permits(p)) ||
          list.toSet().length != list.length) {
        throw const FormatException(
          'Invalid or unsupported review path coverage.',
        );
      }
    }
    final hashes = json['source_hashes'] as Map;
    if (hashes.entries.any(
          (e) =>
              e.key is! String ||
              !ProjectSourcePolicy.permits(e.key as String) ||
              e.value is! String ||
              !RegExp(r'^[0-9a-f]{64}$').hasMatch(e.value as String),
        ) ||
        (json['rag_paths'] as List).any((p) => !hashes.containsKey(p))) {
      throw const FormatException('Invalid source receipt.');
    }
    return ReviewContext._(json);
  }

  void verifySources(ProjectSourceSnapshot snapshot) {
    final actual = {
      for (final d in snapshot.documents) d.source: ragHash(d.text),
    };
    final expected = data['source_hashes'] as Map;
    if (actual.length != expected.length ||
        expected.entries.any((e) => actual[e.key] != e.value)) {
      throw StateError(
        'Review snapshot does not match collected head sources.',
      );
    }
  }
}
