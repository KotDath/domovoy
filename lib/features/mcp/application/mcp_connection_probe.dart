import '../../../core/llm/cancellation.dart';
import '../../../core/mcp/mcp.dart';

/// Outcome of one explicit "Check" of a candidate or stored connection.
final class McpProbeResult {
  const McpProbeResult.success({required this.handshake, required this.tools})
    : ok = true,
      errorKind = null,
      error = null;

  const McpProbeResult.failure({required this.errorKind, required this.error})
    : ok = false,
      handshake = null,
      tools = const <McpToolDescriptor>[];

  final bool ok;
  final McpHandshake? handshake;

  /// Complete `tools/list` result across all pages.
  final List<McpToolDescriptor> tools;
  final McpErrorKind? errorKind;

  /// Sanitized, credential-free explanation for the failure state.
  final String? error;
}

/// Sanitizes an untrusted failure message before it reaches the UI.
///
/// Any exact occurrence of a submitted secret (bearer token or secure env
/// value) forces the generic [fallback] instead of a partial redaction, so no
/// fragment of a credential can reach probe results, UI state, transcripts or
/// diagnostics. [secretValues] may be a live set that a
/// [McpRecordingSecretResolver] fills while the probe runs.
String sanitizeMcpFailureForUi(
  String? raw, {
  required Iterable<String> secretValues,
  required String fallback,
}) {
  final trimmed = raw?.trim() ?? '';
  if (trimmed.isEmpty) {
    return fallback;
  }
  for (final secret in secretValues) {
    final value = secret.trim();
    if (value.isNotEmpty && trimmed.contains(value)) {
      // Never risk showing a partially redacted credential.
      return fallback;
    }
  }
  return sanitizeMcpText(trimmed, fallback: fallback);
}

/// Adds every non-empty value it resolves to [redactions].
///
/// The probe reads draft overrides and stored vault values through this
/// wrapper, so a server that echoes a secret in an error is redacted even when
/// the value came from secure storage rather than the form.
final class McpRecordingSecretResolver implements McpSecretResolver {
  McpRecordingSecretResolver({required this.inner, Set<String>? redactions})
    : redactions = redactions ?? <String>{};

  final McpSecretResolver inner;
  final Set<String> redactions;

  @override
  Future<String?> read(McpSecretReference reference) async {
    final value = await inner.read(reference);
    if (value != null && value.isNotEmpty) {
      redactions.add(value);
    }
    return value;
  }
}

/// Resolver layered over the stored vault for a check of unsaved form values.
///
/// Draft values win over stored ones; [removed] makes a reference explicitly
/// resolve to `null` so a check never silently uses a token the user is in the
/// middle of replacing. Values never leave this resolver.
final class McpDraftSecretResolver implements McpSecretResolver {
  McpDraftSecretResolver({
    required this.base,
    Map<McpSecretReference, String> overrides =
        const <McpSecretReference, String>{},
    Set<McpSecretReference> removed = const <McpSecretReference>{},
  }) : _overrides = Map<McpSecretReference, String>.unmodifiable(overrides),
       _removed = Set<McpSecretReference>.unmodifiable(removed);

  final McpSecretResolver base;
  final Map<McpSecretReference, String> _overrides;
  final Set<McpSecretReference> _removed;

  @override
  Future<String?> read(McpSecretReference reference) async {
    if (_removed.contains(reference)) {
      return null;
    }
    final draft = _overrides[reference];
    if (draft != null && draft.isNotEmpty) {
      return draft;
    }
    return base.read(reference);
  }
}

/// Performs one handshake plus full `tools/list` without touching the host.
///
/// The same path is used for unsaved editor values and for stored
/// connections, so a successful check always proves both the transport and the
/// complete catalog. The connection is closed before the result is returned.
final class McpConnectionProbe {
  const McpConnectionProbe({
    required this.transports,
    this.timeouts = const McpTimeouts(),
    this.maxPages = 64,
  });

  final McpTransportFactory transports;
  final McpTimeouts timeouts;
  final int maxPages;

  Future<McpProbeResult> run(
    McpConnectionConfig config, {
    required McpSecretResolver secrets,
    Iterable<String> redactions = const <String>[],
    CancellationToken? cancellation,
  }) async {
    final token = cancellation ?? CancellationSource().token;
    McpTransportConnection? connection;
    try {
      connection = await transports.create(config, secrets: secrets);
      final handshake = await connection.connect(
        timeout: timeouts.connect,
        cancellation: token,
      );
      final tools = <McpToolDescriptor>[];
      final seenCursors = <String>{};
      String? cursor;
      for (var page = 0; page < maxPages; page += 1) {
        final result = await connection.listTools(
          cursor: cursor,
          timeout: timeouts.catalog,
          cancellation: token,
        );
        tools.addAll(result.tools);
        final next = result.nextCursor;
        if (next == null) {
          return McpProbeResult.success(
            handshake: handshake,
            tools: List<McpToolDescriptor>.unmodifiable(_dedupe(tools)),
          );
        }
        if (!seenCursors.add(next)) {
          throwMcp(
            McpErrorKind.protocol,
            'MCP tools/list repeated a pagination cursor.',
          );
        }
        cursor = next;
      }
      throwMcp(
        McpErrorKind.protocol,
        'MCP tools/list exceeded the page limit.',
      );
    } on McpException catch (error) {
      return McpProbeResult.failure(
        errorKind: error.error.kind,
        error: sanitizeMcpFailureForUi(
          error.error.message,
          secretValues: redactions,
          fallback: sanitizedMcpUnavailableMessage(),
        ),
      );
    } on Object catch (error) {
      return McpProbeResult.failure(
        errorKind: McpErrorKind.transport,
        error: sanitizeMcpFailureForUi(
          error.toString(),
          secretValues: redactions,
          fallback: sanitizedMcpUnavailableMessage(),
        ),
      );
    } finally {
      try {
        await connection?.close();
      } on Object {
        // Closing a probe session is best effort.
      }
    }
  }

  List<McpToolDescriptor> _dedupe(List<McpToolDescriptor> tools) {
    final seen = <String>{};
    final result = <McpToolDescriptor>[];
    for (final tool in tools) {
      if (seen.add(tool.originalName)) {
        result.add(tool);
      }
    }
    return result;
  }
}
