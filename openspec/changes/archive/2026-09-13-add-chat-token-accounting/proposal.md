## Why

The current nullable, cumulative `LlmUsage` loses provider semantics and cannot identify the request, assistant response, model, retry, or compaction operation that incurred usage. A durable provider-first accounting contract is required before a later chat UI can truthfully show current-request, retained-history, response, and conversation totals after restart.

## What Changes

- Normalize provider usage at the adapter boundary into mutually exclusive input, cache-read, cache-write, output, and reasoning dimensions, while preserving non-additive provider input/output/overall totals, provenance, completeness, and sanitized inconsistency metadata.
- Define provider-independent normalization helpers for inclusive/exclusive counter semantics and aliases; malformed, negative, conflicting, or missing usage fields remain unavailable instead of being guessed or double-counted.
- Add an immutable per-provider-attempt ledger with stable session/run/turn/attempt/message or compaction-operation correlation and the exact selected model. Retries and tool-loop turns are distinct attempts; compaction is a distinct operation kind and never an assistant response.
- Make cumulative assistant-conversation, compaction, session, and per-model totals projections of finalized ledger entries plus an explicit legacy baseline, rather than independently mutable totals.
- Expose immutable accounting snapshots for an active-or-latest assistant request, latest committed assistant response, current retained request-shaped context, cumulative assistant work, compaction work, complete session work, and model grouping. Every displayed value carries enough source/completeness information to distinguish provider-reported, derived-from-provider, estimated, partial, and unavailable values.
- Persist finalized ledger entries in `AgentSessionRecord` and restore them through the existing record codec/JSONL store. Records without accounting data decode as generation zero with an empty ledger and their prior coarse usage retained only as an unattributed legacy baseline.
- Finalize each dispatched provider attempt at most once across repeated usage snapshots, terminal repetition, retries, overflow recovery, failures, and cancellation; persist observed provider work at existing safe lifecycle boundaries without claiming recovery of an unacknowledged in-flight attempt after process loss.
- Extend model-backed compaction reporting so same-model and alternate-model attempts enter the ledger with compaction identity, while deterministic compaction contributes no fabricated provider usage.
- Keep pricing/cost, a new tokenizer, chat UI, external analytics, database migration, provider-specific runtime branching, and guessing unsupported-provider dimensions out of scope.

## Capabilities

### New Capabilities
- `chat-token-accounting`: Canonical token semantics, immutable public projections, durable per-attempt ledger, legacy decode, and exact-once lifecycle behavior for assistant and compaction model work.

### Modified Capabilities
- `llm-provider-core`: Replace coarse usage semantics with provider-boundary normalization for Chat Completions and Responses, including reasoning/cache aliases, provenance, completeness, and safe inconsistency handling.
- `agent-runtime`: Correlate and finalize physical provider attempts, expose accounting snapshots/events, derive cumulative usage and budgets without duplicate accumulation, and persist/restore the ledger.
- `agent-session-compaction`: Report model-aware compaction attempts into the same ledger without representing them as assistant responses.

## Impact

- Core public contracts: `lib/core/llm/usage.dart`, LLM events, agent identifiers/events/snapshots/records/runtime, compaction result/error reporting, and exports.
- Provider adapters: OpenAI-compatible Chat Completions and OpenAI Responses usage mappers plus fixture coverage for supported aliases and inclusive/exclusive semantics.
- Persistence: backward-compatible `AgentSessionRecord` additions carried by the existing codec and JSONL full-record snapshots; no storage-envelope or database migration is planned.
- Verification: focused normalization, aggregation, lifecycle, provider-fixture, codec, JSONL fresh-instance restart, retry/cancellation/failure, tool-loop, model-switch-ready, and compaction tests; repository-wide Dart formatting, Flutter analysis, and full tests. Platform builds are required only if implementation changes platform-conditional code or dependencies.
