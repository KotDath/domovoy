// Constructor-only probe. No network requests or credentials.
import 'dart:convert';

import 'package:domovoy/infrastructure/rag/model_service_client.dart';
import 'package:http/http.dart' as http;

void main() {
  final client = http.Client();
  bool accepts(bool? explicit) {
    try {
      if (explicit == null) {
        RagModelServiceClient(client, Uri.parse('http://127.0.0.1:8765'));
      } else {
        RagModelServiceClient(
          client,
          Uri.parse('http://127.0.0.1:8765'),
          allowLoopbackHttp: explicit,
        );
      }
      return true;
    } on ArgumentError {
      return false;
    }
  }

  print(
    jsonEncode({
      'product': const bool.fromEnvironment('dart.vm.product'),
      'profile': const bool.fromEnvironment('dart.vm.profile'),
      'default': accepts(null),
      'explicit_allow': accepts(true),
      'explicit_deny': accepts(false),
    }),
  );
  client.close();
}
