/// Built-in `arxiv` MCP server: search and read descriptive arXiv metadata.
///
/// B9 composes [ArxivMcpServerFactory] with the local MCP host; B4/B5 consume
/// the same `core/research` Paper v1 objects through the tool results.
library;

export 'arxiv_atom.dart';
export 'arxiv_client.dart';
export 'arxiv_errors.dart';
export 'arxiv_http.dart';
export 'arxiv_mcp_server.dart';
