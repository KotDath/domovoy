# Chat Workspace UI Specification

## Purpose

Defines the persistent, capability-driven chat workspace through which users navigate durable conversations, observe agent activity, control execution, and inspect truthful token accounting on desktop and narrow screens.

## Requirements

### Requirement: Durable chat workspace lifecycle
The production application SHALL expose a session-scoped chat workspace backed by the configured durable session catalog and repository rather than the transient one-call prompt operation. Its application state SHALL support listing, creating, selecting, restoring, running, stopping, and deleting chats without presentation code directly mutating a repository or agent runtime. Startup SHALL select and restore the first healthy catalog item in catalog order, or show an actionable empty state when none exists. Creating a chat SHALL allocate and select a fresh repository-backed session. Selecting another chat SHALL close the prior idle live session without deleting it and restore the selected identifier. Unreadable catalog entries and catalog failures SHALL remain sanitized and SHALL NOT be presented as healthy empty history.

#### Scenario: Existing chats open after restart
- **WHEN** fresh production dependencies start with two acknowledged JSONL chats
- **THEN** the workspace lists both in catalog order, restores the first healthy chat, and shows its committed messages without using process state from the previous application instance

#### Scenario: No chat exists
- **WHEN** the durable catalog is empty
- **THEN** the workspace shows no selected conversation, an enabled new-chat action, and no fabricated chat or message

#### Scenario: User creates and switches chats
- **WHEN** the user creates a chat, commits a message, creates another chat, and selects the first
- **THEN** both stable identifiers remain listed, only the selected chat is current, and the first chat restores its acknowledged transcript

#### Scenario: Catalog contains an unreadable stream
- **WHEN** listing returns healthy summaries plus a sanitized unreadable-stream issue
- **THEN** healthy chats remain usable and the workspace presents a non-sensitive storage warning without inventing a chat for the unreadable stream

### Requirement: Deterministic titles and list selection
Each chat list item SHALL use its durable stable title, falling back to a localized new-chat label while no first user title exists. The title SHALL be derived once from the first committed user text by a configured deterministic policy that normalizes whitespace, removes control characters, applies a bounded grapheme-safe truncation, and never invokes a model. Catalog updates SHALL retain deterministic `updatedAt` descending then identifier ascending order. Deleting a non-selected chat SHALL preserve the selection. Deleting the selected chat SHALL choose the next item at the deleted item's pre-delete index, otherwise the previous item, otherwise no selection.

#### Scenario: First message establishes title
- **WHEN** a new chat commits its first user message containing repeated whitespace and text beyond the configured title bound
- **THEN** the catalog and sidebar expose one normalized, grapheme-safe deterministic title that remains unchanged after later messages, compaction, and restart

#### Scenario: Selected middle chat is deleted
- **WHEN** the selected chat is in the middle of the visible ordered list and deletion succeeds
- **THEN** the chat that followed it at the same pre-delete index becomes selected

#### Scenario: Last remaining chat is deleted
- **WHEN** deletion succeeds for the only listed chat
- **THEN** the list becomes empty and the workspace returns to the actionable no-selection state without silently creating a replacement

### Requirement: Serialized workspace commands and race safety
The workspace SHALL serialize state-changing commands for its selected session. A send, create, select, or selection-change command received while an incompatible run, restore, switch, compaction, deletion, or close is active SHALL return a typed busy outcome and SHALL NOT queue hidden work or alter the active operation. Stale asynchronous catalog, restore, stream, or operation completions SHALL be ignored by generation/identity. Optimistic conflicts SHALL refresh authoritative catalog/session state and present a sanitized conflict instead of overwriting a newer revision.

#### Scenario: Selection is requested during a run
- **WHEN** the user attempts to select another chat while the current chat is running
- **THEN** selection is rejected as busy, the current request continues unchanged, and no background restore starts

#### Scenario: Two sends race
- **WHEN** two sends are requested before the first run settles
- **THEN** exactly one run is admitted and the other receives a typed busy outcome without appending another user message

#### Scenario: Old restore completes late
- **WHEN** a superseded restore or catalog request completes after a newer workspace generation is active
- **THEN** its result cannot replace the current chat, timeline, selection, or error state

### Requirement: Capability-driven model and reasoning controls
The composer SHALL contain two distinct controls: a model selector and a reasoning selector. The model selector SHALL enumerate the injected registry, group models under provider display headings, preserve registry-derived names/capabilities, and contain no feature-local provider/model list. The reasoning selector SHALL derive valid modes and canonical efforts from the currently selected model: unsupported models expose disabled only, required models expose enabled only, optional models expose both, and explicit efforts are limited to the model's declared set with model-default available. Selecting a new model SHALL preserve the current reasoning pair only when valid for the target; otherwise it SHALL use the deterministic target default of disabled/model-default for unsupported models and enabled/model-default for required or optional models.

#### Scenario: Model menu opens
- **WHEN** the registered catalog contains models from several providers
- **THEN** the menu renders one provider heading per registry provider and its models beneath it without depending on a hard-coded count or identifier

#### Scenario: Non-reasoning model is selected
- **WHEN** a model whose reasoning capability is unsupported becomes current
- **THEN** the separate reasoning control exposes only disabled/model-default and cannot produce an enabled or explicit-effort selection

#### Scenario: Required-reasoning model has bounded efforts
- **WHEN** a required-reasoning model declares low, medium, and high efforts
- **THEN** reasoning cannot be disabled and the selector offers model-default, low, medium, and high but no undeclared effort

### Requirement: Subsequent-turn selection semantics
An acknowledged chat selection change SHALL affect only subsequent runs in that chat. Historical messages and per-attempt model attribution SHALL remain unchanged. An in-flight request SHALL retain the selection frozen at its admission and SHALL never observe a later choice. The exact per-chat selection SHALL restore after application restart. A selection operation that resolves to the exact current value SHALL be idempotent and SHALL perform no compaction, checkpoint, revision increment, or provider invocation.

#### Scenario: Model changes between turns
- **WHEN** one response completes under model A and an idle model switch to model B is acknowledged before the next send
- **THEN** history and model-A accounting remain unchanged and the next run uses model B with the acknowledged reasoning settings

#### Scenario: Exact selection is chosen again
- **WHEN** the user chooses the already active provider, model, reasoning mode, and effort
- **THEN** the operation reports unchanged without estimating, compacting, invoking a provider, or changing the durable revision

#### Scenario: Application restarts after reasoning change
- **WHEN** an idle reasoning-only change is acknowledged and fresh dependencies restore the chat
- **THEN** the restored composer and next run use that exact reasoning mode and effort

### Requirement: Stop and confirmed deletion
While provider, tool, approval, automatic compaction, or model-switch compaction work is active, the composer SHALL replace the send action with an enabled stop action that requests idempotent cooperative cancellation and retains already committed history plus visible partial output. A chat SHALL be deleted only after an explicit danger confirmation bound to the intended chat identity. Confirmed deletion of a busy chat SHALL first stop and await a stable acknowledged revision, then publish the durable tombstone; if stopping, stabilization, conflict resolution, or deletion fails, no successful deletion SHALL be reported. No undo is required and secure media erasure SHALL NOT be claimed.

#### Scenario: User stops streaming
- **WHEN** the user activates stop after partial reasoning or answer output
- **THEN** active work receives cancellation once, no later model/tool work begins, committed history remains, partial live output remains visibly marked interrupted, and the composer eventually returns to send state

#### Scenario: Delete is cancelled in confirmation
- **WHEN** the user opens delete confirmation and chooses cancel or dismisses it
- **THEN** no stop, repository delete, tombstone, list mutation, or selection change occurs

#### Scenario: Busy chat deletion is confirmed
- **WHEN** the user confirms deletion for the exact chat while it has active model work
- **THEN** the workspace stops that work, waits for its persistence outcome, tombstones the latest acknowledged revision only after stabilization, and applies deterministic neighbor selection after acknowledgement

#### Scenario: Stop cannot establish an acknowledged revision
- **WHEN** confirmed busy deletion encounters a persistence timeout, unreliable session, or revision conflict before a safe delete revision is known
- **THEN** the workspace reports a sanitized failure, refreshes authoritative state where possible, and does not claim or fabricate a tombstone

### Requirement: Duplicate-free typed timeline
The current conversation SHALL be projected from an immutable persisted session snapshot plus live operation deltas into ordered typed items for user messages, assistant content, reasoning, tool calls/results, compaction status, and sanitized errors. Persisted message identities SHALL be authoritative; live items SHALL use stable run/call/part identities and SHALL be replaced rather than appended when their committed counterparts appear. Configurable stream coalescing MAY reduce repaint frequency but SHALL preserve source order, flush the latest content at safe boundaries and terminal events, and never lose or duplicate text.

#### Scenario: Live assistant response commits
- **WHEN** reasoning and answer deltas are visible and the completed assistant message appears in a refreshed snapshot
- **THEN** the timeline replaces the live projection with the persisted message at the same logical position and displays every character exactly once

#### Scenario: Tool result becomes committed
- **WHEN** live tool events report a call and the next session snapshot contains its normalized arguments and correlated result body
- **THEN** one tool item transitions through its statuses and exposes the committed arguments/result without a duplicate tool card

#### Scenario: Terminal arrives before a scheduled repaint
- **WHEN** streaming coalescing has buffered the newest delta and a terminal event arrives
- **THEN** the buffered content is flushed before terminal status is projected

### Requirement: Message, reasoning, tool, compaction, and error presentation
User and assistant messages SHALL have visually distinct bubbles without changing transcript content. Every non-empty assistant reasoning part, including a currently streaming one, SHALL appear in a labeled block collapsed by default independently for that response and remain expandable without affecting execution. Tool blocks SHALL remain visible with tool name, status, normalized arguments, progress when available, result content when committed, and success/failure outcome; malformed display content SHALL fall back to selectable plain text. Compaction blocks SHALL expose operation status and estimates/provenance but no removed history, generated summary text, credentials, or opaque continuation payload. Errors SHALL be sanitized, actionable, separate from partial content, and offer settings access for missing credentials.

#### Scenario: Several responses contain reasoning
- **WHEN** restored history contains reasoning in two assistant messages
- **THEN** each response has its own initially collapsed disclosure and expanding one does not expand the other

#### Scenario: Tool arguments are not valid display JSON
- **WHEN** a persisted tool call contains arguments that cannot be pretty-printed
- **THEN** its tool card remains usable and presents the exact normalized argument string as selectable plain text

#### Scenario: Failure follows partial output
- **WHEN** a run fails after visible reasoning, answer, or tool progress
- **THEN** partial content remains visible and one sanitized error item describes the terminal outcome without exposing raw provider data

### Requirement: Honest three-view token accounting
The workspace SHALL consume immutable session token-accounting snapshots rather than maintain presentation totals. It SHALL provide a compact always-reachable summary and a detailed surface for (1) the active assistant request or otherwise latest finalized assistant request, (2) complete session/history work including assistant and model-backed compaction entries, and (3) the provider attempt correlated to the latest committed assistant response. Each detailed view SHALL display input, output, reasoning, cache read, cache write, cache-hit ratio, and effective overall where semantically available, plus model/correlation and completeness. Values SHALL distinguish provider-reported, derived-from-provider, estimated, partial known subtotal, legacy-unattributed, inconsistent, and unavailable states; unknown values SHALL render as unavailable rather than zero. Current retained-context estimate and target-model context bound SHALL be shown separately from provider usage.

#### Scenario: Provider reports complete cached usage
- **WHEN** the current request snapshot contains complete provider-derived input/output/reasoning/cache dimensions and overall
- **THEN** the request detail displays each non-overlapping value, cache-hit ratio, provenance, and model without double counting parent totals

#### Scenario: One session entry is incomplete
- **WHEN** complete session work has known usage for some attempts and no effective overall for another
- **THEN** history detail shows the known subtotal as partial, withholds a falsely complete overall, and identifies the missing contribution without showing zero

#### Scenario: Latest response differs from latest failed request
- **WHEN** a committed assistant response is followed by a failed provider request with no response message
- **THEN** current-request detail describes the failed attempt while model-response detail remains correlated to the earlier committed response

#### Scenario: Legacy chat is restored
- **WHEN** a legacy record has only unattributed cumulative usage
- **THEN** history identifies that legacy-inclusive amount while request, model-response, per-model, and unavailable dimensions remain unavailable

### Requirement: Single-source responsive design system
The production workspace SHALL obtain primitive scales, semantic color/typography/elevation/motion/focus tokens, dimensions, breakpoints, themes, and reusable controls from one design-system boundary. Feature presentation SHALL contain no raw color, radius, spacing, breakpoint, sidebar-width, or timeline-width values outside token definitions or pure responsive policy values. Dark SHALL be the primary presentation and SHALL use a calm low-chroma shell; light SHALL remain coherent on every configured Flutter platform. Provider/model counts, names, reasoning options, and list lengths SHALL derive from injected data rather than layout constants.

#### Scenario: Theme changes
- **WHEN** the same workspace state is rendered in dark and light themes
- **THEN** semantic roles, focus indication, hierarchy, status meaning, and component geometry remain coherent without feature-local color substitutions

#### Scenario: Registry grows
- **WHEN** another conforming provider and models are injected
- **THEN** selectors and layout render them from registry metadata without source changes to feature-local provider/model constants

### Requirement: Desktop and narrow workspace composition
At the central desktop breakpoint, the workspace SHALL show a fixed-width approximately 276-pixel left session sidebar and a right conversation surface with a slim header, centered bounded timeline, and bottom anchored rounded composer. The dark visual hierarchy SHALL follow the supplied Codex Desktop reference while the composer uses calm pill-shaped controls, progressive disclosure, and a clear filled send/stop state informed by Grok; OpenCode interaction structure is primary and ZCode/Zed are supporting references. Below the breakpoint, chat navigation SHALL move to a drawer or dedicated list route while timeline, model selector, reasoning selector, token details, stop, delete, new-chat, and settings actions remain reachable without clipping or horizontal scrolling.

#### Scenario: Desktop reference viewport renders
- **WHEN** the workspace is rendered at the reference desktop viewport
- **THEN** deterministic visual evidence shows the sidebar/header/centered-timeline/bottom-composer hierarchy, distinct message bubbles, calm dark tokens, and no legacy two-panel prompt layout

#### Scenario: Narrow viewport renders
- **WHEN** width falls below the central desktop breakpoint
- **THEN** the sidebar leaves the content row, chat navigation remains reachable, the composer reflows without obscuring selectors/actions, and the conversation has no horizontal overflow

### Requirement: Accessible keyboard and semantic operation
All workspace actions SHALL be keyboard reachable with visible focus, stable semantic labels and deterministic test keys. Enter SHALL send a non-empty idle draft, Shift+Enter SHALL insert a newline, Escape SHALL dismiss the topmost menu/drawer/dialog, and platform-appropriate new-chat and settings shortcuts SHALL be defined centrally. Interactive targets SHALL be at least 44 logical pixels, normal text and essential controls SHALL meet WCAG AA contrast, status changes SHALL be announced without announcing every streaming token, focus SHALL return predictably after dialogs and destructive actions, and reduced-motion preferences SHALL disable non-essential animation.

#### Scenario: Keyboard sends and edits multiline input
- **WHEN** the focused composer receives Shift+Enter followed by Enter while idle
- **THEN** the first command inserts a newline and the second submits the complete non-empty draft exactly once

#### Scenario: Screen reader observes active work
- **WHEN** a run starts, streams many deltas, and terminates
- **THEN** semantics announce a bounded start/status/terminal sequence, expose stop with the intended chat label, and do not create one live-region announcement per token

#### Scenario: Delete dialog closes
- **WHEN** delete confirmation is cancelled or completed
- **THEN** focus returns to the initiating chat/action when it still exists or to the deterministic selected/new-chat action otherwise

### Requirement: Settings reachability and explicit exclusions
Provider credential settings already supported by the application SHALL remain reachable from wide and narrow workspace states and from a missing-credential error. This capability SHALL NOT add attachments, a markdown engine, chat rename, search, tabs, worktrees, cost/pricing, permissions UI, file-diff panes, or external-agent support.

#### Scenario: Missing credential blocks a send
- **WHEN** the selected provider reports a sanitized missing-credential failure
- **THEN** the timeline error and workspace navigation both offer settings access while retaining the draft/history and exposing no credential value

#### Scenario: Workspace actions are inspected
- **WHEN** the delivered workspace is rendered on desktop and narrow layouts
- **THEN** no control claims an excluded attachment, rename, search, tabs/worktrees, pricing, permissions, diff, or external-agent capability
