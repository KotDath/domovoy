## Context

See `proposal.md` for motivation and the delta specs for observable behavior. The reusable core already supplies caller-owned `AgentSession` create/restore/run/compact/close operations, strict versioned records, a durable JSONL repository/catalog, model capabilities, cancellation, compaction, stable transcript message identities, and `AgentTokenAccountingSnapshot`. Production nevertheless uses `Agent.run()` through `PromptController`, creates transient sessions, does not configure a compactor, and presents an inline Material theme with a single `900` breakpoint.

The primary implementation reference is OpenCode: provider-grouped model choice, separate variant/reasoning control, left session navigation, typed timeline parts, collapsed reasoning, tool cards, interrupt, and danger-confirmed deletion. The supplied Codex Desktop screenshot defines shell proportions. Grok contributes the calm pill composer and progressive disclosure; ZCode/Zed are secondary references for task navigation, thought-level controls, stop, expandable execution content, and token gauge. Existing research sessions `ses_f68b16b62ffedsQ0UP1rdwhrfx` and `ses_f68b16a34ffeyivWv53dgqWaRD` are accepted inputs and are not repeated.

An immediately inspectable static preview is at `mockups/chat-workspace-desktop.svg`. It is a design artifact, not production code and not an approval gate; the user explicitly selected autonomous Heavy execution with no gate.

## Goals / Non-Goals

**Goals:**

- Make one selected durable session the unit of UI ownership and testing.
- Keep risky mutation/cancellation logic below widgets and make all state transitions deterministic.
- Reuse committed JSONL, compaction, model registry, transcript, and accounting contracts instead of duplicating them in presentation state.
- Provide one design-system source from foundations through theme/components, with pure responsive decisions and inspectable visual regression.
- Preserve all configured platforms while requiring direct build evidence for Linux and web.

**Non-Goals:**

- Parallel/background chat runs, multi-window coordination, mailbox UI, or resuming in-flight work after process death.
- Attachments, markdown parsing/rendering, rename/search, tabs/worktrees, pricing/cost, permission-management UI, file diffs, or external agents.
- Dynamic provider discovery, catalog refresh, model pricing, a tokenizer, LLM-generated titles, undo/secure erase, or changing credential secrecy guarantees.
- Replacing JSONL envelopes or rewriting old records solely to add defaults.

## Decisions

### 1. One application controller owns one live selected session

Add `lib/features/chat/application/` with immutable `ChatWorkspaceState`, typed command outcomes/failures, `ChatWorkspaceController`, `ChatTimelineProjector`, and `ChatTokenPresenter`. The controller receives `AgentRuntime`, the chat `AgentDefinition`, `AgentSessionCatalog`, `AgentSessionRepository`, registry catalog view, title policy, scheduler/pacing policy, and settings launcher seam. Widgets issue intent methods only; they never call repository/runtime directly.

Startup lists the catalog, stores healthy summaries plus issues, then restores the first summary in authoritative order. No summaries yields an empty workspace rather than an implicit record. Create opens `SessionPersistence.repository`, selects it, and refreshes catalog. Select is admitted only while the command lane and current session are idle; it closes the prior session and restores the exact requested id. Generation plus session/run/operation ids reject late results. Catalog refresh replaces summaries wholesale in catalog order.

The controller permits one mutation lane. `stop` and the confirmed-delete continuation are the only commands allowed to act on an active operation. Busy results carry the active kind (`run`, `restore`, `modelSwitch`, `compaction`, `delete`, `close`) so widgets can disable controls and tests can assert no hidden queue. This is preferred to per-widget orchestration because lifecycle races remain testable without a Flutter binding.

**Alternative rejected:** keep `PromptController` and add list callbacks. It is centered on transient one-call output and has no revision/session identity, so it cannot safely own restoration, deletion, or live/persisted reconciliation.

### 2. Mutable selection and title are session-record state, not definition mutation

Introduce an immutable selection value containing `ModelRef`, `ReasoningMode`, and `ReasoningEffort`. `AgentDefinition` remains reusable immutable defaults; each new session copies those defaults into current selection. Session snapshots/records expose current selection and optional title. Every run snapshots selection once at admission, and every physical attempt in that run uses it.

The nested record schema advances compatibly; JSONL envelope format does not. Missing selection derives from the stored definition; missing title remains null. No eager rewrite occurs. A configured `AgentSessionTitlePolicy` derives the title in the first-user-message checkpoint: trim, collapse Unicode whitespace, remove controls, and truncate at a configured grapheme-safe display bound with an ellipsis. The value is then immutable. Catalog summaries gain title and complete selection.

Registry catalog enumeration gains immutable ordered provider groups with provider display name and models. Built-ins supply display names as metadata; model names/capabilities already exist. The UI never switches on provider/model ids. Registry insertion/catalog order is the display order; it is deterministic and preserves custom composition intent.

**Alternative rejected:** derive titles during every listing. Compaction can remove the first turn, making title unstable or requiring retained raw history. **Alternative rejected:** copy and mutate `AgentDefinition`; this conflates reusable defaults with per-chat state and risks changing another session.

### 3. Model switch is an idle-only combined record transaction

Add a cancellable session selection operation and operation events/results. Exact equality returns `unchanged` after normal value validation with no estimate or save. Reasoning-only same-model changes persist one ordinary successor and preserve continuation entries. Any active run/compaction/switch rejects another incompatible operation as typed busy; there is no queue.

For a provider/model change:

1. Resolve the exact target from the registry and validate the full reasoning pair.
2. Build the next request snapshot using target model/generation and the committed normalized transcript. Omit opaque continuation entries because they are origin-bound to the old model; visible messages/tool cycles remain.
3. Estimate through the runtime's configured `AgentContextEstimator`. Resolve fit through an injected `AgentModelSwitchFitPolicy`: target context bound minus a valid output reserve and headroom. Configuration, not UI literals, owns reserve/headroom and post-compaction ratio.
4. If the estimate fits, stage target selection plus continuation removal.
5. If oversized, call the existing configured `AgentHistoryCompactor` with `AgentCompactionReason.modelSwitch`, target-model metadata, and a post-compaction target no greater than the fit threshold. Reuse existing grouping, protected seed, candidate, provenance, continuation, accounting, and estimator validation helpers, but do not call public forced `compact()` because that would commit an intermediate record.
6. Validate the candidate as a target-shaped request. Persist candidate transcript/compaction provenance/remapped accounting, compactor usage, continuation removal, and target selection in one expected-revision successor. Adopt it live only after acknowledgement.

Production composes `OpenCodeSummaryCompactor(RegistryAgentSummaryLlmInvocation(registry))` and the existing OpenCode-inspired trigger/estimator policy. Thus both ordinary pressure recovery and model-switch compaction have an actual configured strategy. Compactor provider selection remains strategy-owned (session model by default), and its exact physical model is charged by committed accounting.

No-change while still oversized, ineffective candidate, missing compactor, failure, cancellation, conflict, or failed save retains old selection and visible history. Compactor usage already incurred remains an exact-once accounting side effect and may advance only accounting revision even though switching fails; UI copy must not imply the operation was free. If the combined atomic save wins cancellation, commit wins and the controller displays the new selection. Switching back never resurrects discarded continuation payload.

**Alternative rejected:** first call public `compact()`, then save model. That exposes a durable compacted-old-model halfway state and cannot atomically resolve save/cancellation races. **Alternative rejected:** defer fit until next send, as OpenCode does. The explicit user contract requires compaction before committing the model choice.

### 4. Delete is confirmation-bound stop, close, tombstone

Presentation first obtains a `ChatDeletionIntent` containing exact chat id and display title and opens a modal danger dialog. Dismiss/cancel consumes no command. Confirm submits that same intent once to the controller. The controller prevents other workspace mutations, cancels any active run or selection compaction for that chat, awaits its terminal persistence outcome, closes the live session to prevent later checkpoints, and deletes the latest acknowledged revision through the repository. A stop timeout, unreliable session, stale/external revision, or delete error produces a sanitized failure and catalog refresh/re-restore where possible; success is not optimistic.

After acknowledgement, neighbor choice uses the pre-delete ordered ids: same index, else previous, else null. Deleting an unselected idle summary leaves current selection intact. Tombstone semantics and reserved ids remain repository-owned. There is no undo and UI text says removal is irreversible without claiming physical secure erase.

**Alternative rejected:** optimistic sidebar removal followed by async delete. A failed tombstone would falsely communicate destructive success. **Alternative rejected:** delete before stopping/closing. A late checkpoint could conflict or appear to resurrect state.

### 5. Timeline uses identity-based reconciliation, not event concatenation

`ChatTimelineProjector` is a pure projection over `(AgentSessionSnapshot, LiveRunProjection, disclosureState)`. Persisted transcript messages and accounting message ids are authoritative. Live keys use session/run plus part role/ordinal; tools use call id; operation notices use operation id. On every safe-boundary event or terminal, the controller refreshes the session snapshot. When a persisted message matches the live logical response/request, the projector replaces live content with the persisted item rather than appending it.

The typed registry covers user bubble, assistant text bubble, reasoning disclosure, tool card, compaction notice, and sanitized error/interruption notice. Unknown future content parts become a safe unsupported-part card rather than being silently dropped or crashing the timeline. Reasoning expansion is UI-only, keyed per response/message, and initializes false for every restored or newly streaming response. Tool args come from assembled calls; committed result bodies come from refreshed transcript snapshots because current finish events carry status but not result content. JSON is pretty-printed only on successful decode; otherwise exact normalized text remains selectable.

`ChatStreamPacingPolicy` and an injected scheduler coalesce repaint notifications, not source state. Every delta is reduced immediately into the live buffer; snapshot boundaries, terminal events, session switches, and dispose synchronously flush/cancel scheduled notifications. This avoids dropped trailing text and gives deterministic fake-scheduler tests.

Compaction notices show status, reason, estimates, and strategy labels only. They do not expose generated summary or removed history. Past transient errors and operation events are not invented after restart; committed messages/tools, latest compaction provenance, and accounting do restore.

### 6. Token presentation is a read-only adapter over committed projections

The controller never sums tokens. `ChatTokenPresenter` converts `AgentTokenAccountingSnapshot` and selected model metadata into display values while retaining provenance/completeness. Three detail groups are fixed semantically, not numerically:

- **Current request:** active assistant attempt, otherwise latest finalized assistant request.
- **History:** complete session work, explicitly including assistant and model-backed compaction plus labelled legacy baseline.
- **Model response:** the ledger attempt correlated to latest committed assistant response; a newer failed request does not replace it.

Each group has rows for input, output, reasoning, cache read, cache write, cache-hit ratio, and effective overall. Request-context and response-generated parent totals may appear as sublabels but are never added to children. `unavailable` renders an em dash plus explanation, not `0`; partial aggregates show known subtotal and missing contributor count; inconsistent values are withheld; provider-reported, derived-from-provider, estimated, and legacy are visibly distinct. A compact footer/gauge shows retained context against selected model bound plus short request/response/history totals and opens a dialog on wide screens or bottom sheet on narrow screens.

### 7. Design system is layered and feature code consumes semantics only

Create:

```text
lib/design_system/
  foundations/{primitive_tokens,semantic_tokens,dimensions,responsive_policy}.dart
  theme/{domovoy_theme,domovoy_theme_extension}.dart
  components/{app_surface,focus_ring,icon_action,menu_surface,status_chip}.dart
lib/features/chat/
  application/{chat_workspace_controller,chat_workspace_state,chat_timeline_projector,chat_token_presenter}.dart
  domain/{chat_selection,chat_title_policy,chat_deletion_intent}.dart
  presentation/{chat_workspace_page,workspace_shell,chat_sidebar,chat_timeline,chat_composer,model_selector,reasoning_selector,token_details,delete_chat_dialog,timeline_parts}.dart
```

Primitive values are private implementation inputs. Semantic tokens are a `ThemeExtension` for canvas/sidebar/surface/elevated/message/reasoning/tool/danger/focus colors, typography roles, borders/elevation, spacing/radius, icon/control sizes, and motion. `DomovoyTheme.dark()` is the default and `light()` maps the same roles. `DomovoyDimensions` owns central values including approximately `276` desktop sidebar width, header height, centered timeline/composer maximum width, minimum hit target, and narrow/desktop breakpoints. `WorkspaceLayoutSpec resolveWorkspaceLayout(Size, textScale)` is pure and contains all layout branching. Feature widgets use semantic values/components only; raw visual constants are lint/static-test forbidden outside design-system token files.

Existing API-key settings remain reachable and are wrapped/migrated to shared theme components where displayed from the workspace. This establishes one app-level theme source without requiring unrelated infrastructure changes.

**Alternative rejected:** a feature-local color/constants file. It would become a second theme and leave settings/focus behavior inconsistent. **Alternative rejected:** package adoption. Existing Material 3 plus local tokens is sufficient and avoids dependency churn.

### 8. Visual language and interaction details

Desktop is a dark edge-to-edge shell. The sidebar is about 276 px with a compact brand row, prominent quiet “New chat” action, scrollable title list, selected rounded row, and bottom settings action. A one-pixel semantic divider separates it from content. The content header is slim: drawer toggle only when needed, title/model context, token summary, and overflow delete action. The timeline is centered at a tokenized maximum width with generous vertical rhythm.

User messages are right-aligned low-chroma accent bubbles; assistant messages are left-aligned elevated-neutral bubbles. Reasoning is a recessed neutral disclosure with chevron and short muted preview/count when collapsed. Tool cards use a monospaced content well, outcome icon/label, status subtext, and expandable args/result sections. Errors use danger semantics without flooding the page.

The bottom composer is a rounded elevated pill/panel, fixed to the safe bottom and aligned to timeline width. The multiline field occupies the calm upper area. Its footer contains separate compact model and reasoning pills on the left and one high-contrast circular send/stop action on the right. There is no attachment affordance. Menus are anchored on desktop and full-width sheets on narrow screens. Model rows use radio/check state beneath non-selectable provider headings; reasoning rows never show invalid options.

Dark reference palette direction: near-black neutral canvas, slightly raised graphite sidebar/surfaces, subtle cool-gray borders, off-white primary text, muted gray secondary text, desaturated blue-lilac focus/accent, reserved red danger. Light theme mirrors hierarchy with warm-white canvas and cool-neutral surfaces. Exact color/radius/space values live only in design-system tokens. Text/control contrast targets WCAG AA.

Static preview: `mockups/chat-workspace-desktop.svg` (1440×960). It intentionally demonstrates the default dark desktop state, two bubbles, collapsed reasoning, a tool card, token summary, grouped selector intent, and active send state. It is ready for immediate display and does not block implementation.

### 9. Responsive, keyboard, semantics, and deterministic keys

Wide layout is sidebar plus content. Narrow layout removes sidebar from the row and exposes it through a drawer/chat-list route while preserving new/select/delete/settings. Dialogs become bottom sheets where width/focus demands. Timeline and composer account for safe areas, keyboard insets, text scaling, and no horizontal clipping.

Central shortcuts map Enter to send, Shift+Enter to newline, platform primary+N to new chat, primary+comma to settings, Escape to dismiss, and standard focus traversal. Shortcuts are disabled while a text-composition event is active where appropriate. Stop always remains keyboard reachable while busy. Focus returns to the invoking selector/delete control, deterministic neighbor, or new-chat action. Semantic live regions announce run start/terminal and tool/compaction outcome, not every token. Controls meet 44×44 minimum targets and expose stable keys such as `chat-new`, `chat-list`, `chat-row:<id>`, `chat-composer`, `model-selector`, `reasoning-selector`, `chat-send`, `chat-stop`, `chat-delete`, `delete-confirm`, `token-summary`, and timeline ids.

### 10. Slice and verification strategy

One writer works sequentially; each slice yields a user-observable or independently testable result and freezes a snapshot for a separate DeepSeek verifier:

| Slice | Result | Tier | Primary evidence |
|---|---|---:|---|
| H1 | Session selection/title contracts plus widget-free workspace lifecycle/controller | T2 | core/controller unit tests; codec/catalog backward compatibility; race negatives |
| H2 | Design system, responsive shell, and inspectable mockup-equivalent screens | T1 | token/static checks; dark/light desktop+narrow widget/goldens; semantics baseline |
| H3 | Typed timeline, stream reconciliation, tool/reasoning cards, composer and capability-driven selectors | T1/T2 | fake scheduler/event tests; widget/keyboard/semantics tests; invalid-capability negatives |
| H4 | Atomic model-switch compaction, stop/confirmed delete, token details, production JSONL/restart composition | T2 | transaction/cancel/conflict tests; fresh-stack restart; accounting matrix; Linux/web builds |
| H5 | Final whole-requirement verification on the integrated tree | per changed behavior | AC matrix, full format/analyze/test, all goldens, Linux/web builds, path/diff audit |

Heavy is required for all five slices by explicit user selection: Sol implements each assigned range and a separate DeepSeek context verifies its AC/formal criteria. There is no mandatory Sol code review or contract-review gate. A future material complexity change must be reported to the coordinator rather than silently changing mode. Final H5 reviews the complete remaining user feature, not only the last diff.

## Risks / Trade-offs

- **[T2: switch compaction incurs provider work even when switch fails/cancels]** → show progress and sanitized failure; exact physical usage is finalized and visible in history accounting; never describe failure as free.
- **[T2: model change invalidates opaque continuation]** → remove incompatible entries only in the acknowledged combined switch record, preserve normalized visible transcript, test switch-away/switch-back, and disclose no opaque payload.
- **[T2: cancellation/delete/save races can misreport success]** → one mutation lane, confirmation-bound identity, close-before-delete, expected revisions, commit-wins rules, no optimistic destructive UI, and negative tests with controllable repositories.
- **[T2: process death during switch/delete]** → rely only on acknowledged whole-record snapshots/tombstones; fresh dependencies restore either complete old or complete committed state and never resume work.
- **[T2: model-backed compaction usage must survive failed switch]** → reuse ledger finalization/checkpoint precedence and test completed/failed/cancelled/no-change with exact model correlation.
- **[T1: golden instability across hosts]** → use test fonts/fixed surfaces, deterministic fake data, bounded animation disabled in tests, and platform-independent widget goldens; Linux/web builds are separate smoke evidence.
- **[T1: long streams cause repaint pressure]** → immediate source reduction plus configurable notification pacing and terminal flush; benchmark/count notifications without delaying semantic state.
- **[T1: narrow menus or text scaling clip controls]** → pure size/text-scale layout policy, sheets on narrow screens, 200% text-scale widget tests, and minimum target checks.
- **[Compatibility: old records have no title/selection]** → derive selection from definition, keep title null, no eager migration, strict malformed-current-field rejection, unchanged JSONL envelope.

## Migration Plan

1. Add backward-compatible selection/title values, codec/catalog projections, session operation contracts, and tests without changing production destination.
2. Add the application controller and pure projections over those contracts.
3. Add design-system themes/components and chat shell; keep `PromptPage` available only as migration code until composition flips.
4. Add model-switch transaction, production compactor, lifecycle actions, token surface, and fresh-stack integration.
5. Switch `DomovoyApp` home to the chat workspace, remove obsolete prompt-only controller/page/settings reasoning seam only after replacement coverage, and run final H5 verification.

Rollback before new records are written is a destination revert. After current records exist, rollback must retain a codec capable of reading/ignoring the additive selection/title fields; do not downgrade by deleting JSONL data. Tombstones remain terminal under either version.

## Open Questions

None. Implementation details that do not alter these contracts (exact private class splits, animation curves, and test fixture text) may be chosen within the design-system and task boundaries.
