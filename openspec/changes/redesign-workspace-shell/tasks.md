Implementation prerequisite: `add-project-workspaces` must be accepted. Until
then this change remains `planned/waiting_dependency`; no task below may start.

## 1. Theme and bounded answer rendering

- [ ] 1.1 Add `flutter_markdown` to `pubspec.yaml`/`pubspec.lock` and implement one design-system-styled assistant renderer for the approved headings, paragraphs, ordered/unordered lists, emphasis, strong emphasis, inline code, fenced code, and inert link labels; keep raw HTML, images, tables, task lists, and all link activation non-executable/non-loading, with focused allowed/streaming/unsafe-markup widget tests.
- [ ] 1.2 Map the recorded `final-01` dark/light colors, typography, one-pixel borders, focus treatment, radii, approximately 270 px rail, approximately 700 px timeline, and aligned composer into design-system tokens/dimensions and responsive policy without feature-local visual constants.
- [ ] 1.3 Change `DomovoyApp` from forced dark to an in-process System/Dark/Light controller that defaults to System, follows platform brightness only in System mode, exposes the choice to the workspace, and writes no preference storage; test startup, override, reset, and platform-change behavior.

## 2. Approved truthful shell composition

- [ ] 2.1 Restyle the existing `WorkspaceShell`/header/timeline/composer to the approved prose-first desktop composition and viewport-safe narrow composition, retaining current loading, empty, error, tool, reasoning, compaction, delete, send, and stop states.
- [ ] 2.2 Rework navigation to the approved wordmark, top new-chat action, real `Проекты` → member-chat groups, `Чаты` / `Без проекта`, and bottom provider/theme controls; consume only the accepted Project workspace projection/commands, render every chat exactly once, preserve scoped versus unassigned creation, and mirror unsupported/regrant/deleting states without local inference.
- [ ] 2.3 Add the header project-status surface using the selected real Project plus latest safe root/access label, or `Без проекта` and root `—`; wire Project add to the accepted capability-gated creation flow and omit global usage, sample paths, file controls, attachment/context-plus claims, fabricated counts, and sample provider/token data.
- [ ] 2.4 Render user messages as compact right-aligned raised blocks and assistant answers as free prose through the bounded Markdown renderer, while preserving exact transcript text, selectable plain-text fallbacks, partial markers, errors, reasoning disclosures, and tool/compaction behavior.

## 3. Ephemeral work duration

- [ ] 3.1 Add injected `AgentClock` timing to the chat controller/live-run state: capture monotonic start at run admission, freeze once on the first completed/failed/stopped/cancelled terminal event, and expose read-only elapsed time without changing persistence records or `lib/core/**` contracts.
- [ ] 3.2 Add a run-ID-bound duration label that refreshes visually at most once per second while active, uses `Работает` then frozen `Работал`, does not announce ticks, and disposes its timer on terminal/replacement/navigation/disposal; omit duration for restored history.
- [ ] 3.3 Add deterministic fake-clock tests for normal completion, failure, provider stop, delayed cancellation, duplicate stop/terminal, stale run replacement, wall-clock independence, navigation, disposal, and restart/restore with no fabricated zero or persisted duration.

## 4. Context and selection overlays

- [ ] 4.1 Extend the existing token presenter only with current/latest provider-reported inclusive request input, declared selected-model context bound, and a ratio when both exist; preserve provenance/partial labels and return `—` plus neutral progress for every unavailable operand, with unit tests against omitted, zero, partial, and inconsistent provider data.
- [ ] 4.2 Move the compact context control beside send/stop and implement an upward desktop popover plus narrow sheet using only that projection; verify no retained-context estimate, instruction/file/project/provider category, price, or prototype number is rendered.
- [ ] 4.3 Replace the desktop model menu with an upward, focus-managed provider → models cascade sourced from the validated catalog, with provider preview separate from model activation, provider/model/ID search, bounded lazy lists, truthful unavailable/stale/partial states, outside/Escape dismissal, and trigger focus restoration.
- [ ] 4.4 Restyle reasoning as a separate upward capability-derived picker and retain a viewport-safe narrow sheet; test unsupported/required/optional capability matrices and prohibit undeclared efforts or silent model substitution.
- [ ] 4.5 Add desktop and 390×844 tests for keyboard, pointer, touch, semantics, large catalogs, high text scale, overlay bounds, no horizontal overflow, and deterministic focus return for context/model/reasoning surfaces.

## 5. Real provider settings presentation

- [ ] 5.1 Restyle the existing provider credential/discovery UI into the approved provider list/detail composition with a stacked narrow fallback, deriving provider rows, configured source, catalog contents, freshness, partial failures, save/remove, and refresh outcomes only from current stores/catalog services.
- [ ] 5.2 Preserve the obscured replacement-key flow without ever prefilling or displaying stored/environment values; add negative tests that secret values do not appear in visible text, semantics, controller text, sanitized failures, or provider/model status, and do not add a fabricated connection-health action.

## 6. Regression, visual evidence, and checks

- [ ] 6.1 Update focused workspace/page/composer/timeline/settings tests so accepted Project create/select/delete/regrant-status and scoped/unassigned chat flows plus current chat delete/restart, Enter/Shift+Enter, send/stop, model/reasoning, provider credential/discovery, token details, errors, tool, compaction, drawer, shortcuts, focus, and semantics continue to pass in dark/light desktop/narrow layouts.
- [ ] 6.2 Regenerate exactly `dark_desktop.png`, `light_desktop.png`, `dark_narrow.png`, and `light_narrow.png` under `test/goldens/chat_workspace/`; inspect them plus representative open context/model/reasoning/provider surfaces against approved `final-01`, confirm no 390×844 horizontal overflow, and record SHA-256 fingerprints rather than treating `--update-goldens` as visual approval.
- [ ] 6.3 Run `dart format .`, `flutter analyze`, and `flutter test` from the repository root; report commands, cwd, exit codes, concise output, implementation diff/fingerprint, environment limitations, and reconfirm that the four approved `design/redesign-preview/` SHA-256 values are unchanged.
- [ ] 6.4 Stop and return a concrete blocker before widening scope if implementation needs any change to the accepted Project/session schema, Project application commands, grant store/broker/path policy, platform/native files, directory permission/filesystem APIs, pricing, runtime context-composition, persisted timing/theme, outbound link launching, provider protocols, or either dependency change's artifacts.

## 7. Acceptance criteria

- [ ] 7.1 **AC-01 Visual composition:** dark/light desktop and dark/light 390×844 goldens show the approved `final-01` wordmark, compact rail, truthful Projects/Chats grouping, folder-status header, prose timeline, raised user block, aligned composer, and restrained semantic tokens without sample/demo labels or fake data.
- [ ] 7.2 **AC-02 Responsive accessibility:** at 390×844 and high text scale, the base workspace and every context/model/reasoning/provider surface have no horizontal overflow; all enabled actions are keyboard reachable with visible focus, stable semantics, at least 44 logical-pixel targets, topmost Escape dismissal, and deterministic trigger focus return.
- [ ] 7.3 **AC-03 Existing flows:** accepted Project create/select/delete/regrant-status, Project-scoped/unassigned chat create/select/delete/restart, draft send, idempotent stop, provider credential save/remove/discovery refresh, model switch, reasoning choice, token detail, error/settings, tool, compaction, shortcut, and narrow drawer tests pass with no Project/provider/storage/schema behavior change.
- [ ] 7.4 **AC-04 Truthful availability:** every chat appears exactly once under its real Project or recoverable `Без проекта`; Project controls/root status mirror accepted capability results, unsupported creation stays disabled, and context/provider/catalog unknowns use `—` or explicit unavailable/stale/partial text, never zero or prototype values; no enabled file/attachment/global-usage/pricing/context-composition action exists and no secret/grant material is exposed.
- [ ] 7.5 **AC-05 Markdown safety:** only the approved answer syntax receives rich rendering; live incomplete syntax remains readable and settles without content duplication; raw HTML/script, images, tables/task lists, malformed/unsafe links, and all link taps create no execution, network load, embedded control, or outbound action.
- [ ] 7.6 **AC-06 Duration lifecycle:** fake-monotonic-clock tests prove one run-ID-bound `Работает` timer, terminal `Работал` freeze for every terminal kind, no reset on duplicate stop/terminal, no stale-run mutation, no tick announcements, and no duration after navigation/restart when timing is unavailable.
- [ ] 7.7 **AC-07 Context and selectors:** context beside send uses only provider-reported request input plus declared model bound and shows neutral `—` when unavailable; upward desktop provider→models and reasoning pickers plus narrow sheets handle search, thousands of models lazily, exact capabilities, truthful unavailable state, and explicit selection only.
- [ ] 7.8 **AC-08 Theme:** startup follows System, in-process Dark/Light overrides and reset work in the approved composition, platform brightness is ignored during an explicit override, and no theme preference is persisted.
- [ ] 7.9 **AC-09 Evidence and boundary:** only expected paths change, all four approved preview hashes remain exact, four implementation golden hashes and the tested diff fingerprint are recorded, and `dart format .`, `flutter analyze`, and `flutter test` complete successfully with reproducible evidence.
