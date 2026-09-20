# Day 11 task DAG

The implementation is intentionally sequential so one OpenCode session can
retain architectural context. A task is ready only after its predecessor has
settled, been reviewed, and any coordinator fixes have passed targeted tests.

```text
MEM-01 -> MEM-02 -> MEM-03 -> MEM-04 -> MEM-05 -> MEM-06 -> MEM-07
```

## MEM-01 — Default project

Add `ProjectKind`, migrate project JSON, implement the protected `default`
project and managed sandbox roots, migrate unassigned sessions, and reassign
members of deleted projects. Acceptance: project/unit/platform tests prove
idempotent bootstrap, root recovery, migration, and deletion protection.

## MEM-02 — Memory domain

Add memory identifiers, layers, scopes, kinds, statuses, entries, candidates,
read plans, traces, validation, and repository/service contracts. Acceptance:
pure domain tests cover valid transitions, scope/layer invariants, revisions,
immutability, source provenance, and secret rejection.

## MEM-03 — JSONL persistence

Implement independent working, long-term, candidate, and extraction-state
stores plus native/web factories. Acceptance: round-trip, replay, tombstone,
conflict, truncated-tail, corruption, namespace-isolation, and platform-import
tests pass.

## MEM-04 — Retrieval and context

Implement project/global retrieval, lexical ranking, budgets, safe rendering,
runtime request integration, and `MemoryContextTrace`. Acceptance: scripted
providers observe exactly the enabled records; memory never enters transcripts
or disappears during compaction/model switching.

## MEM-05 — Extraction

Implement explicit phrase candidates, registry-backed batch extraction, strict
JSON parsing, window/overlap, idle/manual flush, checkpoints, single-flight, and
mobile lifecycle recovery. Acceptance: fake-clock and scripted-LLM tests prove
that normal turns do not invoke extraction individually and failures are safe.

## MEM-06 — Application and UI

Add memory state/controllers, adaptive inspector, candidates, confirmation,
edit/forget, read toggles, extraction status, and trace display. Acceptance:
widget tests cover phone, tablet, desktop, keyboard/back behavior, busy/error
states, and correct layer routing.

## MEM-07 — Integration and hardening

Complete restart, default/user-project isolation, lifecycle, prompt-injection,
secret, and end-to-end tests; update documentation and run the live demo.
Acceptance: all repository checks, Android build/emulator smoke, Linux smoke,
and the documented memory/no-memory comparison succeed.

