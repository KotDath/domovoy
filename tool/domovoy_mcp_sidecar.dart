import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Desktop-only MCP HTTP sidecar. One instance exposes one built-in server on
/// loopback while the app keeps the handlers and their shared state. Standard
/// output contains exactly one ready message; no credentials are logged.
Future<void> main() async {
  final input = StreamIterator<String>(
    stdin.transform(utf8.decoder).transform(const LineSplitter()),
  );
  if (!await input.moveNext()) {
    return;
  }
  final config = _SidecarConfig.parse(input.current);
  final listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final client = HttpClient()..autoUncompress = false;
  final subscription = listener.listen(
    (request) => _forward(request, config, client),
  );
  stdout.writeln(
    jsonEncode(<String, String>{
      'serverId': config.serverId,
      'url': 'http://127.0.0.1:${listener.port}/mcp',
    }),
  );
  await stdout.flush();
  // The parent holds stdin open for the sidecar lifetime. EOF means the app
  // closed or crashed; either way the listener must not outlive its owner.
  await input.moveNext();
  await subscription.cancel();
  await listener.close(force: true);
  client.close(force: true);
  await input.cancel();
}

final class _SidecarConfig {
  const _SidecarConfig(this.serverId, this.backendUrl, this.bearerToken);

  final String serverId;
  final Uri backendUrl;
  final String bearerToken;

  static _SidecarConfig parse(String line) {
    final data = jsonDecode(line);
    if (data is! Map) {
      throw const FormatException('Invalid MCP sidecar configuration.');
    }
    final serverId = data['serverId'];
    final backendUrl = Uri.tryParse(data['backendUrl'] as String? ?? '');
    final bearerToken = data['bearerToken'];
    if (serverId is! String ||
        serverId.isEmpty ||
        backendUrl == null ||
        backendUrl.scheme != 'http' ||
        backendUrl.host != '127.0.0.1' ||
        backendUrl.path != '/mcp' ||
        backendUrl.port <= 0 ||
        bearerToken is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(bearerToken)) {
      throw const FormatException('Invalid MCP sidecar configuration.');
    }
    return _SidecarConfig(serverId, backendUrl, bearerToken);
  }
}

Future<void> _forward(
  HttpRequest request,
  _SidecarConfig config,
  HttpClient client,
) async {
  if (request.uri.path != '/mcp' || request.uri.hasQuery) {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
    return;
  }
  final host = request.headers.host;
  if (host != '127.0.0.1' && host != 'localhost') {
    request.response.statusCode = HttpStatus.badRequest;
    await request.response.close();
    return;
  }
  final expected = 'Bearer ${config.bearerToken}';
  final supplied = request.headers.value(HttpHeaders.authorizationHeader);
  if (supplied == null || !_constantTimeEquals(supplied, expected)) {
    request.response.statusCode = HttpStatus.unauthorized;
    await request.response.close();
    return;
  }
  try {
    final upstream = await client.openUrl(request.method, config.backendUrl);
    upstream.followRedirects = false;
    request.headers.forEach((name, values) {
      if (!_isHopByHop(name) &&
          name != HttpHeaders.hostHeader &&
          name != HttpHeaders.authorizationHeader &&
          name != HttpHeaders.contentLengthHeader) {
        upstream.headers.set(name, values);
      }
    });
    upstream.headers.set(HttpHeaders.authorizationHeader, expected);
    await upstream.addStream(request);
    final upstreamResponse = await upstream.close();
    final response = request.response;
    response.statusCode = upstreamResponse.statusCode;
    response.bufferOutput = false;
    upstreamResponse.headers.forEach((name, values) {
      if (!_isHopByHop(name) && name != HttpHeaders.contentLengthHeader) {
        response.headers.set(name, values);
      }
    });
    await response.addStream(upstreamResponse);
    await response.close();
  } on Object {
    try {
      request.response.statusCode = HttpStatus.badGateway;
      await request.response.close();
    } on Object {
      // The MCP client may already have disconnected.
    }
  }
}

bool _isHopByHop(String header) => switch (header.toLowerCase()) {
  'connection' ||
  'keep-alive' ||
  'proxy-authenticate' ||
  'proxy-authorization' ||
  'te' ||
  'trailer' ||
  'transfer-encoding' ||
  'upgrade' => true,
  _ => false,
};

bool _constantTimeEquals(String left, String right) {
  if (left.length != right.length) {
    return false;
  }
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}
