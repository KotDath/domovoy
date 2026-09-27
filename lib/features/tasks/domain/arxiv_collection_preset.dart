import '../../../core/mcp/mcp.dart';

/// One `(server, tool)` requirement of the arXiv collection preset.
typedef PresetTool = ({String connectionId, String toolName});

/// Human-readable name of the built-in arXiv collection preset.
const arxivPresetName = 'Подборка arXiv';

/// One-line explanation shown in the editor next to the preset button.
const arxivPresetDescription =
    'Готовый сценарий дня 19: arxiv.search_papers → digest.summarize_papers → '
    'library.save_digest. Сводка строится только по аннотациям arXiv.';

/// Concrete starting topic; the entire prompt remains editable in the form.
const arxivPresetDefaultTopic = 'агенты на основе больших языковых моделей';

/// Prompt of the built-in arXiv collection preset.
const arxivPresetPrompt =
    'Тема: $arxivPresetDefaultTopic. Выполни цепочку из трёх MCP-вызовов. '
    'Сначала arxiv.search_papers с limit=1 и sortBy=submittedDate. '
    'Передай один полный объект Paper v1 из structuredContent в '
    'digest.summarize_papers. Затем передай этот Paper v1 и полный Digest v1 '
    'из structuredContent в library.save_digest. Не пересказывай и не '
    'обрезай поля объектов при передаче. В ответе укажи ID статьи, тему '
    'и libraryId сохранённой записи.';

/// Tools the preset pins, in pipeline order.
///
/// The preset is guidance for the editor, not an automatic grant: every ID is
/// resolved against the live catalog and a missing server is shown to the user
/// before saving.
const arxivPresetTools = <PresetTool>[
  (connectionId: 'arxiv', toolName: 'search_papers'),
  (connectionId: 'digest', toolName: 'summarize_papers'),
  (connectionId: 'library', toolName: 'save_digest'),
];

/// Model-facing tool IDs of the preset that exist in [catalog].
List<String> resolveArxivPresetToolIds(McpCatalog catalog) =>
    List<String>.unmodifiable(<String>[
      for (final preset in arxivPresetTools)
        if (_routeFor(catalog, preset) case final route?)
          route.modelToolName.value,
    ]);

/// Tool IDs the preset needs but [catalog] cannot currently provide.
List<PresetTool> missingArxivPresetTools(McpCatalog catalog) =>
    List<PresetTool>.unmodifiable(<PresetTool>[
      for (final preset in arxivPresetTools)
        if (_routeFor(catalog, preset) == null) preset,
    ]);

McpToolRoute? _routeFor(McpCatalog catalog, PresetTool preset) {
  for (final route in catalog.routes) {
    if (route.connectionId.value == preset.connectionId &&
        route.originalToolName == preset.toolName) {
      return route;
    }
  }
  return null;
}
