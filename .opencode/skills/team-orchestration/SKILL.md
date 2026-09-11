---
name: team-orchestration
description: "Координируйте tiered pipeline orchestrator с task-subagents architect, coder, coder-strong, coder-fast, verifier, reviewer, reviewer-light и explore. Используйте для routing, handoff, findings, результатов, эскалаций и контроля последовательного workflow без внешнего транспорта."
---

# Оркестрация команды

`orchestrator` — единственная primary-роль команды. Он координирует subagent-роли
`architect`, `coder`, `coder-strong`, `coder-fast`, `verifier`, `reviewer`,
`reviewer-light` и `explore` штатным tool `task`, но не выполняет их профильную
работу самостоятельно. Внешний транспорт для командного процесса не
используется.

Перед первым назначением прочитайте `.opencode/policies/routing.md`, создайте
route card и выберите T0/T1/T2. Tier можно только повысить.

## Роли и маршруты

Используйте роли только по назначению:

- `architect` исследует требования, принимает архитектурные решения и ведёт
  OpenSpec-артефакты.
- `coder-fast` реализует только локальный T0 scope и обязан эскалировать новый
  hard-сигнал до редактирования.
- `coder` реализует утверждённый T1 change, добавляет тесты и запускает
  проверки; `coder-strong` реализует T2 после contract review.
- `verifier` запускает детерминированный runner и возвращает `CHECKS_PASS`,
  `CHECKS_FAIL` или `INCOMPLETE`; он никогда не выдаёт approval.
- `reviewer-light` проверяет T0/T1 diff и эскалирует T2-сигналы.
- `reviewer` выполняет тяжёлый T2 contract/code review только для чтения.
- `explore` проводит ограниченное read-only исследование и возвращает
  наблюдаемые факты.

Read-only роли читают файлы встроенными `read`/`glob`/`grep`, Git — только
`.opencode/bin/repo-git --read-only`, OpenSpec —
`.opencode/bin/repo-openspec`, а фиксированные проверки форматов —
`.opencode/bin/read-check`. Не поручайте им Dart/Flutter/tests: эти проверки
запускает verifier и возвращает структурированный RESULT. Writer-роли используют
`.opencode/bin/repo-git` для обычного локального Git; прямой `git` остаётся
approval-path для network/lossy или неподдержанных операций.

Subagent не вызывает другую роль и не адресует ей сообщение напрямую. Он
возвращает ответ `orchestrator`, который выбирает следующую роль и формирует
новый вызов `task`.

## Маршруты

```text
T0: coder-fast -> verifier -> reviewer-light
T1: architect -> coder -> verifier -> reviewer-light
T2: architect -> reviewer(contract) -> coder-strong -> verifier -> reviewer(code)
```

`orchestrator`, coder перед редактированием и reviewer по фактическому diff
независимо оценивают tier. Новый hard-сигнал останавливает облегчённый маршрут и
возвращается оркестратору как `ESCALATION` с доказательством.

## Вызов роли

Для нового назначения вызовите `task` с точным `subagent_type`. Сохраните
возвращённый `task_id` рядом с ролью, `scope_id` и change. Для уточнения,
исправления или повторной проверки продолжайте тот же сеанс, передав его
`task_id`. После изменения архитектуры или двух fix-циклов создайте свежий
контекст с коротким handoff вместо полного transcript.

В каждый prompt включайте достаточно контекста, чтобы роль не зависела от
истории оркестратора:

- цель и границы работы;
- OpenSpec change или область настройки;
- входные артефакты и уже принятые решения;
- допустимые и запрещённые действия;
- критерии приёмки и обязательные проверки;
- требуемые доказательства и формат ответа.

Каждое задание также содержит route card:

- `scope_id`, `attempt_id`, `initial_tier`, `current_tier`, immutable
  `base_revision`;
- `contract_revision`, `implementation_revision` (`pending` до verifier);
- included/excluded scope и `expected_changed_paths`;
- risk-сигналы с evidence;
- стабильные `AC-*` и required checks;
- `model_tiers_used`, `rework_count` и причину эскалации, если была;
- открытые `finding_id`/`invariant_id`, если есть.

## Контракт explore-задания

Каждое задание `explore` должно содержать:

- границы исследования и допустимые пути;
- вопросы и ожидаемый формат ответа;
- какие доказательства нужно вернуть (файлы, строки, наблюдаемые факты);
- явный запрет правок и state-changing команд.

Отчёт `explore` — черновые наблюдения, а не решение и не итоговое ревью.
Оркестратор передаёт его профильной роли для перепроверки. `explore` не
реализует приложение и тесты и не меняет OpenSpec.

## Контракт сообщения

Передавайте полные самодостаточные сообщения в prompt и требуйте тот же формат
ответа:

```text
Тип: TASK | QUESTION | DECISION | FINDING | RESULT | BLOCKED | ESCALATION
Изменение: <OpenSpec change, задача или область настройки инструментов>
Scope: <scope_id, attempt_id, tier, revisions>
От: <роль>
Кому: <роль>
Контекст: <краткое место и текущее состояние>
Доказательства: <файлы, строки, команды или наблюдаемые результаты>
Сообщение: <запрос, ответ, finding или результат>
Ожидаемый ответ: <конкретный ответ или "не требуется">
```

Существенные решения, влияющие на scope, требования, design или tasks, не
считаются зафиксированными, пока `architect` не запишет их в OpenSpec и не
вернёт обновлённый результат оркестратору.

## Маршрутизация ответов

- `QUESTION` от `coder` или `reviewer` по требованиям и архитектуре передавайте
  `architect`; вопрос о пользовательском выборе задавайте пользователю.
- После `DECISION` продолжайте исходный сеанс роли по его `task_id`.
- `RESULT` кодера передавайте `reviewer` отдельным `TASK` вместе с change и
  доказательствами проверок только после отдельного `RESULT` verifier. Для T0/T1
  используйте `reviewer-light`, для T2 — `reviewer`.
- `FINDING` категории реализации передавайте `coder`; `BLOCKED_BY_SPEC` или
  архитектурную блокировку — `architect`.
- `ESCALATION` повышает tier и инвалидирует прежний облегчённый маршрут.
- После исправлений продолжайте существующий сеанс `reviewer` для повторной
  проверки, кроме случаев обязательного свежего контекста.
- `BLOCKED` считайте остановкой только затронутой части. Не выдавайте работу за
  завершённую, пока блокировка не снята или пользователь явно не сузил scope.

## Findings, evidence и завершение

Каждый finding имеет стабильные `finding_id` и `invariant_id`. Coder может
отметить только `fixed_pending_review`; закрывает finding reviewer после
перепроверки. Повтор одного invariant после двух попыток возвращается
архитектору. Два цикла без нового evidence дают `NO_PROGRESS`.

Состояния различаются явно:

```text
planned -> implementing -> implemented -> under_review -> accepted
                                      \-> blocked_by_spec
```

`implemented` и `CHECKS_PASS` не равны `accepted`. Approval действителен только
для точных `scope_id`, `base_revision`, `contract_revision`,
`implementation_revision` и ссылается на `check_result_id`. Изменение любой
revision инвалидирует его.

Verifier запускает `.opencode/bin/pipeline-check` с полным immutable base SHA и
точными allowed paths.
Runner пишет structured RESULT и неблокирующий shadow-log в Git metadata
`.git/opencode-pipeline/`. При наличии OpenSpec change его validation обязателен;
отсутствующий CLI даёт `INCOMPLETE`, а не скрытый skip.

Reviewer не пишет журнал. После его verdict можно отдельным коротким назначением
передать verifier готовые revisions, result ID и verdict для события `reviewed`.
Verifier только записывает переданное значение и не превращает его в approval.

## Последовательность

Планирование, реализация и ревью одного change выполняются последовательно. Не
запускайте одновременно агентов, способных менять один файл. Параллельны только
независимые read-only исследования с явно непересекающимися границами.

Оркестратор не подтверждает корректность плана, реализации или ревью сам. Он
может сообщить результат пользователю только со ссылкой на ответ ответственной
роли и фактически выполненные проверки.
