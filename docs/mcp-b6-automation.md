# B6: планировщик и локальный MCP-сервер `automation` — результат

Статус: реализация B6 завершена, `dart format`, `flutter analyze` и
`flutter test` зелёные. Область: `lib/core/automation`,
`lib/infrastructure/automation`, `lib/infrastructure/mcp/servers/automation`,
зеркальные тесты и расширение внутреннего запрета B2. `lib/app.dart` и UI не
менялись: B8/B9 получают готовые фабрики и сервис.

## Что добавлено

| Файл | Содержимое |
|---|---|
| `core/automation/cron.dart` | пятичастный cron-парсер (`*`, списки, диапазоны, шаги, имена месяцев/дней), правило OR для дня месяца/недели, ограниченный поиск следующего и предыдущего момента |
| `core/automation/schedule.dart` | `AutomationSchedule`: разовый UTC-момент или cron с явным IANA-поясом, проверка достижимости, ближайшие три момента |
| `core/automation/wall_clock.dart`, `time_zones.dart` | локальное настенное время и контракт `AutomationTimeZones` (DST-политика живёт в `core`) |
| `core/automation/task.dart`, `run.dart` | версионированные модели задачи и запуска, состояния, снимки модели/инструментов/доставки, `(taskId, scheduledAt)` ключ |
| `core/automation/service.dart` | `AutomationService`: создание/подтверждение/пауза/возобновление/удаление, `runTaskNow`, тик, catch-up, no-overlap, foreground, события |
| `core/automation/executor.dart`, `repository.dart`, `limits.dart`, `clock.dart`, `events.dart`, `errors.dart`, `ids.dart` | контракты запуска, хранилища, лимиты, часы, события и ошибки |
| `infrastructure/automation/time_zone_database.dart` | адаптер `timezone` 0.11.1 поверх встроенной базы IANA |
| `infrastructure/automation/automation_jsonl_store.dart` и соседние | версионированный JSONL задач и истории запусков с replay, ревизиями и идемпотентностью |
| `infrastructure/automation/agent_session_automation_executor.dart` | запуск отдельной агентской сессии со снимком задачи, политикой scheduled-task и лимитами |
| `infrastructure/automation/automation_composition.dart` | `buildAutomationStack` — готовая композиция для B9 |
| `infrastructure/automation/automation_foreground_observer.dart` | мобильная политика foreground/background |
| `infrastructure/mcp/servers/automation/automation_mcp_server.dart` | четыре MCP-инструмента над тем же сервисом |

## Spike зависимостей

| Кандидат | Вердикт |
|---|---|
| `cron_parser` 0.5.0 | **Не добавлен.** Последняя публикация четыре года назад, нет платформы web, семантика DST не определена. Пятичастный парсер реализован в `core/automation/cron.dart`: он детерминирован, ограничен по работе и тестируется на DST/границах месяца напрямую. |
| `timezone` 0.11.1 | **Добавлен.** Поддерживает web. Инициализация — встроенная `data/latest_all.dart` (`initializeTimeZones()`), а не `standalone.dart` (тот читает `.tzf` через `dart:io` и для Flutter не подходит) и не `browser.dart` (требует раздачи базы как web-ассета). Локальная зона устройства не читается: у каждой задачи явный IANA-пояс. |

DST-семантика проверена тестами против реальных переходов
`America/New_York`, `Europe/Berlin` и `Australia/Sydney`, а не предполагается
реализацией пакета. Web-сборка с подключённым `infrastructure/automation`
компилируется: адаптер не использует `dart:io`.

## Правила времени и DST-политика

- Все моменты хранятся и сравниваются в UTC; локальное время — только
  вычисление из явного IANA-пояса. `scheduledAt` идемпотентности не зависит от
  переходов.
- Пропавшее локальное время (весенний перевод вперёд) в этот день
  **пропускается**: подстановки «на час позже» нет, берётся следующий
  подходящий момент.
- Повторяющееся локальное время (осенний перевод назад) срабатывает **один
  раз, в более ранний UTC-момент**; второй проход не создаёт второй запуск.
- Взаимодействие дня месяца и дня недели — обычное (Vixie cron): если
  ограничены **оба** поля, достаточно совпадения любого; если одно — только
  оно. Поле считается ограниченным, если оно не ровно `*` (то есть `*/2`
  ограничено).
- Невозможные даты (`0 0 30 2 *`, `0 0 31 4 *`) не принимаются при сохранении:
  `validateReachable` требует три достижимых момента, иначе видимая ошибка
  `invalid_schedule`. Поиск ограничен 12 годами с запасом на 29 февраля, так
  что «вечный» цикл невозможен.
- Отклоняются: секунды, шесть полей, `@daily`, `?`, `L`, `W`, `#`,
  перевёрнутые диапазоны, нулевой шаг и значения вне поля.

Подробная пользовательская формулировка — в
[`automation-user-guide.md`](automation-user-guide.md).

## Хранение

- Namespace `ru.kotdath.domovoy/automation-jsonl-v1`; один поток на задачу
  (`task-<taskId>`) и один на запуск (`run-<runId>`), конверт
  `domovoy.automation_operation` v1 с `sequence`, `expectedRevision`,
  `entryRevision`.
- Replay проверяет вид потока, идентичность, последовательность и цепочку
  ревизий; усечённый хвост отбрасывается и починяется при следующей записи,
  любое другое повреждение — видимая `corruption` без частичного чтения.
- `createTask` = ревизия 0, каждое изменение = +1 и требует ожидаемую ревизию;
  запись запуска = ревизия 0 (`running`), терминальная = +1, обновление
  доставки = +2; больше трёх записей на запуск не принимается.
- Идемпотентность `(taskId, scheduledAt)` закреплена и в сервисе, и в
  хранилище: повторный запуск того же периода отклоняется конфликтом.
- Web и неизвестные цели не получают файлового хранилища
  (`createPlatformAutomationJsonlStreamStorage()` возвращает `null`); B9 не
  регистрирует тогда сервер и не выдумывает путь.

## Планировщик

- Один catch-up при открытии/resume: вычисляется последний момент `<= now`,
  создаётся **один** запуск, более старые периоды сворачиваются в
  `aggregatedSkippedCount` (с потолком `maxAggregatedSkipped` и флагом
  `skippedTruncated`), лавины запусков нет. Следующий момент строго `> now`.
- No-overlap: пока задача выполняется, следующий период записывается
  `skipped` без очереди, а ручной запуск отклоняется `no_overlap`.
- `run_task_now` не сдвигает `nextDueAt`; задача-предложение не запускается до
  подтверждения человеком; разовая задача после срабатывания переходит в
  `completed`.
- Пауза очищает `nextDueAt` (периоды паузы не воспроизводятся), возобновление
  берёт следующий будущий момент.
- После аварийного закрытия оставшиеся `running`-записи при старте становятся
  `interrupted` без повторения побочных эффектов; период с уже
  зафиксированным `scheduledAt` не запускается снова.
- Таймер будит планировщик к **сохранённому** UTC-моменту; при уходе в фон
  мобильное приложение останавливает таймеры и прерывает активный запуск,
  desktop продолжает работу, пока живёт процесс. Пока приложение закрыто, не
  выполняется ничего.

## Запуск задачи

- Каждый fire создаёт **отдельную** transient-сессию агента: системный промпт
  фиксирован, модель, промпт, разрешённые инструменты, доставка и лимиты
  берутся из снимка ревизии задачи.
- Политика `scheduled-task-<taskId>` — `ToolAccessGrant.scheduledTask`:
  `interactiveApproval: false`, `ask` всегда отказ, а
  `automation.create_task` и `automation.run_task_now` запрещены внутренне.
- Перед обращением к модели проверяются модель, каждый закреплённый инструмент
  (регистрация, доступность, представимость схемы) и ключ провайдера; при
  недоступности запуск падает видимо (`model_unavailable`, `tool_unavailable`,
  `secret_unavailable`), а не идёт с урезанными правами.
- Лимиты: время (жёсткий дедлайн вокруг запуска + `AgentRunLimits`), число
  обращений к модели, число вызовов инструментов, размер результата и трассы.
- Итог запуска: статус, текст, ошибка, трасса вызовов, число turn'ов/вызовов,
  результат доставки. Трасса не содержит секретов.

## MCP-инструменты

| Tool | Вход | Успешный `structuredContent` |
|---|---|---|
| `create_task` | `name`, `prompt`, ровно одно из `cron`+`timeZone` / `runAt`, `model`, `allowedTools[]`, необязательный `delivery` | `taskId`, `state: proposed`, `requiresConfirmation: true`, `revision`, `nextOccurrences` (3) |
| `list_tasks` | необязательные `status` (`active|paused|proposed|completed|deleted|all`), `limit` | `tasks[]` со статусом, cron/поясом, `nextDueAt` и сводкой `lastRun` |
| `pause_task` | `taskId`, `paused`, необязательный `expectedRevision` | `taskId`, `state`, `revision`, `nextDueAt?` |
| `run_task_now` | `taskId`, необязательный `expectedRevision` | `runId`, `status: running`, `trigger: manual`, `scheduledAt` |

`create_task` всегда создаёт **предложение** (`origin: agent`); включает его
человек в разделе «Задачи» (B8) через `confirmTask`. Вызов агентом
`create_task` не даёт расписанию никаких новых прав.

## Защита от расширения прав

`automation.run_task_now` мог бы позволить задаче по расписанию запустить
другую сохранённую задачу с более широкими правами. Защита двойная:

1. B2: `ScheduledToolRestrictions.intrinsicDeniedToolIds` теперь включает и
   `mcp_automation__run_task_now`, поэтому неприсмотренный грант запрещает
   вызов независимо от allowlist (`test/core/agents/access_test.dart`,
   `agent_session_automation_executor_test.dart` — агент пробует вызвать оба
   инструмента, исполнение не происходит).
2. Сервер: `run_task_now` отказывает, пока в процессе выполняется
   запланированный запуск (`AutomationService.isScheduledRunActive`), даже
   если вызов как-то дошёл до сервера; сервис дополнительно запрещает
   `runTaskNow` с `origin: scheduledRun` и с `origin: agentTool` во время
   активного планового запуска.

## Как собирают B8 и B9

```dart
final storage = createPlatformAutomationJsonlStreamStorage();
if (storage != null) {
  final stack = buildAutomationStack(
    storage: storage,
    runtime: runtime,                 // InMemoryAgentRuntime
    policies: runtime.policies,       // живая таблица политик
    models: registry,
    tools: tools,
    credentials: credentials,
    delivery: tasksDeliverySink,      // карточка в чате (B8/B9)
  );
  await stack.service.start();
  localHost.register(AutomationMcpServerFactory(service: stack.service));
  await localHost.start('automation');
  // B8: тот же stack.service для раздела «Задачи» и stack.service.events.
  // Observer: AutomationForegroundObserver(service: stack.service).attach();
}
```

`buildAutomationStack` создаёт единственные в приложении хранилище,
планировщик и executor; второй копии нет ни в UI, ни в MCP-сервере.

## Тесты

| Файл | Что проверяет |
|---|---|
| `test/core/automation/cron_test.dart` | разбор всех форм полей, отказы, OR-правило DOM/DOW, `*/5`, границы месяца/года, 29 февраля, недостижимые даты, ограниченность поиска, `lastAtOrBefore` |
| `test/core/automation/cron_dst_test.dart` | DST-политика на управляемой зоне: пропуск gap, единственный запуск в fold, границы проходов |
| `test/core/automation/schedule_test.dart` | JSON round-trip, неизвестный пояс, недостижимое выражение, preview трёх моментов |
| `test/core/automation/task_run_test.dart` | модели задачи/запуска, инварианты состояний, санитизация ошибок, лимиты |
| `test/core/automation/automation_service_test.dart` | fake-clock `*/5`, подтверждение предложения, пауза/возобновление, run-now без сдвига, конкурентные тики, no-overlap, catch-up с агрегацией, crash replay, лимит времени, фон, недоступность, доставка, привилегии, события |
| `test/infrastructure/automation/automation_jsonl_store_test.dart` | ревизии, tombstone, replay после рестарта, идемпотентность периода, усечённый хвост, повреждение, лимиты |
| `test/infrastructure/automation/time_zone_database_test.dart` | реальные IANA-переходы NY/Berlin/Sydney, границы месяца, 29 февраля, недостижимые даты |
| `test/infrastructure/automation/agent_session_automation_executor_test.dart` | доступность модели/инструментов/ключа, снимок определения, отдельная сессия на запуск, трасса, запрет `create_task`/`run_task_now`, лимит вызовов, отмена |
| `test/infrastructure/automation/automation_foreground_observer_test.dart` | мобильная пауза/возобновление, desktop игнорирует lifecycle |
| `test/infrastructure/mcp/servers/automation/automation_mcp_server_test.dart` | схемы для профилей B2, proposal-only `create_task`, `list_tasks`/`pause_task`/`run_task_now`, revision mismatch, запрет во время планового запуска, отмена |
| `test/core/agents/access_test.dart` | внутренний запрет `run_task_now` для неприсмотренных грантов |

## Демонстрация дня 18

1. Открыть раздел «Задачи», создать задачу с `*/5 * * * *`, явным поясом и
   промптом; UI показывает ближайшие три запуска до включения.
2. Дать задаче права на `arxiv.search_papers` и `library.save_digest`,
   выполнить один запуск вручную (`run_task_now`) — появляется `runId` и
   результат; следующий плановый момент не изменился.
3. Оставить приложение открытым на 10–15 минут: видны отдельные запуски с
   результатом и трассой; повторный запуск того же периода не создаётся.
4. Поставить задачу на паузу, пропустить несколько периодов, снять с паузы —
   пропущенное не воспроизводится.
5. Закрыть приложение на несколько периодов и открыть: выполняется ровно один
   свежий запуск, старые периоды отмечены агрегированно как пропущенные.

Ограничение дня 18 «24/7»: приложение не работает, пока оно закрыто. Демо
показывает периодическую работу при открытом приложении и один catch-up при
следующем открытии; для буквальных 24/7 нужен отдельный процесс/сервер и новое
продуктовое решение.

## Ограничения

- Литеральные 24/7 и работа при закрытом приложении не поддерживаются — это
  принятая граница этапа; Android WorkManager, системный cron и push вне
  приложения не используются.
- Web не имеет файлового хранилища автоматизации: B9 не регистрирует сервер,
  планировщик не запускается.
- Доставка «карточка в чате» включается только внедрённым
  `AutomationResultDelivery`; без него результат остаётся в разделе «Задачи» с
  видимой пометкой, что доставка недоступна.
- Парсер сознательно не поддерживает секунды, год, Quartz-макросы и
  неоднозначные расширения; имена месяцев/дней поддержаны.
- Размер результата, трассы и записи ограничен; превышение обрезается с
  видимым маркером.
- Задачи хранятся по устройству; синхронизации между ПК и телефоном нет.
