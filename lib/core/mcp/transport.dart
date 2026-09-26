import 'errors.dart';
import 'ids.dart';

/// Transport families the host knows how to build.
enum McpTransportKind {
  /// Local child process speaking newline-delimited JSON-RPC on stdio.
  stdio,

  /// MCP Streamable HTTP endpoint (HTTPS, or loopback HTTP for own servers).
  streamableHttp,

  /// In-process `IOStreamTransport` pair, used for built-in servers on every
  /// platform including web/Aurora where spawning processes is not available.
  inProcessStream,
}

/// Reference to a secret value in platform secure storage.
///
/// Only the storage key is ever serialized to JSONL; the value itself stays in
/// `flutter_secure_storage` and is resolved at connect time.
final class McpSecretReference {
  const McpSecretReference(this.storeKey);

  factory McpSecretReference.fromJson(Object? json) {
    if (json is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'Secret reference must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    json.forEach((key, value) {
      if (key is! String) {
        throwMcp(
          McpErrorKind.configuration,
          'Secret reference keys must be strings.',
        );
      }
      map[key] = value;
    });
    if (map['kind'] != 'secure_storage' || map['key'] is! String) {
      throwMcp(
        McpErrorKind.configuration,
        'Unsupported secret reference shape.',
      );
    }
    return McpSecretReference(map['key']! as String);
  }

  /// Storage key under which the value can be read.
  final String storeKey;

  /// Convenience reference for a connection bearer token.
  static McpSecretReference bearer(McpConnectionId connectionId) =>
      McpSecretReference('mcp.${connectionId.value}.bearer');

  /// Convenience reference for one stdio environment variable.
  static McpSecretReference stdioEnvironment(
    McpConnectionId connectionId,
    String variable,
  ) => McpSecretReference('mcp.${connectionId.value}.env.$variable');

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'secure_storage',
    'key': storeKey,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpSecretReference && other.storeKey == storeKey;

  @override
  int get hashCode => storeKey.hashCode;

  @override
  String toString() => 'McpSecretReference($storeKey)';
}

/// Transport-specific connection parameters.
sealed class McpTransportConfig {
  const McpTransportConfig();

  factory McpTransportConfig.fromJson(Object? json) {
    if (json is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'Transport configuration must be a JSON object.',
      );
    }
    final map = <String, Object?>{};
    json.forEach((key, value) {
      if (key is! String) {
        throwMcp(
          McpErrorKind.configuration,
          'Transport configuration keys must be strings.',
        );
      }
      map[key] = value;
    });
    final kind = map['kind'];
    return switch (kind) {
      'stdio' => McpStdioTransportConfig.fromJson(map),
      'streamable_http' => McpHttpTransportConfig.fromJson(map),
      'in_process_stream' => McpInProcessStreamTransportConfig.fromJson(map),
      _ => throwMcp(
        McpErrorKind.unsupported,
        'Unknown MCP transport kind "$kind".',
      ),
    };
  }

  McpTransportKind get kind;

  Map<String, Object?> toJson();
}

/// Runs a trusted local MCP server as a child process.
final class McpStdioTransportConfig extends McpTransportConfig {
  McpStdioTransportConfig({
    required String command,
    List<String> args = const <String>[],
    String? workingDirectory,
    Map<String, String> environment = const <String, String>{},
    Map<String, McpSecretReference> secretEnvironment =
        const <String, McpSecretReference>{},
  }) : command = _requireCommand(command),
       args = List<String>.unmodifiable(
         args.map((arg) => _requireArgument(arg)),
       ),
       workingDirectory = workingDirectory == null
           ? null
           : _requirePath(workingDirectory),
       environment = Map<String, String>.unmodifiable({
         for (final entry in environment.entries)
           _requireEnvironmentName(entry.key): _requireEnvironmentValue(
             entry.key,
             entry.value,
           ),
       }),
       secretEnvironment = Map<String, McpSecretReference>.unmodifiable({
         for (final entry in secretEnvironment.entries)
           _requireEnvironmentName(entry.key): entry.value,
       }) {
    for (final name in this.environment.keys) {
      if (this.secretEnvironment.containsKey(name)) {
        throwMcp(
          McpErrorKind.configuration,
          'Environment variable "$name" is both explicit and a secret.',
        );
      }
    }
  }

  factory McpStdioTransportConfig.fromJson(Map<String, Object?> map) {
    final command = map['command'];
    if (command is! String) {
      throwMcp(McpErrorKind.configuration, 'stdio command must be text.');
    }
    final args = map['args'];
    if (args != null && args is! List) {
      throwMcp(McpErrorKind.configuration, 'stdio args must be a list.');
    }
    final environment = map['environment'];
    if (environment != null && environment is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'stdio environment must be an object.',
      );
    }
    final secretEnvironment = map['secretEnvironment'];
    if (secretEnvironment != null && secretEnvironment is! Map) {
      throwMcp(
        McpErrorKind.configuration,
        'stdio secretEnvironment must be an object.',
      );
    }
    return McpStdioTransportConfig(
      command: command,
      args: _decodeStringList(args, 'args'),
      workingDirectory: map['workingDirectory'] == null
          ? null
          : map['workingDirectory']! as String,
      environment: _decodeStringMap(environment, 'environment'),
      secretEnvironment: _decodeSecretMap(secretEnvironment),
    );
  }

  @override
  McpTransportKind get kind => McpTransportKind.stdio;

  final String command;
  final List<String> args;
  final String? workingDirectory;

  /// Explicit non-secret environment values persisted in JSONL.
  final Map<String, String> environment;

  /// Environment variables whose values live in secure storage.
  final Map<String, McpSecretReference> secretEnvironment;

  Iterable<McpSecretReference> get secretReferences => secretEnvironment.values;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'stdio',
    'command': command,
    if (args.isNotEmpty) 'args': args,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
    if (environment.isNotEmpty) 'environment': environment,
    if (secretEnvironment.isNotEmpty)
      'secretEnvironment': {
        for (final entry in secretEnvironment.entries)
          entry.key: entry.value.toJson(),
      },
  };
}

/// Remote Streamable HTTP endpoint, or a loopback endpoint of a built-in
/// server. Plain HTTP is accepted only for loopback hosts.
final class McpHttpTransportConfig extends McpTransportConfig {
  McpHttpTransportConfig({required String url, this.bearerSecret})
    : uri = _requireHttpUrl(url);

  factory McpHttpTransportConfig.fromJson(Map<String, Object?> map) {
    final url = map['url'];
    if (url is! String) {
      throwMcp(McpErrorKind.configuration, 'HTTP url must be text.');
    }
    return McpHttpTransportConfig(
      url: url,
      bearerSecret: map['bearerSecret'] == null
          ? null
          : McpSecretReference.fromJson(map['bearerSecret']),
    );
  }

  @override
  McpTransportKind get kind => McpTransportKind.streamableHttp;

  final Uri uri;
  final McpSecretReference? bearerSecret;

  String get url => uri.toString();

  bool get isLoopback => isLoopbackHost(uri.host);

  Iterable<McpSecretReference> get secretReferences => <McpSecretReference>[
    ?bearerSecret,
  ];

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'streamable_http',
    'url': url,
    'bearerSecret': ?bearerSecret?.toJson(),
  };
}

/// In-process stream endpoint of a locally running MCP server.
final class McpInProcessStreamTransportConfig extends McpTransportConfig {
  McpInProcessStreamTransportConfig({required String serverId})
    : serverId = _requireServerId(serverId);

  factory McpInProcessStreamTransportConfig.fromJson(Map<String, Object?> map) {
    final serverId = map['serverId'];
    if (serverId is! String) {
      throwMcp(McpErrorKind.configuration, 'in-process serverId must be text.');
    }
    return McpInProcessStreamTransportConfig(serverId: serverId);
  }

  @override
  McpTransportKind get kind => McpTransportKind.inProcessStream;

  final String serverId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'in_process_stream',
    'serverId': serverId,
  };
}

/// True for hosts that never leave the device.
bool isLoopbackHost(String host) {
  final normalized = host.toLowerCase();
  return normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '::1' ||
      normalized == '[::1]';
}

Uri _requireHttpUrl(String raw) {
  final candidate = raw.trim();
  final uri = Uri.tryParse(candidate);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throwMcp(McpErrorKind.configuration, 'MCP URL is not a valid URL.');
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') {
    throwMcp(
      McpErrorKind.configuration,
      'MCP URL must use https:// or loopback http://.',
    );
  }
  if (scheme == 'http' && !isLoopbackHost(uri.host)) {
    throwMcp(
      McpErrorKind.configuration,
      'Plain http:// is only allowed for loopback MCP endpoints.',
    );
  }
  if (uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    throwMcp(
      McpErrorKind.configuration,
      'MCP URL must not contain credentials or fragments.',
    );
  }
  return uri;
}

String _requireCommand(String command) {
  final candidate = command.trim();
  if (candidate.isEmpty || _hasControl(candidate)) {
    throwMcp(McpErrorKind.configuration, 'stdio command is not valid.');
  }
  return candidate;
}

String _requireArgument(String arg) {
  if (_hasControl(arg)) {
    throwMcp(McpErrorKind.configuration, 'stdio argument is not valid.');
  }
  return arg;
}

String _requirePath(String path) {
  final candidate = path.trim();
  if (candidate.isEmpty || _hasControl(candidate)) {
    throwMcp(McpErrorKind.configuration, 'Working directory is not valid.');
  }
  return candidate;
}

String _requireEnvironmentName(String name) {
  final candidate = name.trim();
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(candidate)) {
    throwMcp(
      McpErrorKind.configuration,
      'Environment variable name is not valid.',
    );
  }
  return candidate;
}

String _requireEnvironmentValue(String name, String value) {
  if (_hasControl(value)) {
    throwMcp(
      McpErrorKind.configuration,
      'Environment value for "$name" is not valid.',
    );
  }
  return value;
}

String _requireServerId(String serverId) {
  final candidate = serverId.trim();
  if (candidate.isEmpty ||
      candidate.length > 64 ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(candidate)) {
    throwMcp(
      McpErrorKind.configuration,
      'Local server ID contains unsupported characters.',
    );
  }
  return candidate;
}

bool _hasControl(String value) =>
    value.contains('\u0000') || value.contains('\n') || value.contains('\r');

List<String> _decodeStringList(Object? value, String field) {
  if (value == null) {
    return const <String>[];
  }
  if (value is! List) {
    throwMcp(McpErrorKind.configuration, 'stdio $field must be a list.');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String) {
      throwMcp(McpErrorKind.configuration, 'stdio $field must be text.');
    }
    result.add(item);
  }
  return result;
}

Map<String, String> _decodeStringMap(Object? value, String field) {
  if (value == null) {
    return const <String, String>{};
  }
  if (value is! Map) {
    throwMcp(McpErrorKind.configuration, 'stdio $field must be an object.');
  }
  final result = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throwMcp(
        McpErrorKind.configuration,
        'stdio $field must map text to text.',
      );
    }
    result[entry.key as String] = entry.value as String;
  }
  return result;
}

Map<String, McpSecretReference> _decodeSecretMap(Object? value) {
  if (value == null) {
    return const <String, McpSecretReference>{};
  }
  if (value is! Map) {
    throwMcp(
      McpErrorKind.configuration,
      'stdio secretEnvironment must be an object.',
    );
  }
  final result = <String, McpSecretReference>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throwMcp(
        McpErrorKind.configuration,
        'stdio secretEnvironment keys must be text.',
      );
    }
    result[key] = McpSecretReference.fromJson(entry.value);
  }
  return result;
}
