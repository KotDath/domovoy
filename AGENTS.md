# AGENTS.md — инструкции для ИИ-ассистентов

Контракт для любого ИИ-ассистента, работающего с этим репозиторием.
Прочитайте перед любыми изменениями.

## Цель проекта

Domovoy — персональный ИИ-ассистент в виде Flutter-приложения: рабочее
пространство чата с LLM (провайдеры DeepSeek/OpenRouter), стриминг ответа и
reasoning, проекты и настройки API-ключа.

## Инварианты

1. **Один Flutter-пакет `domovoy`.** Никаких вложенных `pubspec.yaml`,
   подпакетов или внешних менеджеров воркспейса. Все зависимости — в корневом
   `pubspec.yaml`.
2. **Идентификатор приложения — `ru.kotdath.domovoy`** на всех платформах:
   `namespace`/`applicationId` в Android, `PRODUCT_BUNDLE_IDENTIFIER` в
   iOS/macOS, `APPLICATION_ID` в Linux, company/namespace в Windows. Не
   переименовывать.
3. **Слои и направление зависимостей:** `presentation → application → domain`,
   `infrastructure` реализует контракты из `core`. Обратные зависимости
   запрещены.
4. **Состояние — `ChangeNotifier` и явная композиция в `lib/app.dart`.**
   Внешних state-management/DI-пакетов нет; не добавлять.
5. **Домен — в `lib/core/`** (`llm/`, `agents/`, `projects/`, `environment/`),
   платформенные адаптеры — в `lib/infrastructure/`, UI — в
   `lib/features/<feature>/{domain,application,presentation}/`, тема и
   компоненты — в `lib/design_system/`.
6. **Платформенный код — через conditional imports** (`*_io.dart`, `*_web.dart`,
   `*_stub.dart`). `dart:io` в кросс-платформенных файлах не использовать.
7. **Секреты — только через `flutter_secure_storage`** (override из настроек)
   или переменную окружения `DEEPSEEK_API_KEY`. Ключи в коде и в репозитории
   запрещены; `.env` в `.gitignore`.
8. **Персистентность — JSONL** (сессии агентов и проекты). Формат менять
   только вместе с миграцией/реплеем.
9. **Линты — `package:flutter_lints/flutter.yaml`.** Не ослаблять правила в
   `analysis_options.yaml` без причины.
10. **Тесты — в `test/`** зеркально структуре `lib/`; общие фейки и харнессы —
    в `test/support/`.
11. **Сообщения коммитов — Conventional Commits** (`feat(chat): ...`).
12. **Секреты, платформенные манифесты и `build/` не коммитить.**

## Структура

- `lib/core/` — домен.
- `lib/infrastructure/` — LLM-провайдеры, JSONL-хранилища, credential-store,
  файловые системы, provisioners.
- `lib/features/` — фичи: `chat`, `projects`, `prompt`, `settings`.
- `lib/design_system/` — тема, токены, компоненты.
- `test/`, `test/support/` — тесты и фейки.
- `assets/models_fallback.json` — фолбэк-каталог моделей.
- `design/` — макеты (read-only референс).

## Стек

- Flutter / Dart, SDK `^3.10.0`.
- Зависимости: `flutter_secure_storage`, `file_selector`, `http`, `path`,
  `path_provider`, `shared_preferences`.
- LLM: OpenAI-совместимый `/chat/completions` (DeepSeek, OpenRouter).
- Linux-десктопу нужен `libsecret` (см. `README.md`).

## Форматирование, анализ, тесты

Запускать из корня репозитория:

```sh
flutter pub get
dart format .
flutter analyze
flutter test
```

Перед завершением задачи код обязан быть отформатирован, а `flutter analyze`
и `flutter test` — проходить без ошибок.

## Запуск

```sh
flutter run -d linux
```

## Типичный цикл изменения

1. Понять требуемое поведение и границы слоя.
2. Внести изменение в `core`/`infrastructure`/`features`, не нарушая
   инварианты выше.
3. `dart format .`
4. `flutter analyze && flutter test`
5. Коммит в стиле Conventional Commits.
