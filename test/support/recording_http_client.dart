import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

final class RecordedRequest {
  const RecordedRequest({
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  String? header(String name) {
    final normalized = name.toLowerCase();
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == normalized) {
        return entry.value;
      }
    }
    return null;
  }

  Map<String, dynamic> get jsonBody => jsonDecode(body) as Map<String, dynamic>;
}

final class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);

  final FutureOr<http.StreamedResponse> Function(RecordedRequest request)
  handler;
  final List<RecordedRequest> requests = <RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = utf8.decode(await request.finalize().toBytes());
    final recorded = RecordedRequest(
      method: request.method,
      url: request.url,
      headers: Map<String, String>.from(request.headers),
      body: body,
    );
    requests.add(recorded);
    return handler(recorded);
  }
}

http.StreamedResponse sseResponse(String body, {int status = 200}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode(body)),
    status,
  );
}

http.StreamedResponse fragmentedSseResponse(String body, {int status = 200}) {
  final bytes = utf8.encode(body);
  return http.StreamedResponse(
    Stream<List<int>>.fromIterable(bytes.map((byte) => <int>[byte])),
    status,
  );
}
