# B5: локальный MCP-сервер library и JSONL-библиотека — результат

Статус: реализация B5 завершена, `dart format`, `flutter analyze` и
`flutter test` зелёные. Область: доменные типы библиотеки в
`lib/core/research`, сервер в `lib/infrastructure/mcp/servers/library/` и
зеркальные тесты `test/core/research/library_test.dart`,
`test/infrastructure/mcp/servers/library/`. `lib/app.dart`, другие серверы,
планировщик, UI, `pubspec.yaml` и существующие JSONL-хранилища не менялись.

## Что добавлено

| Файл | Содержимое |
|---|---|
| `core/research/library_errors.dart` | `LibraryErrorKind`/`LibraryError`/`LibraryException` |
| `core/research/library.dart` | `LibraryId`, `LibraryRecord`, `LibraryCard`, `LibraryRecordCodec`, канонический fingerprint, порядок сортировки |
| `core/research/library_repository.dart` | `LibraryRepository`, `LibraryPage`, `LibrarySaveResult`, `LibraryPageCursor`, `normalizeLibraryQuery` |
| `infrastructure/mcp/servers/library/library_failure.dart` | `LibraryFailureKind`/`LibraryFailure` и стабильный префикс `[library:<kind>]` |
| `infrastructure/mcp/servers/library/library_limits.dart` | `LibraryLimits` и производные `JsonlStorageLimits` |
| `infrastructure/mcp/servers/library/library_envelope.dart` | версионированный конверт JSONL `domovoy.library_record_operation` v1 |
| `infrastructure/mcp/servers/library/library_replay.dart` | replay одного потока записи: последовательность, ревизии, усечённый хвост |
| `infrastructure/mcp/servers/library/library_jsonl_store.dart` | `JsonlLibraryStore implements LibraryRepository`, часы и генератор идентификаторов |
| `infrastructure/mcp/servers/library/library_storage_factory*.dart` | условная фабрика хранилища IO/web/stub |
| `infrastructure/mcp/servers/library/library_storage_namespace.dart` | имя namespace `library-jsonl-v1` |
| `infrastructure/mcp/servers/library/library_mcp_server.dart` | `LibraryMcpServerFactory implements LocalMcpServerFactory` с тремя инструментами |
| `infrastructure/mcp/servers/library/library.dart` | публичный экспорт B5 для B9 |

## Контракт фабрики для B9

```dart
final storage = createPlatformLibraryJsonlStreamStorage();
if (storage != null) {
  final library = LibraryMcpServerFactory(storage: storage);
  localHost.register(library);
  await localHost.start('library'); // serverId стабилен: 'library'
}
// repository доступен для диагностики и композиционных тестов:
// library.repository
```

`serverId` — `library`, версия `1.0.0`, displayName `Library`. Фабрика
создаёт единственный `JsonlLibraryStore` приложения; второй копии библиотеки
нет ни в UI, ни в композиции. На платформах без нативного атомарного
хранилища (web, неизвестная цель) фабрика возвращает `null`, и B9 не
регистрирует сервер — вместо выдуманного файлового пути. Тестовые и
альтернативные композиции используют
`LibraryMcpServerFactory.withRepository(repository: ...)`.

## Инструменты и провод

| Tool | Вход | Успешный результат |
|---|---|---|
| `save_digest` | `digest` — Digest v1, `papers` — 1–10 полных Paper v1, `topic`, необязательный `runId` | `structuredContent`: `libraryId`, `savedAt`, `topic`, `paperCount`, `itemCount`, `created`, `recordRef`, `runId?` + короткий текст |
| `list_saved` | необязательные `query`, `limit` (1–50, по умолчанию 20), `cursor` | `records` — карточки, `nextCursor?`, `totalCount` + короткий текст |
| `get_saved` | `libraryId` | полная `LibraryRecord`: тема, снимки Paper v1, Digest v1, `savedAt`, `revision` |

- Входные и выходные схемы строго типизированы, `additionalProperties: false`
  у всех объектов; обе схемы проходят профили B2
  (`openaiChatCompletions`, `openaiResponses`, `portable`) и проверяются
  валидатором B2 на реальных результатах. Объявленный `outputSchema` требует
  `structuredContent` на успехе — сервер его всегда возвращает.
- `save_digest` проверяет версии схем: Digest/Paper v2 дают явный
  `[library:version_mismatch]` вместо частичного сохранения. Чтобы эта ошибка
  приходила именно от сервера, входная схема объявляет `schemaVersion` как
  `integer(minimum: 1)`, а точную версию проверяет домен; выходные схемы
  закрепляют ровно v1.
- Каждый пункт `Digest.items` обязан ссылаться на переданный Paper
  (`verifyDigestItemsBelongToPapers` из B1); чужой arXiv ID, дубликат статьи,
  несовпадение `topic` и `digest.topic` — `[library:invalid_input]`.
- Неизвестные поля на любом уровне (включая `pdfUrl`) не сохраняются:
  дополнительные ключи отклоняет схема SDK, а сервер дублирует строгую
  проверку ключей как defense in depth. PDF-байты, ссылки на файловую систему
  и секреты в записи не попадают.
- `list_saved` и `get_saved` — read API библиотеки для UI: B8 читает те же
  данные через MCP, отдельного хранилища в приложении нет.

## Идемпотентность `runId` и конфликт

- Fingerprint payload — канонический: `topic` + снимок статей **как
  множество** (порядок не важен) + полный Digest v1 (порядок пунктов
  сохраняется, потому что это и есть сохранённый payload).
- Повтор `save_digest` с тем же `runId` и тем же payload возвращает ту же
  запись с `created: false`, без второй записи в JSONL. Это защищает день 19
  от дубликата после сбоя на шаге сохранения.
- Повтор с тем же `runId`, но другим `topic`, другим снимком статей или другим
  Digest — явный `[library:conflict]`: старая запись не подменяется и не
  выдаётся за сохранение нового payload.
- Без `runId` каждый ручной вызов получает новый `libraryId`
  (16 случайных байт), поэтому две одинаковые ручные подборки — две записи.

## JSONL: модель и хранение

- Namespace: `ru.kotdath.domovoy/library-jsonl-v1` в application support
  каталоге устройства, через существующий `JsonlFilesystemStreamStorage`
  (атомарная генерация + манифест `active`). Никакого ad hoc API пути: сервер
  не импортирует `dart:io`, `path_provider` есть только в IO-фабрике.
- Одна запись — один поток, ключ потока равен `libraryId`. Конверт
  `domovoy.library_record_operation` v1: `libraryId`, `sequence`,
  `operation` (`upsert`), `expectedRevision`, `recordRevision`, `record`.
  Replay проверяет последовательность, ревизии, идентичность записи и версию
  конверта.
- Усечённый хвост (неполная последняя строка) не теряет запись: replay
  возвращает полный префикс и `needsRepair`, а фрагмент отбрасывается при
  следующей публикации этого потока. Полностью нечитаемая запись, чужой ключ
  потока или неизвестная версия записи — `[library:corruption]`: список и
  чтение падают целиком, без частично принятых данных.
- Ошибки самого хранилища (не читается список ключей, не прошла публикация) —
  отдельный `[library:persistence]`, чтобы UI отличал сбой носителя от
  повреждённого содержимого.

## Пагинация и поиск

- Порядок: `savedAt` по убыванию, при равенстве — `libraryId` по убыванию.
- Курсор — keyset: `(savedAt, libraryId)` последней карточки страницы плюс
  нормализованный `query`, в base64url. Вставка новых записей между страницами
  не сдвигает и не пропускает старую страницу (регрессия: «A newer record
  inserted between the pages must not shift page two»). Offset не
  используется.
- Курсор от другого запроса или повреждённый курсор — явный
  `[library:invalid_input]`, а не смешивание двух выдач.
- Поиск без учёта регистра по теме, обзору, названиям/авторам/ID статей и
  `runId`. `totalCount` — живой счётчик совпадений до пагинации, страница при
  этом остаётся стабильной.

## Лимиты

| Измерение | Значение по умолчанию |
|---|---|
| Статей на запись | 1–10 |
| Байт на снимок Paper / все снимки | 16 КиБ / 64 КиБ |
| Байт Digest | 64 КиБ |
| Байт записи / потока JSONL | 256 КиБ / 512 КиБ |
| Тема / runId / query / cursor | 500 / 128 / 200 / 1024 символов |
| Страница `list_saved` | 1–50, по умолчанию 20 |

`LibraryLimits.validate` отвергает несогласованную конфигурацию (например,
`minPapers > maxPapers` или поток меньше записи с конвертом) до старта
сервера. Схемы используют те же значения, поэтому schema-ограничение и
серверная проверка остаются согласованными; агрегатные лимиты (сумма статей,
байты Digest, байты записи), которые схема выразить не может, проверяются
сервером и хранилищем.

## Ошибки

Все ожидаемые ошибки — `CallToolResult(isError: true)` с префиксом
`[library:<kind>]`; `structuredContent` у ошибок нет, поэтому outputSchema
проверяет только успешные результаты.

| kind | Значение |
|---|---|
| `invalid_input` | аргументы, версии, лимиты, чужой ID, конфликтующая тема, курсор |
| `not_found` | неизвестный `libraryId` в `get_saved` |
| `conflict` | повтор `runId` с другим payload |
| `version_mismatch` | Digest/Paper не v1 на входе |
| `corruption` | нечитаемая запись или чужой поток в namespace |
| `persistence` | сбой носителя: список ключей или публикация |
| `cancelled` | MCP-клиент отменил вызов |
| `internal` | непредвиденная ошибка; запись не изменена |

## Проверки

```sh
dart format .
flutter analyze
flutter test test/core/research/library_test.dart \
  test/infrastructure/mcp/servers/library
```

74 герметичных теста в новых файлах: сохранение и replay после перезапуска
(включая реальный файловый `JsonlFilesystemStreamStorage` с temp-каталогом),
идемпотентный `runId` и отсутствие второй записи, идемпотентность `runId`
после перезапуска хранилища, конфликт по теме, снимку статей и Digest,
отдельные ручные сохранения, keyset-пагинация со вставкой между страницами,
поиск, `get_saved`, повреждение/усечённый хвост/чужой ключ потока,
неизвестная версия записи, неизвестная версия входных схем, чужой arXiv ID,
дубликат статьи, несовпадение темы, неизвестные поля, агрегатные и
поэлементные лимиты, `[library:persistence]`, отмена,
`structuredContent`/`isError`, схемы всех трёх инструментов на профилях B2,
отсутствие PDF/секретов в сыром JSONL и статическая изоляция от других
серверов, HTTP, файловой системы и хранилищ секретов.

## Ограничения и заметки

- **Поиск существующего `runId` — линейный.** `save_digest` с `runId`
  перечитывает записи namespace, чтобы найти совпадение; для личной
  библиотеки это допустимо и не требует индекса, который мог бы разойтись с
  основным потоком. Индекс можно добавить позже как производную структуру с
  перестройкой через replay.
- **`list_saved` читает все потоки.** Стоимость ограничена лимитами записи и
  потока; keyset-курсор не превращает выдачу в mutable offset.
- **`totalCount` живой.** Он отражает текущее число совпадений, а не снимок
  первой страницы; содержимое уже начатой пагинации при этом стабильно.
- **Неизвестная версия сохранённой записи даёт `corruption`**, а не
  `version_mismatch`: до появления миграции такие данные честно считаются
  нечитаемыми (fail closed), а не частично принимаются. Версии входных
  payload-ов различаются явно.
- **Усечённый хвост не переписывается автоматически.** Replay возвращает
  полный префикс и флаг `needsRepair`; в v1 записи иммутабельны, поэтому
  починка происходит при следующей публикации этого потока (например, при
  появлении ревизий). Данные записи при этом не теряются.
- **Чтение терпимо к лишним полям внутри сохранённого Paper.** Записывающая
  сторона строгая (лишние поля отклоняются до сохранения), читающая сторона
  не перепубликует прочитанное, поэтому скрытого попадания PDF/секретов в
  новые записи нет.
- **Одна копия библиотеки на устройство.** Синхронизации ПК↔телефон нет;
  web/неизвестные платформы получают `null`-хранилище и не поднимают сервер.
- Живой сквозной сценарий `arxiv → digest → library` и просмотр через UI — за
  B9/B8; здесь проверены контракт, хранилище и герметичные вызовы MCP.
