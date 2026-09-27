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

## Безопасность секретов (review round 2)

- Каждое заново введённое значение (bearer или секретная env-переменная)
  записывается под **уникальной неизменяемой ссылкой**; сохранённая
  конфигурация продолжает ссылаться на прежнюю ссылку и прежнее значение
  вплоть до успешного коммита. Старые фиксированные ссылки сохраняются, если
  значение не заменяли, и никогда не показываются в UI.
- Запись в vault идёт до коммита конфигурации. Если vault коммитит запись и
  затем бросает исключение, значение подтверждается чтением и используется
  дальше; если запись не подтверждается — сохранение отменяется, а staged-
  ссылки удаляются.
- Если сохранение конфигурации могло закоммититься и потом бросить исключение,
  контроллер перечитывает persisted-ревизию/конфигурацию и считает
  закоммиченное состояние истиной; superseded-ссылки удаляются только после
  подтверждённого коммита.
- Неудалённые staged/superseded ссылки показываются как видимая очистка с
  кнопкой «Повторить» (`retrySecretCleanup`); при неясном исходе (read-back
  тоже не удался) ссылки не удаляются вовсе, чтобы не сломать конфигурацию.
- `setEnabled` перечитывает конфигурацию непосредственно перед записью и
  сохраняет поля, изменённые параллельно; сбой авторитетного чтения
  показывается, полная запись из кэша не выполняется.
- В листе прав добавлено пояснение: выбор чата переопределяет проект, пустой
  выбор чата явно запрещает MCP в чате.
- Ошибки проверки (probe) и сохранения проходят через
  `sanitizeMcpFailureForUi`: точное вхождение любого введённого или
  прочитанного из vault секрета заменяет сообщение безопасным fallback целиком,
  без частичной редакции (bearer и секретные env, включая сохранённые
  значения).

## Ограничения

- Интеграция в `lib/app.dart` и реальные четыре сервера — за B9; здесь только
  контракты B1/B2 и фабрика.
- «Проверить» в редакторе выполняет handshake и `tools/list` вне host, поэтому
  не проверяет коллизию имён каталога — коллизия проявляется статусом
  подключения после сохранения.
- OAuth, resources/prompts/sampling и старый HTTP+SSE не поддерживаются (по
  плану первого этапа).
- Удаление подключения удаляет и его секреты; восстановления токена нет.
