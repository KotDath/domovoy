import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'app.dart';
import 'core/llm/credentials.dart';
import 'core/llm/identifiers.dart';
import 'demos/demo_dependencies.dart';

/// Local browser smoke entry. The marker is public; tool/live_proxy.py owns
/// the real DEEPSEEK_API_KEY and only relays the fixed DeepSeek routes.
Object? webSemanticsHandle;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  webSemanticsHandle = WidgetsBinding.instance.ensureSemantics();
  runApp(
    DomovoyApp(
      dependencies: DomovoyDependencies.production(
        httpClient: DeepSeekRelayClient(http.Client()),
        credentialStore: MemoryProviderCredentialStore(<ProviderId, String>{
          ProviderId('deepseek'): browserRelayCredentialMarker,
        }),
      ),
    ),
  );
}
