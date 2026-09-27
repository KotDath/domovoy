/// Built-in `digest` MCP server: abstract-scope synthesis over supplied papers.
///
/// B9 composes [DigestMcpServerFactory] with the local MCP host and injects a
/// [DigestModelPinResolver] that supplies the model fixed for each invocation.
/// The server uses the existing Domovoy LLM registry and credentials; it never
/// queries arXiv, saves library data or creates a second provider client.
library;

export 'digest_failure.dart';
export 'digest_limits.dart';
export 'digest_mcp_server.dart';
export 'digest_model_pin.dart';
export 'digest_synthesizer.dart';
