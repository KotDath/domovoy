import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../app.dart';
import '../core/environment/platform_environment_reader.dart';
import '../core/llm/credentials.dart';
import '../core/llm/identifiers.dart';
import '../infrastructure/credentials/credentials.dart';

/// This marker is public; the loopback relay supplies the real key server-side.
const browserRelayCredentialMarker = 'domovoy-local-relay-marker';

final class DeepSeekRelayClient extends http.BaseClient {
  DeepSeekRelayClient(this._inner);

  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.url.host != 'api.deepseek.com') {
      return _inner.send(request);
    }
    final path = request.url.path;
    if ((request.method != 'GET' || path != '/models') &&
        (request.method != 'POST' || path != '/chat/completions')) {
      throw http.ClientException('Unsupported local relay route');
    }
    final relay = Uri.base.resolve('/__deepseek$path');
    final copied = http.Request(request.method, relay)
      ..headers.addAll(request.headers);
    copied.bodyBytes = await request.finalize().toBytes();
    return _inner.send(copied);
  }

  @override
  void close() => _inner.close();
}

final class DemoDependencies {
  DemoDependencies({required this.stack, required this.client});

  factory DemoDependencies.diagnostic({bool browserRelay = false}) {
    const storage = FlutterSecureStorage();
    const environment = PlatformEnvironmentReader();
    final credentialStore = browserRelay
        ? MemoryProviderCredentialStore(<ProviderId, String>{
            ProviderId('deepseek'): browserRelayCredentialMarker,
          })
        : NamespacedProviderCredentialStore(FlutterSecureStringStore(storage));
    final client = browserRelay
        ? DeepSeekRelayClient(http.Client())
        : http.Client();
    final stack = buildProductionAgentStack(
      httpClient: client,
      credentials: DefaultProviderCredentialResolver(
        store: credentialStore,
        readEnvironment: environment.read,
      ),
      diagnosticNoCompaction: true,
    );
    return DemoDependencies(stack: stack, client: client);
  }

  final ProductionAgentStack stack;
  final http.Client client;

  Future<void> close() async {
    await stack.runtime.close();
    await stack.providerModelCatalog?.close();
    client.close();
  }
}
