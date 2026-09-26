# B2: агентский мост MCP и политика инструментов

Статус: реализация B2 завершена, `dart format`, `flutter analyze` и
`flutter test` зелёные. Область: `lib/core/agents` (мост, схемы, права),
затронутые точки агентского рантайма и зеркальные тесты. Собственные MCP-серверы,
планировщик, UI и финальная композиция `lib/app.dart` не входят (B3–B9).

## Что добавлено

| Файл | Содержимое |
|---|---|
| `lib/core/agents/tool_schema.dart` | профили JSON Schema по wire-семействам, проверка представимости, валидатор значений с бюджетом работы |
| `lib/core/agents/mcp_tools.dart` | `McpAgentToolSource`, `McpAgentToolBinding`, `McpToolResultMapper`, `McpAgentToolBridge` |
| `lib/core/agents/access.dart` | `ToolAccessGrant`, `ToolAccessPolicy` — явные права чата/проекта/задачи |
| `lib/core/agents/tools.dart` | динамические `AgentToolSource`, атомарный merge в `AgentToolRegistry`, `AgentToolView`, per-provider проекция дескриптора, `binding`, `unavailableReason` |
| `lib/core/agents/runtime.dart` | снимок tools на запуск, проверка идентичности и прав перед каждым вызовом и после подтверждения, отказ без интерактивного подтверждения, `AgentToolUnavailable` |
| `lib/core/agents/definition.dart` | флаг `interactiveApproval` (по умолчанию `true`; старые записи читаются без миграции) |
| `lib/core/agents/events.dart` | событие `AgentToolUnavailable(toolId, reason)` |

## Как B9 собирает мост

```dart
final bridge = McpAgentToolBridge(host: mcpHost);   // один раз на приложение
bridge.attachTo(tools);                             // рядом с read/write/edit/bash

// Права чата/проекта: только выбранные стабильные идентификаторы.
policies['chat-42'] = ToolAccessPolicy(
  id: PolicyId('chat-42'),
  grant: bridge.grantFor(
    allowedToolIds: chatSelection, // model-facing имена из каталога
  ),
);

// Задача по расписанию: подтверждений не ждёт, создавать задачи не может.
policies['task-7'] = ToolAccessPolicy(
  id: PolicyId('task-7'),
  grant: ToolAccessGrant.scheduledTask(
    allowedToolIds: taskSelection,
    deniedToolIds: taskCreationToolIds,
  ),
);
```

Определение задачи дополнительно создаётся с `interactiveApproval: false`;
рантайм в этом случае отклоняет любой `ask` до обращения к
`ToolApprovalHandler`. Права проекта можно привязать к конкретному
`ProjectId` (`ToolAccessPolicy(projectId: ...)`): вызов из другого проекта или
из чата без проекта отклоняется. Отключение источника: `bridge.detachFrom(tools)` и
`bridge.dispose()`; `registry.dispose()` снимает подписки.

`bridge.source.unavailableTools` отдаёт UI карту
`modelToolName -> причина` для инструментов, которые видны в каталоге, но не
могут быть предложены провайдеру.

## Схемы: ничего не выбрасывается молча

`ToolSchemaProfile` объявляет, какие ключевые слова JSON Schema провайдер
переносит без потери смысла. `representToolSchema` возвращает либо **точную
копию** исходной схемы (ни одно ограничение не удаляется и не ослабляется),
либо явную причину недоступности. Поддержаны `type`, `properties`, `required`,
`additionalProperties`, `patternProperties`, `items`, `enum`, `const`,
`anyOf`/`oneOf`/`allOf`/`not`, числовые и строковые ограничения, `format`
(фиксированный список), вложенные объекты и массивы.

Инструмент с неподдерживаемым `inputSchema`/`outputSchema` остаётся
зарегистрированным, но **не показывается модели**, а его вызов отклоняется с
видимой причиной (`AgentToolUnavailable`). Тот же валидатор проверяет аргументы
перед каждым вызовом, а `structuredContent`, объявленный в `outputSchema`,
проверяется после вызова: несоответствие — видимая ошибка, не успех.

## Права и каталог

- Allowlist — множество стабильных имён (`mcp_<connection>__<tool>` из B1).
  Неизвестный идентификатор = отказ; явный `denied` сильнее `allowed`; `ask`
  превращается в отказ, когда интерактивное подтверждение невозможно.
- Каждый запуск фиксирует свой набор инструментов и их идентичности до первого
  обращения к модели. Обновление каталога не расширяет текущий запуск.
- Перед каждым вызовом заново проверяются: живой маршрут `(connectionId,
  originalToolName)`, отпечаток схемы и текущая политика. После ожидания
  интерактивного подтверждения проверка повторяется — устаревшее подтверждение
  не обходит ни изменение каталога, ни изменение прав.
- Инструмент, удалённый из каталога или сменивший маршрут, падает явной
  ошибкой без вызова сервера.

## Результаты MCP

- `isError: true` → `ToolExecutionResult.failure`, текст ошибки и
  `structuredContent` попадают в транскрипт как данные (`error` + `details`).
- `structuredContent` успешного вызова передаётся как есть (с лимитом объёма и
  явной пометкой при усечении).
- Текстовые, медиа-, resource-link, embedded-resource и неизвестные блоки
  отображаются структурно; медиа не теряется молча — указываются MIME,
  длина и признак усечения, неизвестный тип назван (`unsupported` + label).
- `timeout` и `cancelled` различаются: таймаут — ошибка инструмента, отмена
  разворачивает запуск (`AgentRunCancelled`), progress из сервера доходит как
  `AgentToolProgress`.
- Описания инструментов считаются недоверенными данными: происхождение
  помечено `[MCP: <connection>]`, управляющие символы удалены, длина
  ограничена. Они не участвуют в политике прав.

## Тесты

| Файл | Что проверяет |
|---|---|
| `test/core/agents/tool_schema_test.dart` | представимость сложных схем, per-provider профиль, отказ по `$ref`/`if`/tuple items/неизвестному `format`, полный набор ограничений при валидации, бюджет работы |
| `test/core/agents/access_test.dart` | deny-by-default, приоритет явного запрета, `ask`→`deny` для задачи, destructive-аннотации, миграция старой записи определения |
| `test/core/agents/tool_sources_test.dart` | атомарный merge источников, коллизии имён, отключение источника, приоритет встроенных инструментов |
| `test/core/agents/mcp_tools_test.dart` | вызов B1-фикстуры через обычный чат, маршрутизация двух серверов с `search`, refresh без расширения прав, удалённый инструмент без вызова, сложные схемы, `isError`/`structuredContent`/медиа, progress/timeout/отмена, подтверждение и повторная проверка, задача без подтверждений и создания задач |

Существующие тесты Pi-инструментов и реплея старых сессий не менялись и
проходят; `interactiveApproval` по умолчанию сохраняет прежнее поведение, а
`toJson` пишет поле только для неинтерактивных запусков, поэтому старые записи
не переписываются.

## Ограничения

- Провайдеры, которых нет в приложении (Anthropic/Gemini wire families),
  используют профиль `portable`; для нового семейства нужно объявить профиль
  явно в `ToolSchemaProfile`.
- Поддержаны только локально разрешаемые `format`; неизвестный `format`
  делает инструмент недоступным (осознанный fail-closed).
- `outputSchema` проверяется только при наличии `structuredContent`; сервер,
  который его не вернул, не получает ошибку, но и не подтверждает контракт.
- Гранты и права строит композиция (B7/B9): B2 предоставляет контракт,
  фабрики и проверку перед каждым вызовом, но не UI выбора и не хранилище
  прав.
