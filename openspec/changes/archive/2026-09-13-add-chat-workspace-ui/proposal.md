## Why

Domovoy already has durable agent sessions, compaction, a multi-provider model catalog, and truthful token projections, but production still exposes only transient one-shot prompts. The remaining user-facing feature is a persistent chat workspace that makes those committed capabilities usable as one coherent desktop-first and responsive experience.

## What Changes

- Replace the production one-shot page with a persistent chat workspace: session list, current timeline, create/select/restore, stop, confirmed delete, restart recovery, and retained API-key settings access.
- Add a testable session-scoped application controller that is the sole UI-facing owner of catalog/session/runtime commands and merges committed snapshots with live events into typed timeline state.
- Add per-chat durable `{providerId, modelId, reasoningMode, effort}` selection and a capability-driven provider-grouped model picker plus separate reasoning picker.
- Add an idle-only transactional model-switch operation. It validates the target, estimates target-shaped context, compacts through the configured compactor when required, and commits the compacted state and new selection together; failed, cancelled, no-change, conflicting, or busy attempts keep the old selection.
- Add stable deterministic chat titles from the first committed user message and deterministic stop-before-delete, tombstone, and neighbor-selection behavior.
- Present user/assistant bubbles, collapsed-by-default reasoning disclosures, tool status/content cards, compaction/error notices, and progressive streaming without duplicate persisted/live content.
- Present honest compact and detailed token accounting for current request, complete session/history, and latest model response, including input, output, reasoning, cache read/write, cache-hit ratio, and overall values with reported/derived/estimated/partial/unavailable labels.
- Introduce `lib/design_system/**` as the sole source for primitive and semantic visual tokens, themes, dimensions, responsive policies, focus behavior, and reusable components. Deliver a calm dark-primary desktop shell matching the supplied Codex reference, with coherent light and narrow-screen variants.
- Cover the independently verifiable domain/controller, design-system shell, timeline/composer, lifecycle/integration, and final whole-feature slices on Linux and web with deterministic visual regression evidence.

## Capabilities

### New Capabilities

- `chat-workspace-ui`: Persistent session navigation, timeline/composer presentation, capability-driven selection controls, lifecycle actions, accounting surfaces, responsive design-system behavior, and accessibility.

### Modified Capabilities

- `agent-runtime`: Add durable mutable session selection and an idle-only atomic model-switch operation while preserving immutable agent defaults and frozen in-flight request selection.
- `agent-session-compaction`: Add target-model switch compaction planning/validation and lifecycle semantics without exposing a partially compacted switch candidate.
- `agent-session-persistence`: Persist per-chat selection and stable title metadata, expose both in catalog summaries, and retain strict backward-compatible JSONL restart behavior.
- `llm-provider-core`: Expose UI-safe provider display metadata and deterministic registry enumeration so selectors never hard-code provider/model identities.
- `prompt-workspace`: Retire the transient one-shot/no-history production workspace requirements in favor of the new chat workspace while preserving settings reachability through the replacement UI.

## Impact

- Expected application areas: `lib/core/agents/**`, production composition in `lib/app.dart`, a new `lib/features/chat/**`, `lib/design_system/**`, and existing settings presentation integration.
- Expected tests: focused core/session/controller tests; widget, semantics, keyboard, responsive, and deterministic golden/visual tests; fresh-stack JSONL restart/integration tests; Linux and web builds; full Flutter analysis/test suite.
- Existing JSONL envelope remains unchanged; the versioned nested session record evolves backward-compatibly. No credentials, provider payloads, or opaque continuation data enter UI state.
- No new package is required by the plan. Attachments, markdown rendering, rename/search, tabs/worktrees, pricing/cost, permissions UI, file diffs, and external-agent support remain out of scope.
- Execution mode is **Heavy for every slice**, explicitly selected by the user. T2 applies to architecture, selection/compaction, persistence, deletion, cancellation, and restart slices; visual token/widget-only work is T1. Heavy uses Sol implementation followed by independent DeepSeek AC/formal verification, with no mandatory general Sol code review or approval gate.
