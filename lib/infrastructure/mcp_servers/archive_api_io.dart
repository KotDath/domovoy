import 'dart:convert';

import 'package:http/http.dart' as http;

/// Small, injectable adapter for the Internet Archive public read APIs.
final class ArchiveApi {
  ArchiveApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, Object?>> search(String query, {int limit = 5}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.length > 200 || limit < 1 || limit > 20) {
      throw const FormatException('Provide a query and a limit from 1 to 20.');
    }
    final uri = Uri.https('archive.org', '/advancedsearch.php', {
      'q': trimmed,
      'fl[]': ['identifier', 'title', 'description', 'date', 'mediatype'],
      'rows': '$limit',
      'page': '1',
      'output': 'json',
    });
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Internet Archive search returned ${response.statusCode}.',
      );
    }
    final body = jsonDecode(response.body);
    if (body is! Map || body['response'] is! Map) {
      throw const FormatException('Invalid Internet Archive search response.');
    }
    final payload = body['response'] as Map;
    final docs = payload['docs'];
    if (docs is! List) {
      throw const FormatException('Internet Archive search has no docs list.');
    }
    return <String, Object?>{
      'query': trimmed,
      'total': payload['numFound'] is num ? payload['numFound'] : 0,
      'items': [
        for (final doc in docs)
          if (doc is Map && doc['identifier'] is String)
            <String, Object?>{
              'identifier': doc['identifier'],
              'title': _shortText(doc['title']),
              'description': _shortText(doc['description']),
              'date': _shortText(doc['date']),
              'mediatype': _shortText(doc['mediatype']),
              'url':
                  'https://archive.org/details/${Uri.encodeComponent(doc['identifier'] as String)}',
            },
      ],
    };
  }

  Future<Map<String, Object?>> item(String identifier) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$').hasMatch(identifier)) {
      throw const FormatException('Invalid Internet Archive identifier.');
    }
    final response = await _client
        .get(Uri.https('archive.org', '/metadata/$identifier'))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw StateError(
        'Internet Archive metadata returned ${response.statusCode}.',
      );
    }
    final body = jsonDecode(response.body);
    if (body is! Map || body['metadata'] is! Map) {
      throw const FormatException('Internet Archive item was not found.');
    }
    final metadata = body['metadata'] as Map;
    return <String, Object?>{
      'identifier': identifier,
      'title': _shortText(metadata['title']),
      'description': _shortText(metadata['description'], maxLength: 2000),
      'date': _shortText(metadata['date']),
      'mediatype': _shortText(metadata['mediatype']),
      'creator': _shortText(metadata['creator']),
      'url': 'https://archive.org/details/${Uri.encodeComponent(identifier)}',
    };
  }

  void close() => _client.close();
}

String _shortText(Object? value, {int maxLength = 500}) {
  final text = switch (value) {
    String text => text,
    List values => values.map((value) => value.toString()).join('; '),
    _ => '',
  };
  final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return normalized.length > maxLength
      ? '${normalized.substring(0, maxLength)}…'
      : normalized;
}
