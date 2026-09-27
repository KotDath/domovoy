# B7: UI подключений MCP и прав — отчёт

Статус: **реализовано и покрыто тестами**. `lib/app.dart` не менялся: сборку
делает B9 через фабрику `McpFeature`.

## Что вошло

| Область | Файлы |
|---|---|
| Домен выбора прав | `lib/core/mcp/tool_selection.dart` (цель чат/проект, запись allowlist, контракт стора, in-memory стор) |
| JSONL-персистентность прав | `lib/infrastructure/mcp/config/jsonl_mcp_tool_selection_store.dart` (append/replay, ревизии, толерантность к обрезанному хвосту) |
| Домен UI | `lib/features/mcp/domain/` (инъектируемые `McpPlatformCapabilities`, черновик подключения) |
| Контроллеры | `lib/features/mcp/application/` (CRUD подключений, probe handshake + `tools/list`, durable права чата/проекта) |
| UI | `lib/features/mcp/presentation/` (страница подключений, редактор с «Проверить», лист прав) |
| Сборка для B9 | `lib/features/mcp/mcp_feature.dart`, баррель `lib/features/mcp/mcp.dart` |
| Чат | `ChatWorkspacePage.mcpToolAccess` + `McpChatToolsButton` в шапке (`WorkspaceShell.headerAction`), pass-through в `ProjectWorkspacePage` |

## Подключение B9

```dart
final mcp = McpFeature.build(
  host: mcpHostManager,
  repository: mcpConnectionRepository,
  secrets: mcpSecretVault,                 // FlutterSecureMcpSecretVault
  selections: JsonlMcpToolSelectionStore(
    storage: createPlatformMcpJsonlStreamStorage()!, // in-memory fallback на web
  ),
  capabilities: McpPlatformCapabilities.aurora, // desktop/mobile/web/aurora
  probeTransports: mcpTransports,
  hostChanges: mcpHostManager,
  builtInConnectionIds: const <String>{'arxiv', 'digest', 'library', 'automation'},
  unavailableReasons: () => mcpBridge.source.unavailableTools,
);
await mcp.initialize();

// экран настроек:
mcp.buildConnectionsPage();
// чат/проект:
ChatWorkspacePage(..., mcpToolAccess: mcp.toolAccess);
// политика прав:
policies['chat-42'] = ToolAccessPolicy(grant: mcp.toolAccess.buildGrant(chatId: id));
```

Платформенный выбор делает композиция: к примеру, для Aurora B9 передаёт
`McpPlatformCapabilities.aurora` (или строит объект через
`supportsStdioOnPlatform(..., disabledByPolicy: true)`), поэтому приложение не
полагается только на `Platform.isLinux`.

## Демо-путь

1. «Добавить» → URL `https://…` + bearer-токен → «Проверить»: видны сервер,
   версия, протокол и полный список инструментов (все страницы `tools/list`).
   После сохранения токен не отображается — только отметка «сохранён».
2. «Инструменты» на карточке: полный каталог с исходными именами.
3. Кнопка инструментов в шапке чата: выбор серверов/инструментов с областью
   «Чат»/«Проект»; выбранное сохраняется между перезапусками, новые tools
   приходят невыбранными, пропавшие показаны отдельным списком.
4. Мобильная/Аврора сборка: stdio-сегмент недоступен с явной причиной,
   HTTPS-подключение доступно.

## Безопасность секретов (review round 1)

- Перед записью новых значений контроллер снимает снимок старых. Если после
  записи в vault изменение отклонено (устаревшая ревизия) или сохранение в
  host не удалось, старые значения восстанавливаются, а значения, записанные
  для несозданного подключения, удаляются.
- Rollback не перезаписывает значение, которое другой писатель сохранил после
  нас: если текущее значение не совпадает с нашим, оно остаётся нетронутым.
  Сбой самого rollback виден в редакторе, секреты в текст ошибки не попадают.
- Любая ошибка проверки (probe) проходит через `sanitizeMcpFailureForUi`:
  точное вхождение любого значения из формы или прочитанного из vault
  (bearer и секретные env) заменяет сообщение на безопасный fallback целиком,
  без частичной редакции.
- Если после удаления подключения vault не отдал секреты, страница показывает
  видимое предупреждение и кнопку «Повторить» (`retrySecretCleanup`),
  а не мнимый успех.

## Ограничения

- Интеграция в `lib/app.dart` и реальные четыре сервера — за B9; здесь только
  контракты B1/B2 и фабрика.
- «Проверить» в редакторе выполняет handshake и `tools/list` вне host, поэтому
  не проверяет коллизию имён каталога — коллизия проявляется статусом
  подключения после сохранения.
- OAuth, resources/prompts/sampling и старый HTTP+SSE не поддерживаются (по
  плану первого этапа).
- Удаление подключения удаляет и его секреты; восстановления токена нет.
