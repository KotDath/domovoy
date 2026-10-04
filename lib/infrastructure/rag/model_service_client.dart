import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../core/llm/cancellation.dart';
import '../../core/rag/contracts.dart';
import '../../core/rag/models.dart';

final class RagModelServiceClient implements RagModelProvider {
  RagModelServiceClient(this.client, this.baseUrl) {
    final local = {'127.0.0.1', 'localhost', '10.0.2.2'}.contains(baseUrl.host);
    if (baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        (baseUrl.scheme != 'https' &&
            !(kDebugMode && local && baseUrl.scheme == 'http'))) {
      throw ArgumentError('RAG service requires HTTPS or debug loopback HTTP');
    }
  }
  final http.Client client;
  final Uri baseUrl;
  Map<String, dynamic>? _tokenizerFingerprints;

  Future<Map<String, dynamic>> _request(
    String path,
    CancellationToken token, [
    Map<String, Object?>? body,
  ]) async {
    checkRagCancellation(token.isCancelled);
    final request = http.Request(
      body == null ? 'GET' : 'POST',
      baseUrl.resolve(path),
    )..followRedirects = false;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await Future.any([
      client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(minutes: 3)),
      token.whenCancelled.then<http.Response>(
        (_) => throw const RagCancelled(),
      ),
    ]);
    checkRagCancellation(token.isCancelled);
    if (response.statusCode != 200) {
      throw StateError(
        'Сервис моделей: HTTP ${response.statusCode}. '
        'Проверьте подключение и совместимость индекса.',
      );
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  @override
  Future<RagModelInfo> health(CancellationToken cancellation) async {
    final json = await _request('/health', cancellation);
    if (json['ready'] != true ||
        json['offset_unit'] != 'codepoint' ||
        (json['dimension'] as int) <= 0 ||
        (json['reranker_pair_limit'] != null &&
            json['reranker_pair_limit'] != 8192) ||
        (json['reranker_query_limit'] != null &&
            json['reranker_query_limit'] != 1024)) {
      throw const FormatException('Incompatible model service');
    }
    _tokenizerFingerprints = (json['tokenizer_fingerprints'] as Map?)
        ?.cast<String, dynamic>();
    return RagModelInfo(
      json['fingerprint'] as String,
      json['dimension'] as int,
      (json['embedding'] as Map)['model'] as String,
    );
  }

  @override
  Future<List<RagToken>> tokenize(
    String text,
    CancellationToken cancellation, {
    bool reranker = false,
  }) async {
    final kind = reranker ? 'reranker' : 'embedding';
    final json = await _request('/v1/tokenize', cancellation, {
      'text': text,
      'kind': kind,
    });
    final expected = _tokenizerFingerprints?[kind];
    if (expected != null && json['tokenizer_fingerprint'] != expected) {
      throw const FormatException('Tokenizer changed during indexing');
    }
    if (json['offset_unit'] != 'codepoint') {
      throw const FormatException('Unsupported token offset unit');
    }
    final positions = <int>[0];
    var position = 0;
    for (final rune in text.runes) {
      position += rune > 0xffff ? 2 : 1;
      positions.add(position);
    }
    final result = <RagToken>[];
    for (final pair in json['offsets'] as List) {
      final start = pair[0] as int;
      final end = pair[1] as int;
      if (start < 0 || end < start || end >= positions.length) {
        throw const FormatException('Invalid tokenizer offset');
      }
      if (end > start) result.add(RagToken(positions[start], positions[end]));
    }
    return result;
  }

  @override
  Future<List<List<double>>> embed(
    List<String> texts,
    RagModelInfo model,
    CancellationToken cancellation, {
    bool query = false,
  }) async {
    final json = await _request('/v1/embeddings', cancellation, {
      'expected_model_fingerprint': model.fingerprint,
      'inputs': [
        for (var i = 0; i < texts.length; i++)
          {
            'id': 'input-$i',
            'text': texts[i],
            'kind': query ? 'query' : 'passage',
          },
      ],
    });
    if (json['fingerprint'] != model.fingerprint ||
        json['dimension'] != model.dimension ||
        json['truncated'] != false ||
        json['normalized'] != true) {
      throw const FormatException('Embedding model changed or input truncated');
    }
    final outputs = json['outputs'] as List;
    final byId = <String, List<double>>{};
    for (final output in outputs) {
      final id = output['id'] as String;
      if (byId.containsKey(id)) {
        throw const FormatException('Duplicate embedding');
      }
      byId[id] = normalizedRagVector(
        (output['vector'] as List).cast<num>(),
        model.dimension,
      );
    }
    if (byId.length != texts.length ||
        List.generate(
          texts.length,
          (i) => 'input-$i',
        ).any((id) => !byId.containsKey(id))) {
      throw const FormatException('Missing or unknown embedding ID');
    }
    return [for (var i = 0; i < texts.length; i++) byId['input-$i']!];
  }
}
