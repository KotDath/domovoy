# MCP в Domovoy: план и демонстрация дней 16–20

## Выбор SDK

Используется `mcp_dart` 2.4.2 в единственном Flutter-пакете `domovoy`. Он
предоставляет клиент и сервер Streamable HTTP и работает с Dart 3.10+, включая
Flutter-клиент. Опубликованная версия поддерживаемого Dart-командой `dart_mcp`
пока не предоставляет Streamable HTTP, поэтому для удалённых серверов она не
подходит. Проверьте состояние пакетов перед обновлением зависимости:

- [mcp_dart на pub.dev](https://pub.dev/packages/mcp_dart)
- [dart_mcp на pub.dev](https://pub.dev/packages/dart_mcp)
- [транспорт MCP](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)

## Два процесса

1. **Archive MCP** (`bin/archive_mcp_io.dart`, `/mcp`, порт 8401):
   `archive_search` вызывает [Advanced Search API](https://archive.org/advancedsearch.php),
   `archive_item` вызывает [Metadata API](https://archive.org/metadata/bigbuckbunny).
   Это публичные операции чтения без учётных данных. Дополнительные
   `task_create`, `task_list`, `task_complete` ведут задачи реализации и
   исследования, при необходимости привязанные к архивному материалу;
   задачи тоже сохраняются в JSONL.
   Публикация файлов в Internet Archive не входит в текущие операции: для неё
   нужны отдельные учётные данные и решение по разрешённым действиям.
2. **Briefing MCP** (`bin/briefing_mcp_io.dart`, `/mcp`, порт 8402):
   `summarize_items`, `save_digest`, `list_digests`, `schedule_digest`,
   `run_due_digests`, `list_schedules`, `cancel_schedule`. Сводка составляется
   из метаданных и коротких описаний, а не из полного содержимого медиа.
   Отчёты и расписание сохраняются событиями в JSONL. Встроенный таймер
   исполняет задания, пока сервер работает. Для поиска он сам вызывает
   **Archive MCP** через MCP SDK.

На VPS оба процесса можно разместить за HTTPS reverse proxy. По умолчанию
они слушают только `127.0.0.1`; для внешней публикации настройте TLS, проверку
доступа в proxy/VPN и явные `MCP_ALLOWED_HOSTS` / `MCP_ALLOWED_ORIGINS`.
Текущий клиент принимает HTTP только для loopback-адресов и HTTPS для удалённых.
Секреты не помещаются в URL, исходный код или JSONL. Авторизацию удалённого
MCP endpoint через OAuth/secure storage следует добавить перед прямой
публикацией в интернет.

## Локальный запуск

В разных терминалах:

```sh
dart run bin/archive_mcp_io.dart
BRIEFING_JSONL_PATH=data/briefing.jsonl dart run bin/briefing_mcp_io.dart
dart run bin/mcp_demo_io.dart 'identifier:bigbuckbunny*'
dart run bin/mcp_schedule_demo_io.dart 'identifier:bigbuckbunny*'
```

`mcp_demo_io.dart` сначала печатает оба списка инструментов, затем делает
`archive_search → archive_item → task_create → summarize_items → save_digest →
task_complete → list_digests`.
Это воспроизводимый автоматический маршрут с передачей результата между
серверами. `mcp_schedule_demo_io.dart` создаёт периодическое задание,
дожидается отчётов, читает агрегат, затем отменяет задание. Для длительной
работы оставьте оба сервера запущенными под `systemd` с постоянным каталогом
для JSONL и выполняйте периодические запросы через `list_digests`.

Параметры серверов: `MCP_BIND_HOST`, `MCP_PORT`, `MCP_ALLOWED_HOSTS` (список
через запятую), `MCP_ALLOWED_ORIGINS` (список через запятую),
`ARCHIVE_MCP_URL`, `ARCHIVE_TASKS_JSONL_PATH`, `BRIEFING_JSONL_PATH`.
У каждого процесса свой `MCP_PORT`.
Для HTTPS proxy оставьте привязку к loopback; в `MCP_ALLOWED_HOSTS` укажите
публичное имя, которое proxy передаёт в `Host`.

## Подключение к агенту

`McpRemoteTools.connect` создаёт отдельный MCP-клиент для каждого адреса,
запрашивает `tools/list` с поддержкой страниц, превращает JSON Schema в схемы
агента и регистрирует маршруты вида `archive__archive_search` и
`briefing__summarize_items`. Исполнитель передаёт JSON-аргументы в `tools/call`,
возвращает структурированный результат модели, пробрасывает отмену и прогресс.
Эти инструменты добавляются к локальным `read`, `write`, `edit`, `bash`; записи
старых чатов обновляются при восстановлении.

Для нативного Linux-приложения с обоими серверами:

```sh
flutter run -d linux --dart-define='DOMOVOY_MCP_SERVERS={"archive":"http://127.0.0.1:8401/mcp","briefing":"http://127.0.0.1:8402/mcp"}'
```

В сборке для VPS используйте HTTPS URL. Это значение пока задаётся при сборке
или запуске через `--dart-define`; следующим шагом можно добавить экран списка
серверов, обновление discovery без перезапуска приложения и OAuth с хранением
токенов в `flutter_secure_storage`. При недоступном сервере приложение
запускается с локальными инструментами, а ошибка подключения идёт в лог.

## Соответствие заданиям

| День | Реализация | Проверка |
| --- | --- | --- |
| 16 | `McpRemoteTools.connect`, `tools/list`; CLI печатает оба списка | HTTP integration test и живой CLI прогон |
| 17 | `archive_search`/`archive_item` с параметрами и результатом; подключение к агенту и UI карточкам инструментов | HTTP integration test; живой прогон приложения с LLM нужен для видео |
| 18 | `schedule_digest`, JSONL, таймер, `list_digests`, `cancel_schedule` | тест восстановления и живой прогон двух фоновых сводок |
| 19 | автоматический CLI pipeline поиска, обработки и сохранения | тест порядка и переданных данных |
| 20 | два MCP-сервера, имена с префиксом, маршрутизация; Briefing MCP вызывает Archive MCP | тест маршрута и живой CLI прогон |

Живой прогон реального DeepSeek агента (без заглушки модели):

```sh
flutter test test/diagnostics/mcp_live.dart --reporter expanded
```

При наличии `DEEPSEEK_API_KEY` и двух запущенных серверов он завершился
маршрутом `archive__archive_search → briefing__summarize_items →
briefing__save_digest`, все три вызова успешны. Видеопрогон интерфейса
оформляется отдельно для сдачи.
