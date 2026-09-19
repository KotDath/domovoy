# Domovoy redesign · planned / waiting Project dependency

## Текущая карточка участка · 19 сентября 2026

- **scope_id:** `redesign-workspace-shell-plan-01`
- **attempt_id:** `1`
- **stage:** `planned/waiting_dependency`
- **change:** `redesign-workspace-shell`
- **ближайший результат:** после принятия `add-project-workspaces` перевести
  реальные Project → Chats и `Без проекта` данные в утверждённую композицию
  `final-01`; временный flat/decorative production shell запрещён.
- **base_revision:** `635c53abf571860fc8211e1b6569039eb94db6d0`
- **стартовый diff текущего planning continuation:** уже утверждённые untracked
  `.opencode/workflow/feature-state/redesign-workspace-shell.md`, `design/` и
  `openspec/changes/redesign-workspace-shell/`; сохранить. Текущий diff также
  добавляет только planning-артефакты `add-project-workspaces` и его state.
- **contract_revision:** `proposal 872dff03…e99f`,
  `design 2d0e0df2…fb80`, `spec 32c17af1…ab7c`,
  `tasks 1e54992a…695c` (полные SHA-256 ниже).
- **rework_count:** `0`.
- **gates:** `final-01` **RESOLVED / APPROVED**; повторный design approval не
  нужен. Реализация shell явно запрещена до `accepted` у
  `add-project-workspaces`. После принятия зависимости отдельное перепланирование
  не нужно, если её опубликованный Project-facing контракт не изменился.

## OpenSpec contract, tasks и AC

- Change: `openspec/changes/redesign-workspace-shell/`; четыре planning artifact
  complete. Зависимость записана в proposal/design/spec/tasks.
- `1.1–1.3`: bounded Markdown, semantic tokens, System/Dark/Light.
- `2.1–2.4`: `final-01`, реальные Project-группы и `Без проекта`, truthful
  root/access status, prose timeline — только поверх accepted dependency.
- `3.1–3.3`: ephemeral monotonic run duration; `4.1–4.5`: truthful context и
  upward model/reasoning selectors; `5.1–5.2`: provider settings без secrets.
- `6.1–6.4`: Project/chat regressions, ровно четыре goldens, checks/evidence и
  stop boundary; `AC-01…AC-09` — visual/responsive/existing flows/truthfulness,
  Markdown safety, duration, context/selectors, theme и path/check evidence.

## Зафиксированные решения

- Shell не создаёт второй Project authority: отображает accepted Project
  projection/commands, членство не выводит из title/provider/path.
- Project add использует capability-gated flow зависимости; unsupported остаётся
  disabled. Header показывает real Project + safe root/access label либо
  `Без проекта` / `—`, но не sample path и не opaque grant.
- Markdown: direct `flutter_markdown`, только bounded assistant syntax; HTML/
  images/outbound actions запрещены. Duration: monotonic, run-bound, ephemeral.
- Model picker: upward provider→models с explicit activation/search/lazy lists;
  reasoning отдельно и только из capability. Theme default System, override
  process-local. Context — provider-reported input + declared model bound, иначе
  `—`; без estimator/files/instructions/project/pricing categories.
- Provider settings сохраняют текущие store/discovery operations; secrets не
  prefill/display и fake health не появляется.

## Scope, пути и non-goals

- Expected paths: `design.md §8` — `pubspec.*`, `lib/app.dart`, design-system,
  chat application/presentation, только Project presentation mapping,
  provider-settings presentation, соответствующие tests и ровно четыре
  `test/goldens/chat_workspace/*.png`.
- Запрещены изменения `lib/core/**`, Project/session persistence/schema,
  Project application commands, grants/path policy, platform/native, provider
  protocol, `design/redesign-preview/**`, `add-project-workspaces/**` и
  `add-provider-discovery-and-api-usage/**`.
- Вне scope: filesystem tools/I/O, attachments, runtime context composition,
  global usage/pricing, persisted duration/theme, outbound links.

## Сложность, tier и execution

- **preliminary/refined complexity:** `medium / medium`; Project foundation теперь
  dependency, а shell остаётся presentation-heavy с проверяемыми widget/golden AC.
- **initial_tier:** `T1`; **current_tier:** `T2` только для timer ↔ terminal/
  cancellation/stale-run lifecycle, не для Project persistence/permissions.
- **recommended_mode / execution_mode:** `light / light`.
- **rationale / selection_source:** явный прежний выбор пользователя; DeepSeek
  writer, затем параллельно Sol reviewer + отдельный DeepSeek verifier. Запрошенный
  GPT-6 Astra low visual review идёт дополнительно по зафиксированным goldens.
- Если accepted Project contract существенно изменит сложность shell, координатор
  получает причину и новую рекомендацию; режим не переключается молча.

## Проверки и зависимости

- `.opencode/bin/repo-openspec validate redesign-workspace-shell --strict`:
  exit 0, `Change 'redesign-workspace-shell' is valid` после dependency update.
- `.opencode/bin/repo-git diff --check`: exit 0. Approved preview SHA-256
  перепроверены и совпадают с evidence ниже. Flutter не запускался: product/test/
  dependency/platform code не менялся.
- **blocking dependency:** `add-project-workspaces` coder-ready: platform matrix
  выбрана, для него отдельно выбран Light и зафиксированы его модели. Shell всё
  ещё ждёт implementation/verification/acceptance зависимости; собственный
  Light/model route shell не изменён.
- **preserved dependency:** accepted unarchived
  `add-provider-discovery-and-api-usage` неизменён; сохранить sync/archive order.
- **blocker:** только acceptance `add-project-workspaces`; не блокирует независимые
  участки проекта и не разрешает начинать shell частично.

## Полные SHA-256 OpenSpec planning artifacts

```text
872dff03201995890cbcf3912d0dc43324298783fb382531356717588290e99f  proposal.md
2d0e0df2113b37b833c7b18cae65df270ec8749e17de603eb38868c5431cfb80  design.md
32c17af16b467cd72a23c60ea624acaea556f2ec57c73300d63f4aa9cdab7cb8  specs/chat-workspace-ui/spec.md
1e54992ac610a8b59b2abf7c68715aaa0cd6b0831078f7d7619821bc1254695c  tasks.md
```

## Принятый дизайн · evidence сохранён ниже

## Исторический статус принятия дизайна · 19 сентября 2026

- **accepted_design / final-01** — пользователь одобрил v05a и поручил
  дизайнерскую полировку с фиксацией финального макета для реализации.
- Основание: «в целом мне вот эта версия очень нравится. Я бы её одобрил»;
  затем «найди ... скилл дизайнера ... подштрихуй ... макет финальный».
- Полировка выполнена в разрешённом объёме; повторное дизайн-approval не требуется
  для этих мелких правок. Основная композиция и взаимодействия сохранены.
- Финальный источник: `design/redesign-preview/{index.html,style.css,app.js}`.
  Решения, токены и границы реализации собраны в `design/redesign-preview/README.md`.
- Preview: http://localhost:8765/?v=final-01; существующая Orca-вкладка
  f09092b8-7a8f-4e6f-a574-a38f251ec464 обновлена, default theme System восстановлен.
- **HTML implemented / browser checks pass / design accepted**.
  **Flutter implementation not started**. OpenSpec, Flutter, tests,
  зависимости и platform-файлы не менялись. Субагенты не создавались.
- Следующий этап — отдельное OpenSpec-планирование и Light-реализация по
  утверждённому макету. Этот файл не объявляет product CHECKS_PASS.

## Финальная дизайнерская полировка

Использован find-skills; локального frontend-design не обнаружено.
Прочитан официальный https://github.com/anthropics/skills/blob/main/skills/frontend-design/SKILL.md
(локальная копия /tmp/domovoy-frontend-design-SKILL.md), без глобальной установки.
План полировки: сохранить graphite/warm-neutral/periwinkle tokens, системный
sans-serif и левое выравнивание; composer и лента одной ширины; никаких новых
декоративных блоков. Согласованное направление имеет приоритет над советами скилла.

Выполнено: совпадение краёв composer/ленты, outline utility-иконки, чуть более
читаемые подписи, focus для disclosure/popover, active settings, aria-current
чата. Упрощены заголовки settings/project. Concept badge заменён на
«Финальный макет · демонстрационные данные», поскольку дизайн принят.

## Финальная проверка / evidence

- node --check design/redesign-preview/app.js: exit 0.
- /tmp/orca-final.py: exit 0. Orca dark/light, model/context/providers/project;
  iframe 390×844: нет horizontal overflow, context/model/reasoning/project
  внутри viewport. Скриншоты /tmp/preview-final-*.png.
- Лично просмотрены dark context/providers/project, light model и narrow model.
- Дополнительный Orca eval 9a57b802-d42e-48e5-bd24-942b1d98c278:
  model selection, reasoning selection, создание проекта + чата, folder focus,
  DOM Escape + возврат фокуса, unknown context — все true.
- Физический Escape через Orca не перепроверялся; проверен DOM handler.
- repo-git diff --check: exit 0; файлы untracked, потому версия фиксируется SHA.
- Это HTML/browser QA, не полный accessibility audit и не Flutter verification.
- Markdown renderer и runtime permissions/context data остаются вопросами
  технического планирования, не незакрытым визуальным approval.

## SHA-256 финальных файлов

```text
9eb1afc301d4809c16e29c243578587aef3f3bf94b0afd6f1deebe4efff590a8  index.html
0de7953d2bb382aab5c70f1fee9b777f8e25e28b01db218eb774092abfb2775d  style.css
8775e4dbcf22d94e338afc3b48471c8622bddf108cfcf612cda7b9d3c8911f69  app.js
0794860a6dc62ff5c2bceb1f7dda3f336494222cc72251086af0fbb3610825f9  README.md
```

## История итераций (статусы ниже исторические)

# Domovoy redesign · визуальное исследование

- scope_id: redesign-preview-D0
- attempt_id: 1
- stage: accepted_design
- change: none; design accepted, implementation planning is next
- initial_tier/current_tier: T1 / T1, design-only
- execution_mode: design-prototype (не implementation light/heavy)
- rework_count: 0
- model: GPT-6 Astra; настройка effort изнутри сессии не подтверждена.
- base_revision: 635c53abf571860fc8211e1b6569039eb94db6d0
- Стартовый diff: чисто; `repo-git status --short` не вывел изменений.
- Gate: требуется явное утверждение пользователем финального дизайна. До этого
  не менять Flutter/OpenSpec и не заявлять о реализации продуктового поведения.
- Scope: `design/redesign-preview/**` и этот process-файл. Другие пути не менялись.

## Выполненный участок / AC

- [x] Локальный статический пакет: index.html, style.css, app.js, README.md.
- [x] Чат с meaningful sample, тёмная/светлая/системная тема (default system).
- [x] Вложенные Project → Chats и «Без проекта»; навигация и сворачивание групп.
- [x] Provider split-view, демонстрационные статусы и модели, без значений ключей.
- [x] Model picker с группировкой и поиском, отдельный reasoning selector.
- [x] Состав контекста: used/limit, категории, estimated/reported/unknown semantics.
- [x] Проект: имя, пример корня, дополнительные read-only папки; доступ не выдан.
- [x] Usage: пример token chart; стоимость и неизвестные данные — «—».
- [x] Responsive ≤760px; focus-visible, native modal focus, Escape.
- [x] Постоянная маркировка «Концепт · функциональность не реализована».
- [x] Самопроверка браузером и запись ограничений. Это не formal verification/approval.

## Решения для обсуждения, не утверждённый контракт

Графит / тёплый нейтральный фон, барвинковый акцент, три глубины поверхностей.
Сайдбар 258px, текстовая лента ~700px, отдельный спокойный композер.
Пользователь — компактный приподнятый блок, ответ — свободная проза.
Контекст показан модальным popover-style диалогом, чтобы работали focus trap и Escape.
Системная тема не сохраняется; всё состояние живёт только до reload.
Навигация чатов меняет заголовок/принадлежность, но не демонстрационную переписку.
Новый чат/копирование/отправка/проверка подключения показывают объясняющий toast.

## Проверенная версия файлов (SHA-256, включая untracked)

```text
da7f1ec0bc58d1ce0acd31c5748c4c90e9c6b570b545abd0884bb26de7be2e18  app.js
a29452eca5606a897d7c22a234ac3f1483e12088fa101900683f9256f57b90e6  index.html
8e1fb37a4e2f91c27511d3ac5f3cf3c9534e79e9fe0b533c1126aac06ef606ae  README.md
dc8794786306ae3d5c574ec6c5620f3d7df2c72ed0f006dea22df8ed417b0377  style.css
```

Пути выше относительно `design/redesign-preview/`. Все четыре файла новые.
После visual/smoke проверок добавлен явный Escape handler в app.js. Повторены
`node --check` (exit 0) и целевая browser-проверка handler/focus; см. ниже.
HTML/CSS не менялись после screenshot evidence.

## Evidence / окружение

Cwd всех команд: `/home/kotdath/orca/workspaces/domovoy/feature-rework-ui`.
Linux, установленный Node/Python3 и Orca CLI; никаких установок зависимостей.

- `.opencode/bin/repo-git status --short` и `rev-parse HEAD`: exit 0, старт чистый, SHA выше.
- `node --check design/redesign-preview/app.js`: exit 0, без ошибок.
- `.opencode/bin/repo-git diff --check`: exit 0. Ограничение: новые untracked-файлы
  эта Git-команда не проверяет; их версия зафиксирована SHA-256 и браузером.
- `sha256sum design/redesign-preview/*`: exit 0, значения выше.
- `python3 -m http.server 8765 --bind 0.0.0.0 --directory design/redesign-preview`:
  background server, HTTP-превью успешно загружено; финального exit code пока нет.
- `orca-ide tab create --url http://localhost:8765/ --json`: exit 0, page
  `eb420195-4735-4088-99ac-a0348fc0efff`. Предназначена для пользовательского обсуждения.
- `orca-ide screenshot --page eb420195-4735-4088-99ac-a0348fc0efff --json`:
  exit 0; JSON decoded через Python base64. Изображения лично просмотрены через read:
  `/tmp/opencode/domovoy-preview.png` (dark 1169×923),
  `/tmp/opencode/domovoy-light.png` (light 1169×923),
  `/tmp/opencode/domovoy-mobile.png` (same-origin iframe 390×844 на desktop screenshot),
  `/tmp/opencode/domovoy-providers.png` (dark providers).
- Orca eval smoke на окончательном коде: переключение light → light; поиск OpenAI →
  4 результата; выбор → «GPT ⌄»; context.open → true; DeepSeek detail → DeepSeek;
  context chip в settings → display:none; usage → visible; создание проекта → 3 группы.
  CLI exit 0, response id `32ee2de5-8ae4-4737-b357-f5d688132b7a`.
- Responsive eval в same-origin iframe: viewport 390×844; horizontal overflow false
  для chat/providers/usage; menu display:flex; project dialog width 362, overflow false.
  CLI exit 0, response id `25758878-b1b0-4a6e-ac0c-09158af8ad6e`.
- Desktop eval: 1169×923, horizontal overflow false, system resolved to dark.
- При самопроверке исправлены [hidden] CSS specificity и принадлежность выбранного
  чата при возврате из settings; smoke/evidence выше после этих исправлений.
- Flutter checks не запускались: приложение не изменено. OpenSpec не создавался.
- Последующая Escape-проверка: `orca-ide keypress --page
  eb420195-4735-4088-99ac-a0348fc0efff --key Escape --json` дважды вернула
  exit 0 / pressed, но диалог остался открыт, даже с явным keydown handler.
  Причина доставки native key в embedded page не установлена, дальнейшие попытки
  остановлены. DOM `document.dispatchEvent(new KeyboardEvent("keydown",
  {key:"Escape",bubbles:true}))` закрыл диалог; следующий eval подтвердил
  focus=model-button (responses 461ad236-1655-4069-99d2-ca97f670f60b,
  ab840441-03a6-4e9f-9e7a-81a888544e41). Handler проверен, физический Escape
  через Orca остаётся UNVERIFIED; нужна ручная проверка пользователем.

## Ограничения / следующий шаг

Не проверялся реальный mobile device, screen reader или полный набор браузеров.
Не делалось измерение WCAG contrast; визуально проверены основные поверхности.
Все provider/model/token данные иллюстративны, сеть/FS/секреты не используются.
Блокеров для обсуждения макета нет; native-key automation ограничена, см. выше.
Следующий шаг — комментарии пользователя
в этой же Orca-сессии и визуальные итерации; approval ещё не получен.
Это handoff/evidence, не формальный runner RESULT; runner revision/id отсутствуют.

## Итерация 02 · 2026-09-19 · прямой feedback пользователя

Владелец макета работает самостоятельно, без субагентов. Approval не получен.
Изменены только design/redesign-preview и этот process-файл.

- Применены пункты feedback 1–11: context у send, elapsed byline с живой
  шестисекундной демо-генерацией, удалены палитра/слоган/личное пространство/
  большая кнопка нового чата; model provider→models и reasoning вверх от composer;
  Проекты/Чаты с плюсами, локальное создание чатов по контексту.
- Пользователь явно выбрал header «иконка папки + название чата».
- Rich formatting: объяснено различие Flutter RichText/TextSpan и Markdown
  renderer. Текущий SelectableText не разбирает Markdown. Решение о renderer
  и окончательный scope ещё не согласованы. Есть статический HTML-пример.
- Проверка Chrome CDP /tmp/preview-qa.py: exit 0. Dark/light, providers,
  context, project form, usage, model hover/select, таймер running/completed,
  новый чат в новом проекте и без проекта. 390×844: horizontal overflow false
  для chat и всех перечисленных панелей. Скриншоты /tmp/domovoy-*.png.
  Лично просмотрены dark desktop, light model picker, dark narrow/chat/models.
- node --check app.js: exit 0. Flutter/tests/OpenSpec не менялись.
- Сначала Orca CLI был недоступен: runtime_unavailable; open дал timeout.
  После снятия sandbox CLI доступен, но tab list (включая all) пуст;
  прежний page ID отсутствует. Сервер http://localhost:8765/ отвечает HTTP 200.
- Через Orca открыта новая вкладка f09092b8-7a8f-4e6f-a574-a38f251ec464;
  snapshot подтверждает preview / 02 и обновлённый UI. Runtime:
  a3bb3a2f-6f7d-4c10-b406-ad217a668974. Дальнейшая работа через Orca browser.
- Старые хэши/evidence относятся только к итерации 01.

## Итерация 03 · референсы пользователя

Контекст заменён на компактный немодальный popover у кругового индикатора;
model picker — два каскадных меню; controls справа рядом с отправкой.
Изменены только HTML/CSS/JS/README макета и этот state. Approval не получен.
Orca page f09092b8-7a8f-4e6f-a574-a38f251ec464 обновлена на /?v=03;
контекст оставлен открытым для обсуждения. node --check app.js: exit 0.
Проверены Orca dark/light context/model/providers/project, reasoning и
same-origin iframe 390×844: overflow false, все открытые панели внутри ширины.
Evidence: /tmp/orca03.py exit 0, /tmp/preview03-*.png; просмотрены dark context,
light model/context, narrow model, dark providers/project. Это проверка HTML,
не техническая реализация Flutter. Контекстные значения демонстрационные.

## Итерация 04 · верхняя навигация

По последнему feedback добавлен спокойный верхний пункт «Новый чат»;
это пересматривает прежнее пожелание убрать отдельную кнопку. Wordmark теперь
`domovoy`, без значка и preview рядом; concept badge сохранён над диалогом.
Создание — в текущем проекте/без проекта. node --check: exit 0.
Orca /tmp/orca04.py: exit 0; dark/light providers/context/project/model,
390×844 без горизонтального overflow. Скриншоты /tmp/preview04-*.png.
Отдельный клик верхнего нового чата подтвердил создание в текущем проекте.
Страница возвращена на исходный диалог /?v=04. Approval ещё не получен.

## Итерация 05 · sidebar по референсу Codex

Компактный domovoy, outline New Chat, папки, вложенные строки без направляющих
и счётчиков, нейтральный selected фон. Plus проекта на hover/focus/touch.
Orca /tmp/orca05.py: exit 0, dark/light и основные панели, narrow 390×844
overflow false. Визуальная проверка обнаружила слишком широкий opacity selector;
исправлен на :not(.project-title), повторный DOM-check подтвердил opacity 1
обоих заголовков, /tmp/preview05-fixed.png лично просмотрен.
Актуальная вкладка /?v=05a, CSS/JS v=05a. node --check: exit 0.
Approval не получен. Изменены только разрешённые файлы макета/state.
