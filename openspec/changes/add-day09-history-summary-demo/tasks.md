## 1. Runtime composition and cadence

- [x] 1.1 Add optional production-stack compaction injection while preserving default and diagnostic behavior; verify composition tests for baseline and custom policy.
- [x] 1.2 Implement a 10-completed-raw-message trigger with persisted logical count and no pending/duplicate advance; verify first and second cadence and restart in Day 9 tests, and no-change checkpoint semantics in the existing core compaction tests.
- [x] 1.3 Wrap the structured-summary compactor to retain two complete pairs and preserve candidate boundary, summary, reports, and durable metadata; verify retained suffix, summary prefix, and exact-once ledger tests.

## 2. Comparable application demo

- [x] 2.1 Add the shared ordered 14-prompt brief and two distinct durable production sessions; verify both modes receive identical prompts and restore progress/summary/usage after a fresh stack.
- [x] 2.2 Build a Day 9 page with next-step, run-all, reset, answer comparison, expandable prompt titles, saved summary/raw tail, and API-only assistant/summary/combined usage; verify initial unknown state and controls in the manual browser run, plus partial aggregate semantics in existing accounting tests.
- [x] 2.3 Add native and safe browser relay entrypoints plus concise recording/measurement guidance; verify external web output includes local font assets and no real key is compiled.

## 3. Final evidence

- [x] 3.1 Run focused cadence/persistence and accounting tests, manual browser UI, `dart format .`, `flutter analyze`, full `flutter test`, Linux debug and external web builds, strict OpenSpec validation, and repo diff check; record exact frozen changed-tree fingerprint, commands/results, and limitations in feature state.
