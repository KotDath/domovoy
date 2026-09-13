## MODIFIED Requirements

### Requirement: Capability-driven model and reasoning controls
The composer SHALL contain two distinct controls: a model selector and a reasoning selector. The model selector SHALL enumerate the current validated catalog generation, group models under provider display headings, preserve registry-derived names/capabilities, and contain no feature-local provider/model list. It SHALL provide provider/model search and bounded scrolling or equivalent lazy presentation so large catalogs remain responsive and every listed model can be reached by keyboard, touch, and accessibility navigation. It SHALL expose refresh, freshness/source status, and actionable partial failure. A previously persisted but currently unavailable model SHALL be shown by its saved identity and SHALL require explicit supported replacement before a send. The reasoning selector SHALL derive valid modes and canonical efforts from the currently selected model: unsupported models expose disabled only, required models expose enabled only, optional models expose both, and explicit efforts are limited to the model's declared set with model-default available. Selecting a new model SHALL preserve the current reasoning pair only when valid for the target; otherwise it SHALL use the deterministic target default of disabled/model-default for unsupported models and enabled/model-default for required or optional models.

#### Scenario: Model menu opens
- **WHEN** the model menu opens after a catalog refresh
- **THEN** it displays the current validated provider groups, their models, and source/freshness status without a hard-coded provider count or credential values

#### Scenario: Non-reasoning model is selected
- **WHEN** a model with unsupported reasoning is selected
- **THEN** only disabled reasoning is available and the selection remains valid for later turns

#### Scenario: Required-reasoning model has bounded efforts
- **WHEN** a model requires reasoning and declares a limited canonical effort set
- **THEN** the selector excludes disabled reasoning and efforts outside that model's set

#### Scenario: Saved model is unavailable
- **WHEN** a restored chat refers to a model absent from the current validated catalog
- **THEN** its saved model remains visible as unavailable, the transcript stays readable, and sending is blocked until the user explicitly selects a supported model

#### Scenario: Provider has thousands of models
- **WHEN** a provider contributes a very large server-listed chat catalog
- **THEN** the picker remains responsive, supports name/id search and bounded scrolling, and allows selection of a model near the end without rendering every row eagerly

### Requirement: Honest three-view token accounting
The workspace SHALL consume immutable session token-accounting snapshots rather than maintain presentation totals. It SHALL provide a compact always-reachable summary and a detailed surface for (1) the active assistant request or otherwise latest finalized assistant request, (2) complete session/history work including assistant and model-backed compaction entries, and (3) the provider attempt correlated to the latest committed assistant response. The leading input value SHALL be the inclusive provider request-context total, the leading output value SHALL be the inclusive provider response-generated total, and the leading overall value SHALL count both once. Detail SHALL show exclusive uncached input and non-reasoning output only when clearly labeled as components, plus reasoning, cache read/write, and cache-hit ratio where semantically available, with model/correlation and completeness. Values SHALL distinguish provider-reported, exactly derived-from-provider, partial known subtotal, legacy-unattributed, inconsistent, and unavailable states; unknown values SHALL render as unavailable rather than zero. No estimator-derived token count, retained-context estimate, or estimated context-limit progress SHALL appear in the displayed token summary or details; internal runtime estimation and guards remain available.

#### Scenario: Provider reports complete cached usage
- **WHEN** a provider reports inclusive input 40, inclusive output 17, reasoning 15, and cache read 0
- **THEN** the request displays 40, the response displays 17, the combined invocation displays 57, reasoning displays 15, and no component is added again to its parent

#### Scenario: One session entry is incomplete
- **WHEN** one provider attempt has no usable overall total
- **THEN** the session view distinguishes known subtotal from unavailable full total and never displays a falsely complete sum

#### Scenario: Latest response differs from latest failed request
- **WHEN** a new provider request fails after an earlier committed assistant response
- **THEN** the current/latest request view identifies the failure attempt while latest response remains correlated with the earlier committed response

#### Scenario: Legacy chat is restored
- **WHEN** a saved chat contains only legacy unattributed cumulative usage
- **THEN** the history view labels that usage unattributed and no latest request, latest response, or per-model usage is invented

#### Scenario: Provider omits reasoning and cache counters
- **WHEN** a successful provider response has inclusive input/output totals but omits optional reasoning and cache data
- **THEN** inclusive totals remain visible and omitted optional dimensions show unavailable rather than zero

### Requirement: Settings reachability and explicit exclusions
Provider-scoped API-key settings SHALL remain reachable from wide and narrow workspace states and from a missing-credential error. Settings SHALL identify the selected provider and configured credential source without revealing the key and SHALL allow each built-in API-key provider's override to be added or removed separately. This capability SHALL NOT add attachments, a markdown engine, chat rename, search, tabs, worktrees, cost/pricing, permissions UI, file-diff panes, or external-agent support.

#### Scenario: Missing credential blocks a send
- **WHEN** the selected provider reports a sanitized missing-credential failure
- **THEN** the timeline error and workspace navigation both offer that provider's settings while retaining the draft/history and exposing no credential value

#### Scenario: Workspace actions are inspected
- **WHEN** the delivered workspace is rendered on desktop and narrow layouts
- **THEN** no control claims an excluded attachment, rename, search, tabs/worktrees, pricing, permissions, diff, or external-agent capability

#### Scenario: Two provider overrides are configured
- **WHEN** settings are opened after keys for two providers were saved
- **THEN** each provider shows its own configured status and removal action without showing either key

## ADDED Requirements

### Requirement: Provider error presentation
The workspace SHALL display a provider's available human-readable API failure message as plain selectable text after credential/authorization redaction, with provider and model identity. It SHALL preserve already streamed partial content and SHALL not replace a failed request's message with an estimated token explanation. A missing or unsafe provider message SHALL use an actionable sanitized fallback.

#### Scenario: Context overflow returns an API message
- **WHEN** a provider rejects a request for exceeding its context length and the attempt terminates
- **THEN** the timeline shows the provider's reported limit and requested-token explanation in plain text, with secret material redacted

### Requirement: Reproducible Day 8 token demonstration
The application SHALL offer a separately launched diagnostic scenario that runs short, long, and real over-limit requests through the selected configured API-key provider and shows the provider's inclusive request, response, and session usage for successful attempts. Its overflow case SHALL be able to generate a sufficiently large request without manually pasting text, SHALL bypass proactive compaction and overflow recovery only for that diagnostic run, and SHALL show the provider's terminal API error in plain text. This diagnostic SHALL not alter production chat compaction policy or silently fabricate usage for the failed call.

#### Scenario: Short and long requests are compared
- **WHEN** the user runs the provided short and long diagnostic cases with a configured provider
- **THEN** each result identifies the model, reports only available provider usage, and allows the growth in request/session tokens to be compared

#### Scenario: Real provider overflow is reproduced
- **WHEN** the user runs the diagnostic overflow case against a provider whose request exceeds its actual context limit
- **THEN** the provider receives the oversized request, the diagnostic performs no automatic compact-and-retry, and its returned error message is displayed without an estimated substitute
