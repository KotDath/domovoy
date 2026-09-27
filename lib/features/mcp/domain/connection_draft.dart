import '../../../core/mcp/mcp.dart';

/// Transport families the connection editor can create.
enum McpConnectionTransportChoice { stdio, streamableHttp }

/// Mutable, write-only form state of one connection editor session.
///
/// Secret inputs ([bearerToken], [secretEnvironment] values) live only here
/// and in the secure vault: they are never part of a persisted configuration
/// and the controller clears them after a successful save. A stored secret is
/// represented by a boolean/name, so the editor can say that a value exists
/// without ever reading it back into the UI.
final class McpConnectionDraft {
  const McpConnectionDraft({
    this.editingConnectionId,
    this.connectionId = '',
    this.alias = '',
    this.enabled = true,
    this.baseRevision,
    this.transport = McpConnectionTransportChoice.streamableHttp,
    this.url = '',
    this.bearerToken = '',
    this.bearerTokenStored = false,
    this.removeBearerToken = false,
    this.command = '',
    this.args = const <String>[],
    this.workingDirectory = '',
    this.environment = const <String, String>{},
    this.secretEnvironment = const <String, String>{},
    this.secretEnvironmentStored = const <String>{},
    this.removedSecretEnvironment = const <String>{},
  });

  factory McpConnectionDraft.create({
    McpConnectionTransportChoice transport =
        McpConnectionTransportChoice.streamableHttp,
  }) => McpConnectionDraft(transport: transport);

  factory McpConnectionDraft.fromConfig(McpConnectionConfig config) {
    return switch (config.transport) {
      McpStdioTransportConfig stdio => McpConnectionDraft(
        editingConnectionId: config.connectionId.value,
        connectionId: config.connectionId.value,
        alias: config.alias,
        enabled: config.enabled,
        baseRevision: config.revision,
        transport: McpConnectionTransportChoice.stdio,
        command: stdio.command,
        args: stdio.args,
        workingDirectory: stdio.workingDirectory ?? '',
        environment: stdio.environment,
        secretEnvironmentStored: stdio.secretEnvironment.keys.toSet(),
      ),
      McpHttpTransportConfig http => McpConnectionDraft(
        editingConnectionId: config.connectionId.value,
        connectionId: config.connectionId.value,
        alias: config.alias,
        enabled: config.enabled,
        baseRevision: config.revision,
        transport: McpConnectionTransportChoice.streamableHttp,
        url: http.url,
        bearerTokenStored: http.bearerSecret != null,
      ),
      McpInProcessStreamTransportConfig() => throwMcp(
        McpErrorKind.unsupported,
        'Built-in in-process MCP connections cannot be edited as external '
        'servers.',
      ),
    };
  }

  /// Non-null when an existing stored connection is being edited.
  final String? editingConnectionId;

  /// User-entered connection ID while creating; ignored when editing.
  final String connectionId;
  final String alias;
  final bool enabled;

  /// Revision the editor was opened at; a save is rejected when the stored
  /// configuration moved past it.
  final int? baseRevision;

  final McpConnectionTransportChoice transport;

  /// Remote endpoint and its write-only bearer token input.
  final String url;
  final String bearerToken;
  final bool bearerTokenStored;
  final bool removeBearerToken;

  /// stdio command, argument array, working directory and environment.
  final String command;
  final List<String> args;
  final String workingDirectory;

  /// Explicit non-secret environment values persisted in JSONL.
  final Map<String, String> environment;

  /// New secure environment values, never persisted outside the vault.
  final Map<String, String> secretEnvironment;

  /// Names whose values already live in the vault.
  final Set<String> secretEnvironmentStored;

  /// Stored secure names the user explicitly removed.
  final Set<String> removedSecretEnvironment;

  bool get isEditing => editingConnectionId != null;

  /// Connection ID this draft will be saved under.
  String get effectiveConnectionId =>
      (editingConnectionId ?? connectionId).trim();

  /// Existing secure names that survive this edit.
  Set<String> get retainedSecretEnvironment => secretEnvironmentStored
      .where((name) => !removedSecretEnvironment.contains(name))
      .toSet();

  McpConnectionDraft copyWith({
    String? connectionId,
    String? alias,
    bool? enabled,
    McpConnectionTransportChoice? transport,
    String? url,
    String? bearerToken,
    bool? bearerTokenStored,
    bool? removeBearerToken,
    String? command,
    List<String>? args,
    String? workingDirectory,
    Map<String, String>? environment,
    Map<String, String>? secretEnvironment,
    Set<String>? secretEnvironmentStored,
    Set<String>? removedSecretEnvironment,
  }) {
    return McpConnectionDraft(
      editingConnectionId: editingConnectionId,
      connectionId: connectionId ?? this.connectionId,
      alias: alias ?? this.alias,
      enabled: enabled ?? this.enabled,
      baseRevision: baseRevision,
      transport: transport ?? this.transport,
      url: url ?? this.url,
      bearerToken: bearerToken ?? this.bearerToken,
      bearerTokenStored: bearerTokenStored ?? this.bearerTokenStored,
      removeBearerToken: removeBearerToken ?? this.removeBearerToken,
      command: command ?? this.command,
      args: args ?? this.args,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      environment: environment ?? this.environment,
      secretEnvironment: secretEnvironment ?? this.secretEnvironment,
      secretEnvironmentStored:
          secretEnvironmentStored ?? this.secretEnvironmentStored,
      removedSecretEnvironment:
          removedSecretEnvironment ?? this.removedSecretEnvironment,
    );
  }

  @override
  String toString() =>
      'McpConnectionDraft(${editingConnectionId ?? connectionId}, '
      '${transport.name}, alias: "$alias")';
}
