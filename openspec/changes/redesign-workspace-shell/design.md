## Context

See `proposal.md` for motivation and
`specs/chat-workspace-ui/spec.md` for the observable contract. The approved
visual source of truth is `design/redesign-preview/` at version `final-01`; its
four recorded SHA-256 values in the feature-state file are part of the design
evidence and must not be changed by implementation.

At this planning revision the Flutter app has semantic dark/light Material 3
tokens, a responsive sidebar/timeline/composer, flat durable sessions,
capability-driven model/reasoning selection, provider credential/discovery
settings, immutable token accounting, and four dark/light × desktop/narrow
goldens. `DomovoyApp` currently forces dark mode. Assistant text is
`SelectableText`; no Markdown renderer is installed. The prerequisite
`add-project-workspaces` supplies the real Project entity, membership, creation,
deletion, and safe grant-status projection that this change must consume after
that dependency is accepted. It does not supply context composition, pricing, or
per-response duration.

## Goals / Non-Goals

**Goals:**

- Translate `final-01` into Flutter without redesigning its composition.
- Reuse the accepted Project/chat/provider/accounting behavior and keep
  presentation adapters read-only over those sources.
- Make every visible value and enabled action truthful in production.
- Keep the implementation independently verifiable through focused widget/unit
  tests, existing flow tests, and four deterministic shell goldens.

**Non-Goals:**

- Adding, migrating, or changing Project/domain persistence, nested session
  ownership, directory grants, path policy, filesystem tools, attachments, or
  context composition; those Project contracts belong to
  `add-project-workspaces` and are prerequisites here.
- Adding provider pricing, cost estimates, seven-day/global usage aggregation, or
  prototype provider/model/token samples.
- Persisting theme or run duration, changing provider protocols, changing secret
  storage, enabling outbound links, or altering native/platform files.

## Decisions

### 1. Adapt the existing shell instead of building a second workspace

`WorkspaceShell`, `ChatSidebar`, `ChatTimeline`, and `ChatComposer` remain the
single production path. Design-system tokens/dimensions are adjusted centrally;
the feature widgets consume only semantic roles. Existing message/tool/reasoning/
error projections and commands remain authoritative.

The accepted Project workspace projection is rendered directly: healthy Projects
own their real member chats, and null or unresolved memberships appear under
`Чаты` → `Без проекта` with the dependency's sanitized warning when applicable.
Project add opens the existing capability-gated creation flow; it remains disabled
with the existing explanation on unsupported platforms. New-chat actions preserve
the selected Project or unassigned context and invoke the accepted scoped creation
command exactly once. The header project icon opens a small truthful status
surface containing the selected Project name plus latest safe root/access status,
or `Без проекта` and root `—`; it never substitutes a sample path, grant, or
permission. The global usage destination remains omitted. Provider settings stay
available and are restyled as a real-data list/detail surface with a stacked
narrow fallback.

Alternative rejected: retain an interim flat or in-memory Project façade. It
would contradict approved `final-01` and duplicate or weaken the accepted durable
Project/grant authority.

### 2. Use semantic `final-01` tokens and an in-process theme controller

The approved colors map to the existing semantic extension: canvas, sidebar,
raised/elevated, border/divider, text levels, selected/hover, and accent. Geometry
(approximately 270 px sidebar, 700 px timeline, aligned composer, 10–16 px
surface radii) stays in design-system foundations rather than feature literals.

`DomovoyApp` owns `ThemeMode`, initializes it to `ThemeMode.system`, and passes
the current value/change callback through the workspace presentation boundary.
System/Dark/Light is available in the sidebar. This state is intentionally not
written to `shared_preferences`: `final-01` requires System as default and theme
choices, but does not require persistence.

Alternative rejected: reuse the existing `shared_preferences` dependency for an
override. That silently adds persistence semantics beyond the approved slice.

### 3. Render a deliberately bounded Markdown subset with `flutter_markdown`

Add `flutter_markdown` as a direct dependency and wrap it in one
`AssistantMarkdown` presentation component. Configure CommonMark-style parsing
and design-system styling for only headings, paragraphs, ordered/unordered lists,
emphasis, strong emphasis, inline code, fenced code, and link labels. Images use
a non-loading fallback, raw HTML is never interpreted as Flutter widgets, and
unsupported structures receive no specialized rich renderer. Do not provide
`onTapLink`: links are visibly styled/selectable but inert in this slice, so
`javascript:`, custom, malformed, and even HTTP(S) targets cannot cause an
external action. No `url_launcher` or platform integration is added.

The same component renders persisted and live assistant answer text. During
streaming it reparses the complete accumulated string; incomplete delimiters may
temporarily remain plain text, and the terminal render is asserted against the
same completed source. User messages, tool payloads, reasoning, errors, and
unsupported parts remain plain selectable text and are never parsed as Markdown.

Tests cover every allowed construct, incomplete fenced/emphasis syntax, nested
plain text, raw `<script>`/HTML, image syntax, table/task-list input, malformed and
unsafe links, and proof that no network image or tap callback is produced.

Alternative rejected: a feature-local regex/`TextSpan` parser. It is difficult to
make nesting, escaping, streaming delimiters, and code fences predictable and is
more security-sensitive than a maintained parser with an explicit rendering
allowlist.

### 4. Duration is ephemeral monotonic live-run presentation data

Reuse the existing `AgentClock` abstraction. `ChatWorkspaceController` receives
an optional clock (system clock in production, fake in tests). On successful run
admission it stores the clock's monotonic `elapsed` value in `ChatLiveRunState`;
folding the first terminal event stores a terminal elapsed value. The controller
exposes current monotonic elapsed read-only so the page can repaint a dedicated
duration label at one-second granularity without publishing one runtime state per
tick. A timer exists only while the current run is non-terminal and is cancelled
on terminal state, run replacement, navigation, widget disposal, or controller
disposal.

Elapsed display is `(terminalElapsed ?? clock.elapsed) - startedElapsed`, clamped
at zero and rounded down to whole seconds. Active text is `Работает N с`; every
terminal kind freezes as `Работал N с`, while completed/cancelled/failed/stopped
status remains a separate semantic status. A cancellation request does not end
the timer; only the terminal event does. Duplicate stop and duplicate terminal
events cannot reset the start or move the frozen value. Because the timing is not
in `AgentSessionRecord`, restored/historical responses omit the byline. A new run
replaces the ephemeral measurement; no old answer gets the new run's duration.

Alternative rejected: derive duration from `DateTime` or record
`updatedAtMicros`. Both include unrelated persistence work and are vulnerable to
wall-clock jumps; adding persisted response timing is a separate schema change.

### 5. The context control is a view over existing accounting, not composition

Move the compact token entry point beside send/stop and present its detail in an
upward anchored desktop popover or narrow sheet. Extend only the presenter shape
needed for current/latest provider-reported inclusive request input and the
selected model's declared context bound. Show a ratio/ring only when both are
present; otherwise show a neutral ring and `—`. Existing partial and provenance
labels remain. Do not surface the estimator-derived retained-context value and do
not invent the prototype's history/instructions/files/provider categories.

Alternative rejected: map session totals into context fill. Lifetime usage is
not the active request context and would create a convincing but false value.

### 6. Pickers share an upward anchored interaction pattern

Desktop model selection uses one focus-managed anchored overlay above the model
trigger with a provider list on the left and the active provider's model list on
the right. Pointer hover may preview a provider, but focus/click activation must
provide identical behavior and cannot select a model. The model is changed only
by explicit model activation. A search field filters provider display names,
model names, and IDs. Both lists have bounded height and use lazy builders so a
large validated catalog is not eagerly laid out. The current catalog
source/freshness/partial-failure state remains visible and unavailable saved
models stay explicit.

Reasoning uses a separate, smaller upward anchored overlay generated by
`reasoningChoicesFor`; no display label is mapped back into a capability. Escape,
outside dismissal, selection, and route disposal restore focus to the trigger.
At narrow/high-text-scale layouts, model and reasoning use searchable/bounded
bottom sheets that preserve the same data and capability semantics. All overlay
positions are clamped to safe viewport insets.

Alternative rejected: hard-coded three-level reasoning labels and prototype
catalog entries. They disagree with provider model capabilities and discovery.

### 7. Provider settings keep the existing credential boundary

Refactor the current provider settings presentation into approved list/detail
geometry while keeping `ProviderCredentialStore`, environment-source reporting,
and `ProviderModelCatalog` as the only data/command sources. The stored or
environment key is never read into display text or the input controller. The
obscured input accepts only a replacement value supplied in the current UI;
save/remove/refresh outcomes use existing sanitized messages. Provider status
means configured source/catalog status, not a fabricated network health check.

Alternative rejected: reproduce the HTML's demonstration “connected” rows or a
connection-test button without a defined provider health operation.

### 8. Evidence and path boundary

Expected implementation paths are limited to:

- `pubspec.yaml`, `pubspec.lock`
- `lib/app.dart`
- `lib/design_system/foundations/{primitive_tokens,dimensions,responsive_policy}.dart`
- `lib/design_system/theme/{domovoy_theme,domovoy_theme_extension}.dart`
- `lib/features/chat/application/{chat_workspace_controller,chat_workspace_state,chat_timeline_projector,chat_token_presenter}.dart`
- `lib/features/chat/presentation/{workspace_shell,chat_sidebar,chat_composer,chat_timeline,timeline_parts,model_selector,reasoning_selector,token_details}.dart`
- new presentation helpers under `lib/features/chat/presentation/` only for the
  bounded Markdown renderer, duration label, context popover, or shared anchored
  overlay
- `lib/features/projects/presentation/**` only to map the already accepted
  Project creation/navigation/status commands and states into `final-01`; no
  Project application/domain/storage behavior may change
- `lib/features/settings/presentation/provider_api_keys_dialog.dart` and, only if
  extracted from it, new provider-settings presentation helpers in that directory
- focused tests under `test/features/chat/{application,presentation}/`, existing
  provider settings tests, `test/widget_test.dart`, and `test/app_composition_test.dart`
- `test/goldens/chat_workspace/{dark_desktop,light_desktop,dark_narrow,light_narrow}.png`

No `lib/core/**` domain contract, persistence/storage implementation, platform
directory, or approved `design/redesign-preview/**` file is expected to change.
If implementation requires one, the coder must stop that dependent work and
return the concrete reason for coordinator/architect review instead of widening
scope.

The implementation handoff must include command, cwd, exit code, concise output,
and version/fingerprint for `dart format .`, `flutter analyze`, and `flutter test`.
It must also include SHA-256 for the four resulting goldens and reconfirm the four
approved preview hashes are unchanged. The later visual reviewer compares all
four goldens and representative open context/model/reasoning/provider surfaces to
`final-01`, while the formal verifier checks every AC independently.

## Risks / Trade-offs

- **[T2 lifecycle coupling]** A duration tied to cancellation/terminal events
  could reset, freeze early, or attach to the wrong run. → Key state by run ID,
  use monotonic injected time, freeze only on first terminal, cancel presentation
  timers on replacement/disposal, and test duplicate stop, stale event, failure,
  navigation, and restart/restore negatives.
- **[Untrusted Markdown]** Provider text could attempt HTML, images, or malicious
  links. → No HTML widget interpretation, no image loading, no link callback, an
  explicit rendering subset, and negative widget/semantics tests.
- **[Secret exposure]** A settings redesign could accidentally prefill or log a
  key. → Keep the credential store boundary unchanged; test that stored and
  environment values never appear in text, semantics, controller values, or
  failure messages.
- **[False context precision]** Session totals or estimator values could look like
  current context usage. → Accept only provider-reported request input plus a
  declared model bound; missing is `—`, partial stays partial, no zero fallback.
- **[Overlay overflow/focus loss]** Upward cascades may clip at 390×844 or strand
  keyboard focus. → Clamp desktop overlays, use narrow sheets, test Escape/outside
  dismissal and focus restoration at reference viewports and high text scale.
- **[Golden churn]** Four intentional full-shell goldens will change broadly. →
  Keep widget behavior assertions separate, fingerprint all goldens, and require
  a targeted visual comparison rather than accepting `--update-goldens` alone.
- **[Concurrent accepted change]** `add-provider-discovery-and-api-usage` is
  accepted but unarchived and overlaps provider/model/accounting requirements. →
  Do not edit or archive it here; implementation builds on its current code, and
  change archival/sync order must preserve its accepted requirements before this
  delta is archived.
- **[Hard dependency]** Starting from flat sessions would create a contradictory
  temporary production shell or duplicate Project authority. → Keep this change
  at `planned/waiting_dependency`; do not start any shell task until
  `add-project-workspaces` is accepted, then consume its fixed public state and
  commands without modifying its persistence/grant contract.

## Migration Plan

1. Confirm `add-project-workspaces` is accepted and freeze its Project-facing
   controller/state contract for this dependent presentation slice.
2. Add the Markdown dependency and presentation-only adapters.
3. Update semantic tokens/layout and shell destinations around the accepted
   Project/chat controller/runtime.
4. Add duration/accounting projections and anchored selectors with focused tests.
5. Restyle provider settings without changing storage/discovery operations.
6. Regenerate exactly four workspace goldens and run the complete Flutter checks.

There is no data migration in this dependent change. Rollback removes only its
Markdown dependency and presentation changes; accepted Project/session/grant,
credential, provider-catalog, and token data remain compatible and untouched.
