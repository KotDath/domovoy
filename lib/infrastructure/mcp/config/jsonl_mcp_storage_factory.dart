import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_mcp_storage_factory_unsupported.dart'
    if (dart.library.io) 'jsonl_mcp_storage_factory_io.dart'
    if (dart.library.js_interop) 'jsonl_mcp_storage_factory_web.dart'
    as platform;

/// MCP configuration streams use an independent namespace. Web returns null.
JsonlStreamStorage? createPlatformMcpJsonlStreamStorage() {
  return platform.createPlatformMcpJsonlStreamStorage();
}
