# B1: MCP-основа — результат платформенного spike

Статус: реализация B1 завершена, автоматические проверки зелёные.
Область: `core/mcp`, `core/research`, `infrastructure/mcp`, корневой
`pubspec.yaml`. Фабрики серверов, UI, агентский мост и `lib/app.dart` в B1 не
входят и подключаются в B2–B9.

## Что проверено

| Проверка | Результат |
|---|---|
| `mcp_dart` 2.4.2 на Dart 3.11 / Flutter 3.41 | Резолвится, собирается web и Linux |
| Negotiated protocol (профиль `stable`) | С нашими серверами согласуется MCP `2026-07-28`; legacy-fallback остаётся в SDK |
| stdio: handshake/tools/list/tools/call | Живой дочерний процесс `dart run` в `mcp_stdio_transport_test.dart` |
| Streamable HTTP: loopback, динамический порт, bearer | `mcp_http_transport_test.dart` на Dart VM |
| In-process stream (`IOStreamTransport`) | `mcp_stream_transport_test.dart` |
| Пагинация `tools/list` | Реальные курсоры через низкоуровневый сервер + guard на повтор курсора |
| Изоляция четырёх серверов | `mcp_host_manager_test.dart`: 4 каталога, коллизии имён, маршрутизация |
| Секреты | Только ссылки в JSONL; stderr и диагностика редактируются |
| Окружение stdio | Allowlist + явные значения; `DEEPSEEK_API_KEY` ребёнку не передаётся |

## Loopback

Фактический результат на этой машине (Linux desktop, Dart VM):

- `StreamableMcpServer` на `127.0.0.1` с `port: 0` сообщает реальный
  `boundPort`; клиент подключается по `http://127.0.0.1:<port>/mcp` с
  короткоживущим bearer-токеном.
- Неверный токен отклоняется до доступа к каталогу (HTTP 403 при пустом
  `oauthProtectedResource`), что видно в тесте.
- Платформенный smoke на Android и Авроре **не выполнялся**: устройств в этой
  среде нет. Для телефонов безопасный путь — `McpLocalTransportPreference.stream`
  (`IOStreamTransport` внутри процесса), он не требует сокетов и проверен
  тестами; loopback HTTP остаётся предпочтением `auto` там, где он
  подтверждён.

## Платформенные ограничения

- **Linux/Windows/macOS**: доступны все три транспорта. stdio запускается через
  `dart:io` с минимальным окружением.
- **Android**: сторонний stdio не предлагается
  (`McpStdioLauncher.isSupported == false`; явная ошибка `unsupported`).
  Встроенные серверы работают; до подтверждения loopback на устройстве
  использовать in-process stream.
- **Аврора**: `dart:io` есть, но loopback HTTP и запуск процессов не
  подтверждены. До smoke использовать stream; конкретику зафиксирует B9.
- **Web**: серверы и stdio недоступны (stub), внутренние потоки и HTTP-клиент
  компилируются; `flutter build web` с подключённым `infrastructure/mcp`
  проходит.

## Как воспроизвести

```sh
flutter pub get
dart format .
flutter analyze
DEEPSEEK_API_KEY=sk-parent DOMOVOY_MCP_TEST_SECRET=parent-secret flutter test
flutter build web --target <любой файл, импортирующий infrastructure/mcp>
flutter build linux --debug --target <тот же файл>
```

При обычном `flutter test` тест stdio остаётся валидным, но проверка утечки
родительских секретов становится тривиальной: задайте переменные окружения,
как в команде выше.

## Незакрытые риски

- Android/Aurora loopback не подтверждён; fallback stream обязателен.
- `notifications/tools/list_changed` принимается адаптером и запускает
  атомарный refresh, но в stateless-профиле MCP `2026-07-28` push-уведомления
  требуют `subscriptions/listen`; наш сценарий опирается на refresh при
  переподключении и явный `refreshCatalog`.
- Схемы MCP сложнее формата LLM-провайдера: полная схема сохраняется в
  каталоге, но недоступные для провайдера инструменты должен явно помечать B2.
- `mcp_dart` 2.4.2 логирует протокольные метаданные на уровне debug в stdout;
  перед публичной сборкой B9 стоит выставить уровень логгера SDK.
