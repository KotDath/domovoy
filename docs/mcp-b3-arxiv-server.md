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
- Парсер отвергает не-XML, несовпадающие теги, DOCTYPE/неизвестные сущности,
  управляющие символы, > 100 записей, > 2 млн символов текста, длинные
  заголовки/аннотации/имена/категории. Сырой текст ответа никогда не попадает
  в результат и логи; из ошибочной Atom-ленты API извлекается только
  санитизированный код вида `incorrect_id_format_for`.
- Вход дополнительно проверяется в клиенте и схемой MCP: пустой/слишком
  длинный/слишком сложный запрос, неверная категория, `limit` вне 1–30,
  ID-URL или мусор отклоняются до сети; `additionalProperties: false`.
- Тайм-аут 15 с на всю операцию и на HTTP-адаптер; `Rate limiter`: запросы
  сериализованы (не более одного в полёте) и разнесены минимум на 3 с;
  `Retry-After` (секунды или HTTP-дата) сдвигает следующий запрос, но не более
  чем на 24 ч.
- Кэш — LRU на 32 записи с TTL 10 минут по канонизированному ключу запроса;
  попадание не расходует лимит частоты.
- Отмена MCP-клиента проверяется до и после вызова: отменённый запрос не
  возвращает данные, но уже начатый HTTP-запрос доигрывает до собственного
  тайм-аута, потому что `package:http` не умеет прерывать сокет; до этого
  момента слот «одно соединение» занят.

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

45 герметичных тестов покрывают: обычный поиск и `get_paper`, построение и
экранирование запроса, пейджинг/`limit`/`truncated`, пустую ленту,
дубликаты версий, сортировки, битый XML и поля, ленту ошибки API, лимиты
размера, 429/5xx, тайм-аут, сериализацию и разнос запросов ≥ 3 с,
`Retry-After`, попадание и границы кэша, схемы и результаты обоих tools
(включая проверку `outputSchema` валидатором B2), поведение HTTP-адаптера.

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
