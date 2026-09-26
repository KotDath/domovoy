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
| stdio: шумный старт | 2000 строк stderr до initialize не блокируют handshake и редактируются |
| Streamable HTTP: loopback, динамический порт, bearer | `mcp_http_transport_test.dart` на Dart VM и smoke на эмуляторе Android |
| In-process stream (`IOStreamTransport`) | `mcp_stream_transport_test.dart`, переподключение к свежей сессии |
| Пагинация `tools/list` | Реальные курсоры через низкоуровневый сервер + guard на повтор курсора |
| Изоляция четырёх серверов | `mcp_host_manager_test.dart`: 4 каталога, коллизии имён, маршрутизация |
| Стабильность имён | Имя — чистая функция `(connectionId, originalToolName)`; удаление/добавление tools не переименовывает соседей |
| Секреты | Только ссылки в JSONL; stderr и диагностика редактируются |
| Окружение stdio | Allowlist + явные значения; `DEEPSEEK_API_KEY` ребёнку не передаётся |

## Loopback

Фактический результат на этой машине (Linux desktop, Dart VM):

- `StreamableMcpServer` на `127.0.0.1` с `port: 0` сообщает реальный
  `boundPort`; клиент подключается по `http://127.0.0.1:<port>/mcp` с
  короткоживущим bearer-токеном.
- Неверный токен отклоняется до доступа к каталогу (HTTP 403 при пустом
  `oauthProtectedResource`), что видно в тесте.

Фактический результат на эмуляторе Android 15 (API 35, `emulator-5554`,
`x86_64`), временный probe через `flutter run`, удалён из репозитория:

```
http-endpoint=streamableHttp http-url=http://127.0.0.1:41577/mcp
stdio-supported=false
http-handshake=android-smoke/2026-07-28
http-tools=search
http-call=android-smoke:search:android
stream-handshake=android-stream
stream-reconnect-call=android-stream:search:stream
result=ok
```

То есть на Android работают и loopback HTTP с bearer-токеном, и in-process
stream, включая переподключение к тому же встроенному серверу; сторонний stdio
через публичный API не предлагается (`McpStdioLauncher.isSupported == false`).

## Платформенные ограничения

- **Linux/Windows/macOS**: доступны все три транспорта. stdio запускается через
  `dart:io` с минимальным окружением.
- **Android**: сторонний stdio не предлагается. Loopback HTTP и in-process
  stream подтверждены на эмуляторе API 35; встроенные серверы можно поднимать
  обоими способами.
- **Аврора**: `dart:io` есть, но loopback HTTP и запуск процессов не
  подтверждены. Dart определяет `Platform.isLinux` как
  `operatingSystem == 'linux'`, поэтому Aurora может выглядеть как обычный
  Linux; **автоматическое определение Aurora не заявляется**. B9 обязан
  отключить сторонний stdio явным override композиции:

  ```dart
  createMcpStdioLauncher(
    forceDisabled: true,
    disabledReason: auroraStdioDisabledReason,
  )
  ```

  До smoke на устройстве встроенные серверы работают через stream-fallback.
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

Android-loopback воспроизводится временным `flutter run`-probe (в репозитории
не хранится): поднять `LocalMcpServerHost` с HTTP-предпочтением, подключиться
через `McpSdkTransportFactory` и выполнить handshake/list/call на
`emulator-5554`.

При обычном `flutter test` тест stdio остаётся валидным, но проверка утечки
родительских секретов становится тривиальной: задайте переменные окружения,
как в команде выше.

## Правки после ревью раунда 3

- Поздний отказ каталога (`_failConnectionForCatalog`) перепроверяет поколение
  операции и идентичность соединения после `await close()`: remove, disconnect
  или stop во время закрытия не воскрешают удалённый/остановленный статус.
- `LocalMcpServerHost.acquireStreams` после старта сессии перепроверяет, что
  running-состояние всё ещё зарегистрировано: остановка во время старта
  закрывает отвязанную сессию и даёт явную ошибку, повторный `start()` и
  подключение работают; правило одного живого клиента сохранено.
- Сторонний stdio отключается явным override
  (`createMcpStdioLauncher(forceDisabled: true, disabledReason: ...)`) для
  сборок, где Dart не может отличить Aurora от Linux; автоопределение не
  заявляется, B9 обязан выставить override.

## Правки после ревью раунда 2

- `_attemptConnect` различает `connected` / `failed` / `stale`: отменённая
  явным disconnect или stop попытка не планирует реконнект.
- `McpConnectionRepository.loadTombstones()` отдаёт ревизии удалённых
  соединений; после рестарта re-add продолжает tombstone-ревизию, optimistic
  проверки не ослаблены.
- Каталог публикуется транзакционно: кандидат строится до мутаций, поэтому
  коллизия имён роняет только своё соединение (закрывается, маршруты
  снимаются) и не ломает соседей; `refreshCatalog` ведёт себя так же.
- `LocalMcpServerHost.start` не сохраняет сломанный endpoint: неудачная
  сессия очищается и повторный `start()` работает. Живой stream-клиент
  резервирует сессию, конкурентные `acquireStreams` отклоняются.
- Сторонний stdio разрешён только на Linux, Windows и macOS; для Aurora B9
  добавляет явный override (см. раунд 3).

## Правки после ревью раунда 1

- Ревизии соединений согласованы: create = 0, update = +1, re-add после
  удаления продолжает ревизию tombstone; одинаково для in-memory и JSONL.
- Имена tools больше не зависят от состава каталога; коллизия полного имени
  отклоняется явной ошибкой.
- Отпечаток каталога включает схему/описание/аннотации, поэтому смена
  дескриптора публикуется новой ревизией.
- In-flight connect/refresh проверяют поколение операции и не публикуются после
  disconnect/remove/upsert/stop; отброшенные соединения закрываются.
- Реконнект инкрементирует счётчик ровно один раз на сбой.
- Переподключение к встроенному stream-серверу получает свежую сессию.
- stderr stdio-ребёнка подписывается сразу после старта транспорта.
- Повреждённый JSONL конфигурации виден в snapshot (`configurationError`),
  событием и исключением из `start()`.
- `McpCatalog.forConnection` возвращает неизменяемые списки.

## Незакрытые риски

- Аврора loopback не подтверждён; fallback stream обязателен.
- `notifications/tools/list_changed` принимается адаптером и запускает
  атомарный refresh, но в stateless-профиле MCP `2026-07-28` push-уведомления
  требуют `subscriptions/listen`; наш сценарий опирается на refresh при
  переподключении и явный `refreshCatalog`.
- Схемы MCP сложнее формата LLM-провайдера: полная схема сохраняется в
  каталоге, но недоступные для провайдера инструменты должен явно помечать B2.
- `mcp_dart` 2.4.2 по умолчанию пишет свои debug/info-логи **в stderr** на VM
  (`logging_io.dart`: `writeLog(stderr.writeln)`), на web — в `print`. Это
  метаданные конверта (методы, id), не payload; секреты туда не попадают, а
  при необходимости B9 может замолчать их через `silenceMcpLogs()` или
  перехватить через `setMcpLogHandler`. Наши собственные диагностические
  сообщения проходят через `McpSecretRedactor` и `sanitizeMcpText`.
