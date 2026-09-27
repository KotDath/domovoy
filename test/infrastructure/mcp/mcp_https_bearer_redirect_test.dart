import 'dart:io';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/infrastructure/mcp/mcp.dart';
import 'package:flutter_test/flutter_test.dart';

/// Controlled HTTPS bearer test with a cross-origin redirect.
///
/// Two loopback HTTPS servers with self-signed certificates and different
/// ports are different origins. The MCP endpoint answers the initialize POST
/// with `303 See Other` to the second server; the test asserts that the bearer
/// token reaches only the configured origin and is never forwarded to the
/// redirected origin, and that the handshake fails closed instead of
/// silently continuing against the other origin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory certificateDirectory;
  late String certificatePath;
  late String keyPath;
  var opensslAvailable = false;

  setUpAll(() async {
    certificateDirectory = await Directory.systemTemp.createTemp(
      'domovoy-mcp-tls-',
    );
    certificatePath = '${certificateDirectory.path}/cert.pem';
    keyPath = '${certificateDirectory.path}/key.pem';
    final result = Process.runSync('openssl', <String>[
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      keyPath,
      '-out',
      certificatePath,
      '-days',
      '2',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
    ]);
    opensslAvailable = result.exitCode == 0;
  });

  tearDownAll(() async {
    await certificateDirectory.delete(recursive: true);
  });

  test(
    'a cross-origin redirect never receives the bearer token',
    () async {
      if (!opensslAvailable) {
        markTestSkipped('openssl is not available to create test TLS certs');
        return;
      }
      final context = SecurityContext()
        ..useCertificateChain(certificatePath)
        ..usePrivateKey(keyPath);
      final origin = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final redirected = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(origin.close);
      addTearDown(redirected.close);
      expect(origin.port, isNot(redirected.port));

      final originAuthorization = <String?>[];
      final redirectedAuthorization = <String?>[];
      var redirectedHits = 0;

      origin.listen((request) async {
        originAuthorization.add(request.headers.value('authorization'));
        request.response.statusCode = HttpStatus.seeOther;
        request.response.headers.set(
          'location',
          'https://127.0.0.1:${redirected.port}/mcp',
        );
        await request.response.close();
      });
      redirected.listen((request) async {
        redirectedHits += 1;
        redirectedAuthorization.add(request.headers.value('authorization'));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          '{"jsonrpc":"2.0","id":1,"error":{"code":-32600,'
          '"message":"redirected origin has no session"}}',
        );
        await request.response.close();
      });

      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = _TrustLocalCertificates();
      addTearDown(() => HttpOverrides.global = previousOverrides);

      const token = 'controlled-bearer-token-0123456789';
      final secrets = RuntimeMcpSecretResolver();
      final reference = McpSecretReference.bearer(
        McpConnectionId('https-redirect'),
      );
      secrets.put(reference, token);
      final config = McpConnectionConfig(
        connectionId: McpConnectionId('https-redirect'),
        alias: 'https-redirect',
        transport: McpHttpTransportConfig(
          url: 'https://127.0.0.1:${origin.port}/mcp',
          bearerSecret: reference,
        ),
      );
      final factory = McpSdkTransportFactory(
        diagnostics: MemoryMcpDiagnosticsSink(),
      );
      final connection = await factory.create(config, secrets: secrets);
      addTearDown(connection.close);

      // The redirected origin cannot complete the MCP session: the handshake
      // fails closed instead of continuing against the other origin.
      await expectLater(
        connection.connect(
          timeout: const Duration(seconds: 20),
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<McpException>()),
      );

      expect(
        originAuthorization,
        contains('Bearer $token'),
        reason: 'the configured origin receives the token',
      );
      expect(
        redirectedAuthorization.whereType<String>(),
        isEmpty,
        reason: 'the bearer value must never be sent to a redirected origin',
      );
      // Proves the scenario actually exercised the redirect: with the SDK
      // following it, the check above is a real assertion, not a vacuous one.
      expect(redirectedHits, greaterThanOrEqualTo(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

final class _TrustLocalCertificates extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (cert, host, port) => true;
    return client;
  }
}
