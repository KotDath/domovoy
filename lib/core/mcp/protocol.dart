import '../llm/json.dart';
import 'errors.dart';
import 'ids.dart';

/// Result of a successful MCP initialize/server-discover handshake.
final class McpHandshake {
  const McpHandshake({
    required this.serverName,
    required this.serverVersion,
    required this.protocolVersion,
    this.instructions,
    this.capabilities = const <String, Object?>{},
  });

  final String serverName;
  final String serverVersion;
  final String protocolVersion;
  final String? instructions;
  final Map<String, Object?> capabilities;

  Map<String, Object?> toJson() => <String, Object?>{
    'serverName': serverName,
    'serverVersion': serverVersion,
    'protocolVersion': protocolVersion,
    if (instructions != null) 'instructions': instructions,
    if (capabilities.isNotEmpty) 'capabilities': capabilities,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpHandshake &&
          other.serverName == serverName &&
          other.serverVersion == serverVersion &&
          other.protocolVersion == protocolVersion &&
          other.instructions == instructions &&
          jsonEquals(other.capabilities, capabilities);

  @override
  int get hashCode => Object.hash(
    serverName,
    serverVersion,
    protocolVersion,
    instructions,
    jsonHash(capabilities),
  );

  @override
  String toString() =>
      'McpHandshake($serverName $serverVersion, protocol $protocolVersion)';
}

/// One tool announced by a server, before model-facing naming.
final class McpToolDescriptor {
  McpToolDescriptor({
    required this.connectionId,
    required String originalName,
    String? title,
    String? description,
    required Map<String, Object?> inputSchema,
    Map<String, Object?>? outputSchema,
    Map<String, Object?>? annotations,
    Map<String, Object?>? raw,
  }) : originalName = _requireToolName(originalName),
       title = _trimToNull(title),
       description = _trimToNull(description),
       inputSchema = freezeJsonMap(copyJsonMap(inputSchema)),
       outputSchema = outputSchema == null
           ? null
           : freezeJsonMap(copyJsonMap(outputSchema)),
       annotations = annotations == null
           ? null
           : freezeJsonMap(copyJsonMap(annotations)),
       raw = raw == null ? null : freezeJsonMap(copyJsonMap(raw));

  final McpConnectionId connectionId;

  /// Tool name exactly as announced by the server.
  final String originalName;
  final String? title;
  final String? description;

  /// Full raw JSON Schema, preserved without dropping any constraints.
  final Map<String, Object?> inputSchema;
  final Map<String, Object?>? outputSchema;
  final Map<String, Object?>? annotations;

  /// Full wire object for re-serialization to LLM providers.
  final Map<String, Object?>? raw;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpToolDescriptor &&
          other.connectionId == connectionId &&
          other.originalName == originalName &&
          other.title == title &&
          other.description == description &&
          jsonEquals(other.inputSchema, inputSchema) &&
          jsonEquals(other.outputSchema, outputSchema) &&
          jsonEquals(other.annotations, annotations);

  @override
  int get hashCode => Object.hash(
    connectionId,
    originalName,
    title,
    description,
    jsonHash(inputSchema),
    jsonHash(outputSchema),
    jsonHash(annotations),
  );

  @override
  String toString() => 'McpToolDescriptor(${connectionId.value}/$originalName)';
}

/// One page of `tools/list`, including the cursor for the next page.
final class McpToolPage {
  const McpToolPage({required this.tools, this.nextCursor});

  final List<McpToolDescriptor> tools;
  final String? nextCursor;
}

/// Content block kinds the host understands explicitly.
enum McpContentKind {
  text,
  image,
  audio,
  resourceLink,
  embeddedResource,
  unknown,
}

/// Decoded MCP content block.
///
/// Unknown block kinds are preserved as [McpUnsupportedBlock] so nothing is
/// dropped silently: the agent and UI receive an explicit explanation.
sealed class McpContentBlock {
  const McpContentBlock();

  McpContentKind get kind;

  /// Text usable by the model, empty for media-only blocks.
  String get text => '';
}

final class McpTextBlock extends McpContentBlock {
  const McpTextBlock(this.text);

  @override
  McpContentKind get kind => McpContentKind.text;

  @override
  final String text;
}

final class McpMediaBlock extends McpContentBlock {
  const McpMediaBlock({
    required this.kind,
    required this.data,
    required this.mimeType,
  });

  @override
  final McpContentKind kind;
  final String data;
  final String mimeType;
}

final class McpResourceLinkBlock extends McpContentBlock {
  const McpResourceLinkBlock({required this.uri, this.name, this.mimeType});

  @override
  McpContentKind get kind => McpContentKind.resourceLink;

  final String uri;
  final String? name;
  final String? mimeType;

  @override
  String get text => uri;
}

final class McpEmbeddedResourceBlock extends McpContentBlock {
  const McpEmbeddedResourceBlock({
    required this.uri,
    this.embeddedText,
    this.data,
    this.mimeType,
  });

  @override
  McpContentKind get kind => McpContentKind.embeddedResource;

  final String uri;
  final String? embeddedText;
  final String? data;
  final String? mimeType;

  @override
  String get text => embeddedText ?? '';
}

final class McpUnsupportedBlock extends McpContentBlock {
  const McpUnsupportedBlock({required this.label, this.text = ''});

  @override
  McpContentKind get kind => McpContentKind.unknown;

  /// Wire type name that could not be decoded.
  final String label;

  @override
  final String text;
}

/// Decoded `tools/call` result.
final class McpToolCallResult {
  const McpToolCallResult({
    required this.isError,
    required this.content,
    this.structuredContent,
  });

  final bool isError;
  final List<McpContentBlock> content;
  final Object? structuredContent;

  bool get isEmpty => content.isEmpty && structuredContent == null;

  /// Concatenated text blocks, joined by newlines.
  String get textContent {
    final parts = <String>[];
    for (final block in content) {
      if (block.text.isNotEmpty) {
        parts.add(block.text);
      }
    }
    return parts.join('\n');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is McpToolCallResult &&
          other.isError == isError &&
          other.structuredContent == structuredContent &&
          _blocksEqual(other.content, content);

  @override
  int get hashCode =>
      Object.hash(isError, structuredContent, Object.hashAll(content));

  @override
  String toString() =>
      'McpToolCallResult(isError: $isError, blocks: ${content.length})';
}

String _requireToolName(String name) {
  final candidate = name.trim();
  if (candidate.isEmpty || candidate.length > 256) {
    throwMcp(McpErrorKind.protocol, 'Server returned an invalid tool name.');
  }
  return candidate;
}

String? _trimToNull(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

bool _blocksEqual(List<McpContentBlock> left, List<McpContentBlock> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    final a = left[i];
    final b = right[i];
    if (a.runtimeType != b.runtimeType || a.text != b.text) {
      return false;
    }
    switch (a) {
      case McpMediaBlock():
        final other = b as McpMediaBlock;
        if (a.data != other.data ||
            a.mimeType != other.mimeType ||
            a.kind != other.kind) {
          return false;
        }
      case McpResourceLinkBlock():
        final other = b as McpResourceLinkBlock;
        if (a.uri != other.uri ||
            a.name != other.name ||
            a.mimeType != other.mimeType) {
          return false;
        }
      case McpEmbeddedResourceBlock():
        final other = b as McpEmbeddedResourceBlock;
        if (a.uri != other.uri ||
            a.embeddedText != other.embeddedText ||
            a.data != other.data ||
            a.mimeType != other.mimeType) {
          return false;
        }
      case McpUnsupportedBlock():
        final other = b as McpUnsupportedBlock;
        if (a.label != other.label) {
          return false;
        }
      case McpTextBlock():
        break;
    }
  }
  return true;
}
