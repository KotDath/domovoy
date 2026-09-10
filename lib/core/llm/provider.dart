import 'cancellation.dart';
import 'errors.dart';
import 'events.dart';
import 'identifiers.dart';
import 'json.dart';
import 'request.dart';

abstract interface class LlmProvider {
  ProviderId get id;

  LlmWireFamily get wireFamily;

  Stream<LlmEvent> stream(
    LlmRequest request, {
    required CancellationToken cancellation,
  });
}

final class LlmProviderProfile {
  LlmProviderProfile({
    required this.id,
    required this.wireFamily,
    required Uri endpoint,
    required String environmentVariable,
    required String dialectId,
  }) : endpoint = requireSecretFreeEndpoint(endpoint),
       environmentVariable = environmentVariable.trim(),
       dialectId = dialectId.trim() {
    if (this.environmentVariable.isEmpty) {
      throwLlm(
        LlmErrorKind.configuration,
        'Credential environment variable must not be blank.',
      );
    }
    if (this.dialectId.isEmpty) {
      throwLlm(LlmErrorKind.configuration, 'Dialect id must not be blank.');
    }
  }

  factory LlmProviderProfile.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return LlmProviderProfile(
      id: ProviderId.fromJson(map['id']),
      wireFamily: LlmWireFamily.fromJson(map['wireFamily']),
      endpoint: Uri.parse(requireNonBlankString(map, 'endpoint')),
      environmentVariable: requireString(map, 'environmentVariable'),
      dialectId: requireString(map, 'dialectId'),
    );
  }

  static const jsonType = 'llm.provider_profile';

  final ProviderId id;
  final LlmWireFamily wireFamily;
  final Uri endpoint;
  final String environmentVariable;
  final String dialectId;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'id': id.toJson(),
      'wireFamily': wireFamily.toJson(),
      'endpoint': secretFreeEndpointString(endpoint),
      'environmentVariable': environmentVariable,
      'dialectId': dialectId,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LlmProviderProfile &&
          other.id == id &&
          other.wireFamily == wireFamily &&
          other.endpoint == endpoint &&
          other.environmentVariable == environmentVariable &&
          other.dialectId == dialectId;

  @override
  int get hashCode =>
      Object.hash(id, wireFamily, endpoint, environmentVariable, dialectId);
}

Uri requireSecretFreeEndpoint(Uri endpoint) {
  if (endpoint.userInfo.isNotEmpty) {
    throwLlm(
      LlmErrorKind.configuration,
      'Endpoint must not contain embedded credentials.',
    );
  }
  return endpoint;
}

String secretFreeEndpointString(Uri endpoint) {
  if (endpoint.userInfo.isEmpty) {
    return endpoint.toString();
  }
  return endpoint.replace(userInfo: '').toString();
}
