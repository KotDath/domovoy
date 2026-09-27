/// Built-in `library` MCP server: the one local owner of saved digests.
///
/// B9 composes [LibraryMcpServerFactory] with the local MCP host, passing the
/// platform JSONL storage from [createPlatformLibraryJsonlStreamStorage].
/// `save_digest` persists validated Digest v1 payloads with Paper v1
/// snapshots, `list_saved` and `get_saved` are the read API of the library UI.
/// There is no second library store in the application, and no filesystem path
/// is ever accepted from a tool caller.
library;

export 'library_envelope.dart';
export 'library_failure.dart';
export 'library_jsonl_store.dart';
export 'library_limits.dart';
export 'library_mcp_server.dart';
export 'library_replay.dart';
export 'library_storage_factory.dart';
export 'library_storage_namespace.dart';
