# Маршрутизация задач

Каждая работа получает стабильный `scope_id`, `attempt_id`, начальный tier и
проверяемые критерии приёмки до назначения исполнителя. Tier можно только
повышать. Если фактический diff обнаруживает новый риск, старый маршрут больше
не действует.

## Tier'ы

### T0 — локальное изменение

Допустим только когда scope известен, изменение локально, критерий проверки
очевиден и нет hard-сигналов. Обычный маршрут:

```text
coder-fast -> verifier -> reviewer-light
```

### T1 — обычная запланированная работа

Нужны требования и декомпозиция, но нет hard-сигналов. Обычный маршрут:

```text
architect -> coder -> verifier -> reviewer-light
```

### T2 — критический контракт

Любой из следующих сигналов сразу требует T2:

- authentication, secrets, privacy, permissions или cryptography;
- persistence, schema, migration, data loss или restore;
- concurrency, cancellation, retry, lifecycle, recovery или idempotency;
- внешний необратимый, платный или пользовательский side effect;
- public API, wire/provider protocol или backward compatibility;
- изменение архитектурного контракта;
- повторно открытый invariant;
- отсутствие исполняемого критерия приёмки.

Маршрут:

```text
architect -> reviewer (contract review) -> coder-strong -> verifier
          -> reviewer (code review)
```

## Route card

Оркестратор создаёт и передаёт каждой роли:

```text
scope_id: <стабильный id>
attempt_id: <id текущей попытки>
initial_tier: T0 | T1 | T2
current_tier: T0 | T1 | T2
contract_revision: <версия пользовательского запроса/OpenSpec>
implementation_revision: pending | <fingerprint verifier>
base_revision: <полный immutable commit SHA до начала реализации>
included_scope: <пути и поведение>
excluded_scope: <явные non-goals>
risk_signals: <сигнал + доказательство или none>
acceptance_ids: <AC-...>
expected_changed_paths: <repo-relative paths/globs>
required_checks: <команды>
model_tiers_used: <fast | balanced | strong>
rework_count: <целое число>
```

`base_revision` фиксируется полным commit SHA до первого writer-вызова и не
меняется внутри scope. Verifier анализирует совокупность `base..HEAD`, index,
worktree и untracked paths. Его fingerprint включает base/HEAD tree blobs,
file modes, index entries, содержимое файлов, symlink targets и удаления.

Оценка выполняется трижды:

1. `orchestrator` — по запросу и известному контексту;
2. `coder`/`coder-fast` — до первой правки по планируемому touch-set;
3. `reviewer-light`/`reviewer` — по фактическому diff.

Coder или reviewer, обнаруживший необходимость повышения, возвращает
`ESCALATION` оркестратору и не продолжает облегчённый маршрут.

## Состояния и revisions

```text
planned -> implementing -> implemented -> under_review -> accepted
                                      \-> blocked_by_spec
```

`implemented` означает только handoff кодера. `CHECKS_PASS` означает только
успех формальных проверок. `accepted` возможен исключительно после подходящего
LLM-review и его verdict.

Вердикт всегда привязан к `scope_id`, `base_revision`, `contract_revision` и
`implementation_revision`. Изменение контракта, базы или проверяемой реализации
делает прежний verdict устаревшим. `result_id` строится из canonical check
payload и сохраняется иммутабельно: повтор идентичной проверки идемпотентен, а
иная полезная нагрузка никогда не перезаписывает существующий RESULT.

## Findings и остановка бесполезного цикла

Каждый обязательный finding получает стабильные `finding_id` и `invariant_id`.
Coder переводит его только в `fixed_pending_review`; закрыть finding может лишь
reviewer. Повторное открытие одного invariant после двух попыток исправления
маршрутизируется архитектору как `BLOCKED_BY_SPEC`. Два цикла без нового
evidence, закрытого finding или улучшившейся проверки дают `NO_PROGRESS` и
требуют пересмотра контракта, дробления scope или решения пользователя.

После изменения архитектуры или двух fix-циклов создаётся свежий task context.
В него передают route card, решения, открытые findings и evidence, а не полный
transcript.

## Модельные профили

Профили описывают назначение, а не обещанную цену провайдера:

- `fast`: `opencode-go/muse-spark-1.3-contributor` — orchestrator,
  `coder-fast`, verifier и light reviewer;
- `balanced`: `openai/gpt-5.6-sol` — architect и T1 `coder`;
- `strong`: `xai/grok-4.6` для T2 `coder-strong` и
  `openai/gpt-5.6-sol` для heavy reviewer.

Сильная модель не вызывается на T0. Недоступность strong-профиля не понижает T2:
scope остаётся незавершённым до требуемого review.

## Исполнение команд по ролям

Writer-роли выполняют обычные repo-local Git-команды через
`.opencode/bin/repo-git`. Wrapper использует default-deny грамматику:
команды и опции должны точно входить в allowlist, сокращения длинных опций запрещены,
а значения опций поглощаются атомарно по типу. Пути передаются после явного `--`,
остаются в worktree, а `add` принимает только явные файлы. `-C` разрешён только внутри текущего
worktree. `branch`/`tag` только читаются, `config` только читает локальную конфигурацию без includes,
`remote` только показывает список/адрес, а `commit` требует явное сообщение и отключает hooks,
signing и редакторы. Lazy fetch, pager, external diff/textconv и fsmonitor принудительно отключены.
Неподдержанная, network, lossy или external-scope операция идёт через прямой `git`, который
остаётся `ask` для writer-ролей и `deny` для read-only ролей.

`explore`, `reviewer-light` и `reviewer` используют встроенные
`read`/`glob`/`grep` и только фиксированные read-only wrappers:
`.opencode/bin/repo-git --read-only`, `.opencode/bin/repo-openspec` и
`.opencode/bin/read-check`. Их shell deny-правила также запрещают redirection,
pipe, chaining и command substitution. Они не запускают Dart/Flutter/tests;
формальный RESULT создаёт `verifier`.
