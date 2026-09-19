## MODIFIED Requirements

### Requirement: Message, reasoning, tool, compaction, and error presentation
User messages SHALL appear as compact raised blocks aligned to the right, while
assistant answers SHALL use a prose-first surface without a surrounding message
card. Assistant text SHALL render only headings, paragraphs, ordered and unordered
lists, emphasis, strong emphasis, inline code, fenced code, and link labels from
Markdown; arbitrary HTML, images, tables, task lists, and embedded executable or
interactive content SHALL NOT be rendered. Links SHALL have no outbound action in
this slice, regardless of scheme. Streaming Markdown SHALL remain readable during
incomplete delimiters and SHALL settle to the same rendering as the completed
text without changing transcript content. Every non-empty assistant reasoning
part, including a currently streaming one, SHALL appear in a labeled block
collapsed by default independently for that response and remain expandable
without affecting execution. Tool blocks SHALL remain visible with tool name,
status, normalized arguments, progress when available, result content when
committed, and success/failure outcome; malformed display content SHALL fall back
to selectable plain text. Compaction blocks SHALL expose operation status and
estimates/provenance but no removed history, generated summary text, credentials,
or opaque continuation payload. Errors SHALL be sanitized, actionable, separate
from partial content, and offer settings access for missing credentials.

#### Scenario: Several responses contain reasoning
- **WHEN** restored history contains reasoning in two assistant messages
- **THEN** each response has its own initially collapsed disclosure and expanding one does not expand the other

#### Scenario: Tool arguments are not valid display JSON
- **WHEN** a persisted tool call contains arguments that cannot be pretty-printed
- **THEN** its tool card remains usable and presents the exact normalized argument string as selectable plain text

#### Scenario: Failure follows partial output
- **WHEN** a run fails after visible reasoning, answer, or tool progress
- **THEN** partial content remains visible and one sanitized error item describes the terminal outcome without exposing raw provider data

#### Scenario: Supported Markdown completes after streaming
- **WHEN** an assistant answer streams incomplete Markdown and then completes with headings, lists, emphasis, inline code, a fenced code block, and a link
- **THEN** intermediate content remains readable and the completed answer renders the bounded syntax once without losing or duplicating text

#### Scenario: Unsafe or unsupported markup is received
- **WHEN** assistant text contains raw HTML, script markup, an image, a task list, a table, or a non-HTTP link target
- **THEN** no HTML executes, no image or rich embedded control is created, no external action occurs, and the original text remains safely readable

### Requirement: Desktop and narrow workspace composition
At the central desktop breakpoint, the workspace SHALL follow the approved
`final-01` composition: an approximately 270-pixel compact left navigation rail,
a slim header with project-status icon and chat title, a centered approximately
700-pixel prose timeline, and a bottom composer aligned to that timeline. The
visual hierarchy SHALL use the approved low-chroma graphite/warm-neutral surfaces,
periwinkle accent, restrained one-pixel borders, and compact typography in both
dark and light themes. User content, assistant prose, and the composer SHALL
remain the primary visual emphasis. Below the breakpoint, navigation SHALL move
behind a menu while timeline, model selector, reasoning selector, context detail,
send/stop, delete, new-chat, provider settings, and theme actions remain reachable.
At 390 by 844 logical pixels the workspace and every open first-slice menu,
popover, sheet, or dialog SHALL remain within the viewport without horizontal
overflow.

#### Scenario: Desktop reference viewport renders
- **WHEN** the workspace is rendered at the reference desktop viewport in dark or light theme
- **THEN** deterministic visual evidence matches the approved sidebar/header/prose-timeline/aligned-composer hierarchy without prototype labels or sample data

#### Scenario: Narrow viewport renders
- **WHEN** the workspace is rendered at 390 by 844 logical pixels in dark or light theme
- **THEN** navigation is available behind the menu, all current-chat controls remain reachable, and neither the base view nor an open overlay has horizontal overflow

#### Scenario: High text scale uses safe composition
- **WHEN** text scaling makes the desktop row unsafe
- **THEN** the workspace uses its narrow fallback and keeps actions readable and reachable rather than clipping controls

### Requirement: Accessible keyboard and semantic operation
All workspace actions SHALL be keyboard reachable with visible focus, stable
semantic labels, and deterministic test keys. Enter SHALL send a non-empty idle
draft, Shift+Enter SHALL insert a newline, Escape SHALL dismiss only the topmost
menu, popover, sheet, drawer, or dialog, and platform-appropriate new-chat and
settings shortcuts SHALL remain defined centrally. Opening an anchored selector
SHALL move focus into it; selecting or dismissing it SHALL return focus to its
trigger. Provider and model columns SHALL support directional/Tab traversal and
selection without hover, and the narrow fallback SHALL provide equivalent focus
and semantics. Interactive targets SHALL be at least 44 logical pixels, normal
text and essential controls SHALL meet WCAG AA contrast, status changes SHALL be
announced without announcing every streaming token or timer tick, and
reduced-motion preferences SHALL disable non-essential animation.

#### Scenario: Keyboard sends and edits multiline input
- **WHEN** the focused composer receives Shift+Enter followed by Enter while idle
- **THEN** the first command inserts a newline and the second submits the complete non-empty draft exactly once

#### Scenario: Screen reader observes active work
- **WHEN** a run starts, streams many deltas while its visible elapsed label updates, and terminates
- **THEN** semantics announce a bounded start/status/terminal sequence, expose stop with the intended chat label, and do not announce each token or elapsed-second tick

#### Scenario: Topmost overlay closes
- **WHEN** a keyboard user opens a picker or popover and presses Escape
- **THEN** only that topmost surface closes and focus returns to its trigger

#### Scenario: Delete dialog closes
- **WHEN** delete confirmation is cancelled or completed
- **THEN** focus returns to the initiating chat/action when it still exists or to the deterministic selected/new-chat action otherwise

### Requirement: Settings reachability and explicit exclusions
Provider-scoped API-key and model-discovery settings SHALL remain reachable from
wide and narrow workspace states and from a missing-credential error. Settings
SHALL identify providers, actual credential source/configured state, actual
catalog contents, and refresh outcomes without revealing a stored or environment
credential value. A replacement credential MAY be entered only through the
existing obscured credential control and SHALL never be prefilled from storage.
This capability SHALL consume but SHALL NOT add or alter the accepted Project
persistence, membership, creation, deletion, directory selection/grant, or path-
policy contracts from `add-project-workspaces`. It SHALL NOT add filesystem tools,
attachments, runtime context composition, global/time-bucket usage analytics,
cost/pricing, chat rename, search, tabs, worktrees, file-diff panes, or external-
agent support.

#### Scenario: Missing credential blocks a send
- **WHEN** the selected provider reports a sanitized missing-credential failure
- **THEN** the timeline error and workspace navigation both offer that provider's settings while retaining the draft/history and exposing no credential value

#### Scenario: Workspace actions are inspected
- **WHEN** the delivered workspace is rendered on desktop and narrow layouts
- **THEN** Project controls and access status reflect only accepted Project capability results, while no enabled control claims project-file operations, attachment, context-composition, pricing, global usage, rename, search, tabs/worktrees, diff, or external-agent capability

#### Scenario: Two provider overrides are configured
- **WHEN** settings are opened after keys for two providers were saved
- **THEN** each provider shows its own configured source/status and removal action without showing or prefilling either key

#### Scenario: Provider catalog is unavailable
- **WHEN** discovery is stale, partially failed, or unavailable
- **THEN** settings and selectors show the actual safe source/freshness/failure state and do not substitute prototype provider counts, model names, or connection claims

## ADDED Requirements

### Requirement: Truthful Project-backed navigation in the approved shell
This change SHALL start only after `add-project-workspaces` is accepted. The
approved `Проекты` section SHALL render every healthy Project with exactly its
durable member chats, while `Чаты` / `Без проекта` SHALL render null and
recoverable unresolved memberships exactly once with any sanitized dependency
warning. Project creation, selection, disclosure, regrant where supported,
deletion, and Project-scoped or unassigned new-chat actions SHALL invoke only the
accepted Project workspace commands and preserve their capability/cancellation/
recovery semantics. On unsupported platforms Project creation SHALL remain
disabled with the accepted explanation while unassigned chats remain usable. The
header project-status surface SHALL show the selected real Project and latest safe
root/access label, or `Без проекта` with root `—`; it SHALL NOT infer membership,
display a sample path, expose grant material, or claim file access stronger than
the latest broker result.

#### Scenario: Projects and legacy chats render
- **WHEN** accepted catalogs contain two healthy Projects, their member chats, null-membership chats, and one recoverable unresolved membership
- **THEN** every chat appears exactly once beneath its real Project or `Без проекта`, with no grouping inferred from title/provider/path and no fabricated root or permission

#### Scenario: User creates a chat in the selected context
- **WHEN** the user invokes new chat while a healthy Project or `Без проекта` is selected
- **THEN** the accepted scoped creation command runs exactly once and the durable chat appears only in that selected Project or unassigned group

#### Scenario: User creates a Project on a supported platform
- **WHEN** the Project add action is activated and the accepted creation flow commits successfully
- **THEN** the real empty Project becomes selected and visible without an implicit chat, file operation, or locally fabricated access status

#### Scenario: Project creation is unsupported or access is lost
- **WHEN** the accepted capability reports unsupported creation, requires regrant, or reports revoked/missing/corrupt/unverifiable access
- **THEN** the shell preserves Project/chat navigation, mirrors that sanitized status and available action exactly, and grants no file operation or stronger active claim

### Requirement: Runtime theme choice
The application SHALL start in System theme mode and resolve dark or light from
the platform. It SHALL expose System, Dark, and Light choices from the approved
workspace navigation; selecting Dark or Light SHALL override System for the
current application process only, and selecting System SHALL resume following
platform brightness changes. This slice SHALL NOT persist a theme override.

#### Scenario: Application starts with a light platform theme
- **WHEN** the application starts without an in-process choice and platform brightness is light
- **THEN** the workspace uses the approved light semantic tokens

#### Scenario: User selects and resets an override
- **WHEN** the user selects Dark and later selects System
- **THEN** the workspace first uses dark tokens and then resumes the current platform brightness without writing preference storage

#### Scenario: Platform changes while override is active
- **WHEN** platform brightness changes while Dark or Light is explicitly selected
- **THEN** the explicit in-process selection remains effective until System is selected or the process restarts

### Requirement: Honest live work-duration label
For the current admitted chat run, the workspace SHALL measure elapsed work from
run admission with a monotonic time source. While that run remains non-terminal,
the associated assistant response SHALL show `Работает N с` or the equivalent
minute/second form and update visually no more than once per second. Completion,
failure, provider stop, or acknowledged cancellation SHALL freeze the duration
and change the label to `Работал N с`, with terminal status remaining separately
available. A stop request alone SHALL NOT freeze or reset the timer before the
terminal event. The duration SHALL remain available only while that current live
run state remains in memory; switching/restoring a chat, admitting another run,
or restarting the application SHALL omit the label rather than invent or persist
a duration for historical answers.

#### Scenario: Run completes normally
- **WHEN** a current run remains active across several monotonic seconds and then completes
- **THEN** one visible label advances by elapsed whole seconds during work and freezes at the terminal elapsed value with `Работал`

#### Scenario: Stop is requested more than once
- **WHEN** stop is activated repeatedly before cancellation reaches a terminal event
- **THEN** cancellation remains idempotent, one timer continues from the original admission, and it freezes only on the terminal event

#### Scenario: Wall clock changes
- **WHEN** calendar time moves backward or forward while a run is active
- **THEN** displayed elapsed duration remains monotonic and does not jump with wall-clock time

#### Scenario: Historical duration is unavailable
- **WHEN** an answer is restored after navigation or application restart without persisted timing data
- **THEN** no zero, guessed duration, or misleading `Работал` value is shown

### Requirement: Composer context control uses committed accounting only
The composer SHALL place a compact context control beside send/stop. Its upward
desktop popover and narrow-screen fallback SHALL use only the selected session's
existing immutable token-accounting projection and selected model metadata. It
MAY show current/latest provider-reported inclusive request input, declared model
context bound, and a derived ratio only when both operands are available and
clearly labeled. Any unavailable operand or token dimension SHALL display `—`,
never zero; a partial subtotal SHALL retain its partial marker. The control SHALL
NOT display estimated retained context, instructions/files/provider breakdowns,
future context-composition controls, or prototype sample numbers.

#### Scenario: Reported input and declared limit are available
- **WHEN** the current/latest request has provider-reported inclusive input and the selected model has a declared context bound
- **THEN** the control shows both values and their labeled ratio without adding cache or reasoning components again

#### Scenario: Context value is unavailable
- **WHEN** the provider omits request input or the selected model has no trustworthy context bound
- **THEN** the missing value and progress appear as `—`, the ring does not imply zero percent, and no estimator substitutes a value

#### Scenario: Prototype categories are absent
- **WHEN** the context detail is opened for a real Project-scoped or unassigned chat
- **THEN** it contains no fabricated instruction, file, project, provider-data, or permission token category

### Requirement: Upward provider-model and reasoning pickers
On desktop, the model trigger SHALL open above the composer as a two-stage
provider-to-model cascade sourced only from the current validated catalog.
Provider activation by pointer, click, or focus SHALL reveal that provider's
models without changing the selected model until a model is activated. The
surface SHALL have bounded height; provider and model lists SHALL scroll or lazily
build rows, and search by provider display name, model name, or model identifier
SHALL keep very large catalogs usable. On narrow layouts, the same catalog SHALL
use a viewport-safe searchable sheet instead of a clipped cascade. The separate
reasoning trigger SHALL open above the composer on desktop and use a viewport-safe
sheet on narrow layouts. Its choices SHALL be derived exactly from the current
model's capabilities: unsupported reasoning has only disabled/default, required
reasoning cannot be disabled, optional reasoning exposes disabled plus enabled
default and only declared efforts. Unavailable saved models, stale/partial
catalog state, and providers with no selectable models SHALL remain truthful and
shall not silently select a substitute.

#### Scenario: Keyboard user selects from the cascade
- **WHEN** a keyboard user opens the desktop model picker, focuses another provider, and activates one of its models
- **THEN** focusable provider/model columns remain above the composer, only the explicit model activation changes selection, the picker closes, and focus returns to the trigger

#### Scenario: Catalog contains thousands of models
- **WHEN** a provider supplies thousands of validated models
- **THEN** bounded/lazy presentation and search allow a keyboard or touch user to reach a model near the end without laying out every row at once

#### Scenario: Narrow picker opens
- **WHEN** the model or reasoning trigger is activated at 390 by 844 logical pixels
- **THEN** a searchable model sheet or capability-derived reasoning sheet stays inside the viewport and returns focus to its trigger on selection or dismissal

#### Scenario: Model does not support reasoning
- **WHEN** the selected model declares reasoning unsupported
- **THEN** the reasoning control communicates the disabled/default state and cannot produce an enabled or explicit-effort selection
