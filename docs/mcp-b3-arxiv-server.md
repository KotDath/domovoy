# B3: локальный MCP-сервер arXiv — результат

Статус: реализация B3 завершена, `dart format`, `flutter analyze` и
`flutter test` зелёные, выполнен один живой smoke на официальном API.
Область: `lib/infrastructure/mcp/servers/arxiv/` и зеркальные тесты
`test/infrastructure/mcp/servers/arxiv/`. `lib/app.dart`, агентский мост B2,
другие серверы, планировщик, UI и `core/research` не менялись — общий
контракт Paper v1 использован как есть.

## Что добавлено

| Файл | Содержимое |
|---|---|
| `arxiv_errors.dart` | `ArxivFailureKind`/`ArxivFailure` и стабильный префикс `[arxiv:<kind>]` для MCP-результата |
| `arxiv_http.dart` | инъектируемый `ArxivHttpAdapter`, `HttpArxivHttpAdapter` на `package:http` с ограничением тела, без редиректов и PDF |
| `arxiv_atom.dart` | строгий ограниченный Atom-парсер arXiv: сущности, CDATA, пространства имён, ошибки API, лимиты полей |
| `arxiv_client.dart` | `ArxivClient`: запросы, нормализация, дедупликация версий, порядок, тайм-аут, rate limiter, `Retry-After`, LRU-кэш |
| `arxiv_mcp_server.dart` | `ArxivMcpServerFactory implements LocalMcpServerFactory` с `search_papers` и `get_paper` |
| `arxiv.dart` | публичный экспорт B3 для B9 |

## Контракт фабрики для B9

```dart
// Продакшен: фабрика сама создаёт HttpArxivHttpAdapter и владеет им.
final arxivFactory = ArxivMcpServerFactory();
localHost.register(arxivFactory);
await localHost.start('arxiv');           // serverId стабилен: 'arxiv'
// ... при остановке приложения:
arxivFactory.dispose();                   // закрывает только собственный адаптер

// Тесты/особая композиция: адаптер и часы инъектируются.
final testFactory = ArxivMcpServerFactory(
  httpAdapter: myAdapter,
  clock: myClock,
  requestTimeout: const Duration(seconds: 15),
  minRequestInterval: const Duration(seconds: 3),
  cacheTtl: const Duration(minutes: 10),
  cacheCapacity: 32,
  maxResponseBytes: 2 * 1024 * 1024,
);
```

Фабрика владеет одним `ArxivClient` на процесс: лимит частоты, «одно живое
соединение» и кэш общие для всех сессий, переподключений и HTTP-сессий
сервера, а не сбрасываются на сессию. `factory.client` отдаёт клиент для
диагностики. `serverId` — `arxiv`, версия `1.0.0`, displayName `arXiv`.

## Инструменты и провод

| Tool | Вход | Результат |
|---|---|---|
| `search_papers` | `query` (обязательный), `category`, `submittedAfter`, `sortBy`, `limit` 1–30 (по умолчанию 10) | `structuredContent {papers: [Paper v1], count, truncated, totalResults?}` + короткий текст |
| `get_paper` | `arxivId` (проверенный, с версией или без) | `structuredContent` — сам Paper v1 + короткий текст |

- `search_query` собирается из свободного текста: `all:<term>` на каждый
  токен, соединённые ` AND `; `category` добавляется как `cat:<category>`;
  `submittedAfter` — как `submittedDate:[YYYYMMDDHHMM TO 999912312359]` в UTC
  (документированная грамматика, минуты, GMT). Спецсимволы (`:`, кавычки,
  скобки, Boolean-операторы) в `query` отбрасываются токенизацией, поэтому
  модель не может переписать грамматику запроса.
- Пейджинг ограничен: `start=0`, `max_results=limit`; `get_paper` использует
  рекомендованный `id_list` (с `vN` для конкретной версии), `max_results=1`.
- `sortBy` — только `relevance`, `lastUpdatedDate`, `submittedDate`;
  `sortOrder=descending`. Повторяемый порядок: relevance сохраняет порядок API,
  даты сортируются по убыванию с тай-брейком по arXiv ID.
- Дедупликация по базовому ID: остаётся старшая версия, затем более поздний
  `updatedAt`; первый по порядку API представитель сохраняет позицию.
- Даты нормализуются в UTC, `abstractUrl` всегда строится из проверенного ID,
  PDF-ссылки не запрашиваются и не возвращаются.

## Защита, лимиты и кэш

- Инъектируемый `ArxivHttpAdapter`; `HttpArxivHttpAdapter` читает тело
  потоково и отвергает > `maxResponseBytes` (2 МиБ), не следует редиректам,
  отвергает не-UTF-8.
- Парсер отвергает не-XML, несовпадающие *полные* имена тегов (включая
  namespace-префиксы), DOCTYPE/неизвестные сущности, XML-нелегальные code
  points в тексте/CDATA/атрибутах (не только в числовых сущностях),
  > 100 записей, > 2 млн символов текста, длинные
  заголовки/аннотации/имена/категории. Сырой текст ответа никогда не попадает
  в результат и логи; из ошибочной Atom-ленты API извлекается только
  санитизированный код вида `incorrect_id_format_for`.
- Вход дополнительно проверяется в клиенте и схемой MCP: пустой/слишком
  длинный/слишком сложный запрос, неверная категория, `limit` вне 1–30,
  ID-URL или мусор отклоняются до сети; `additionalProperties: false`.
- Тайм-аут 15 с на всю операцию и на HTTP-адаптер; `Rate limiter`: запросы
  сериализованы (не более одного в полёте) и разнесены минимум на 3 с;
  `Retry-After` (секунды или HTTP-дата) отсчитывается от момента получения
  ответа, а не от начала запроса, и сдвигает следующий запрос не более чем на
  24 ч.
- Кэш — LRU на 32 записи с TTL 10 минут по канонизированному ключу запроса;
  попадание не расходует лимит частоты. Результат истёкшей попытки не
  публикуется в кэше.
- Тайм-аут очереди помечает попытку истёкшей: если запрос ждал за чужим
  запросом и вызывающий уже получил timeout, действие не отправляет запрос в
  arXiv вообще (`_LoadAttempt`). Та же проверка повторяется в `_fetch` сразу
  после ожидания rate/backoff-гейта, до `_lastRequestAt` и до `_http.get`:
  длинный `Retry-After` не превращается в поздний запрос после истечения
  вызывающего.
- Deadline HTTP-запроса управляет `Abortable.abortTrigger` (`package:http`
  1.6): по истечении тайм-аута запрос действительно прерывается, и адаптер
  ждёт подтверждённого завершения транспорта, прежде чем сообщить timeout и
  отпустить очередь. Для инъектированного клиента, который игнорирует
  `abortTrigger`, ожидание ограничено `settleTimeout` (по умолчанию 5 с):
  timeout сообщается, но физическое завершение соединения не подтверждается —
  гарантия «одно соединение» после тайм-аута относится только к клиентам,
  поддерживающим abort. Логическая очередь в любом случае не отправляет
  истёкшие вызовы.
- Отмена MCP-клиента проверяется до и после вызова; уже начатый HTTP-запрос
  прерывается тем же deadline-механизмом, а не ждёт бесконечно.

## Ошибки: домен, сеть и протокол различимы

Все ошибки инструмента — `CallToolResult(isError: true)` с префиксом
`[arxiv:<kind>]` в тексте; `structuredContent` у ошибок нет, поэтому
outputSchema B2 проверяет только успешные результаты.

| kind | Значение |
|---|---|
| `invalid_input` | отказ до сети: аргументы, ID, отвергнутый API-запрос |
| `not_found` | статьи или версии нет в arXiv |
| `rate_limited` | 429 или «слишком часто»; несёт `Retry-After` |
| `network` | 5xx, обрыв соединения, клиентская ошибка HTTP |
| `timeout` | истёк тайм-аут запроса или очереди |
| `protocol` | битый/огромный/не-UTF-8 ответ, нарушение Atom-структуры |
| `cancelled` | MCP-клиент отменил вызов |

## Проверки

```sh
dart format .
flutter analyze
flutter test test/infrastructure/mcp/servers/arxiv
ARXIV_LIVE_SMOKE=1 flutter test \
  test/infrastructure/mcp/servers/arxiv/arxiv_live_smoke_test.dart
```

54 герметичных теста покрывают: обычный поиск и `get_paper`, построение и
экранирование запроса, пейджинг/`limit`/`truncated`, пустую ленту,
дубликаты версий, сортировки, битый XML и поля, несовпадающие полные имена
тегов, XML-нелегальные code points в тексте/CDATA/атрибутах и валидную
namespaced-ленту с supplementary-символами, ленту ошибки API, лимиты
размера, 429/5xx, тайм-аут, истечение очереди без отправки запроса,
истечение во время длинного `Retry-After` без позднего запроса,
сериализацию и разнос запросов ≥ 3 с, `Retry-After` от момента ответа,
попадание и границы кэша, схемы и результаты обоих tools (включая проверку
`outputSchema` валидатором B2), поведение HTTP-адаптера: лимит тела, UTF-8,
редиректы, сетевые ошибки, abort транспорта по deadline, ожидание
settlement и ограниченное ожидание для клиентов без abort.

Живой smoke (один прогон, два запроса с паузой):

```text
live smoke: search=2 totalResults=71758 first=2211.02350v1
  "Tierkreis: A Dataflow Framework for Hybrid Quantum-Classical Computing"
```

## Пределы источника и координация устройств

- Legacy arXiv API по [условиям использования](https://info.arxiv.org/help/api/tou.html):
  не более одного запроса каждые 3 секунды и одно соединение одновременно
  **для всех машин под контролем пользователя**. Domovoy не имеет
  межмашинной синхронизации: ПК и телефон, запущенные одновременно, каждый
  соблюдают свои 3 с и один запрос, но вместе могут превысить общий лимит.
  Документация не заявляет глобально гарантированного лимита; снижают риск
  кэш (TTL 10 минут) и то, что повторный поиск не обращается к сети.
- Официальный API отдаёт только описательные метаданные (название, авторы,
  аннотация, категории, даты, ссылки). Хранить и преобразовывать их можно;
  PDF не скачиваются, полный текст не индексируется, перепубликация не
  выполняется.
- Релевантность задаёт внутренний поиск arXiv, поэтому порядок relevance
  зависит от API; даты сортируются локально детерминированно.
- Поле `submittedAfter` — единственный документированный фильтр дат; верхняя
  граница запроса фиксирована (`999912312359`), отдельного `submittedBefore`
  в контракте B3 нет.
- Свободный текст не поддерживает сложную грамматику arXiv (поля, Boolean,
  фразы): это осознанное ограничение безопасности и повторяемости; для
  грамматики достаточно `category` и документированного `sortBy`.

## Правки после ревью раунда 1

- **Истёкшая очередь.** `_load` помечает попытку (`_LoadAttempt`) истёкшей в
  `Future.timeout(onTimeout:)`; сериализованное действие проверяет метку до
  второго чтения кэша, до сети и до публикации результата. Раньше второй
  вызов, чей вызывающий уже получил timeout, всё равно уходил в arXiv после
  освобождения очереди. Регрессия: «a call that times out in the queue never
  reaches the adapter» (до фикса адаптер получал 2 запроса, после — 1).
- **Retry-After.** Гейт `_notBefore` теперь отсчитывается от
  `_clock.nowUtc()` в момент обработки ответа, а не от старта запроса;
  обычный разнос ≥ 3 с сохранён. Регрессия: «Retry-After is anchored to the
  response, not the request start» (до фикса задержка ответа 5 с и
  Retry-After 10 с давала паузу 10 с вместо 15 с).
- **XML.** Закрывающий тег сравнивается с полным (с namespace-префиксом)
  именем открывающего, а весь документ проходит проверку XML 1.0 code points
  до токенизации: U+0001 в тексте/CDATA/атрибуте и lone surrogate теперь дают
  protocol-ошибку, валидные namespaced-ленты и surrogate pairs принимаются.
  Регрессии: «rejects mismatched qualified closing tags», «rejects
  XML-illegal code points in text, CDATA and attributes», «parses a valid
  namespaced Atom feed with supplementary text».
- **Тайм-аут транспорта.** `HttpArxivHttpAdapter` отправляет
  `AbortableRequest` с `abortTrigger`; deadline прерывает запрос, а адаптер
  ждёт подтверждённого settlement (или `settleTimeout` для клиентов без
  abort) и только потом сообщает timeout, поэтому очередь не освобождается при
  живом сокете. Регрессии: «aborts an abortable transport at the deadline and
  waits for it», «waits for a transport that ignores abort to settle before
  timing out», «does not block forever when the transport never settles».
  Честное ограничение: физическая гарантия «одно соединение после тайм-аута»
  действует для клиентов, поддерживающих `abortTrigger` (дефолтные
  `IOClient`/`BrowserClient` из `package:http` 1.6); для игнорирующего клиента
  подтверждается только логическая очередь, а `settleTimeout` ограничивает
  ожидание.

## Правки после ревью раунда 2

- **Поздний запрос после длинного гейта.** `_load` передаёт попытку
  (`_LoadAttempt`) в `_fetch`, и `_fetch` перепроверяет её сразу после
  `await _waitForTurn()`, до записи `_lastRequestAt` и до `_http.get`. Раньше
  вызов, чей вызывающий уже получил timeout, продолжал ждать в
  `Retry-After: 60`, а затем всё равно отправлял запрос в arXiv. Регрессия:
  «a call expired during a long rate-limit wait never sends a late request» —
  fake-clock с блокируемым `sleep`: после 429 с `Retry-After: 60` второй
  вызов истекает по реальному тайм-ауту, release сна не добавляет запрос в
  адаптер (до фикса добавлял), а свежий вызов после backoff проходит и не
  расходует лишний 3-секундный интервал. Физический settlement транспорта и
  квалифицированные XML-имена из раунда 1 сохранены.
