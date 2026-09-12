## Acceptance Criteria

| AC | Verifiable outcome |
|---|---|
| AC-01 | Core repository/catalog contracts contain no filesystem/browser types; a replacement store and the in-memory store expose equivalent list/load/save/delete, optimistic revision, tombstone, and sanitized-error behavior. |
| AC-02 | Envelope-v1 JSONL deterministically replays full `AgentSessionCodec` snapshots, sequence/revision/identity transitions, continuation/compaction state, and no credentials or executable runtime values. |
| AC-03 | Fresh store/runtime instances over the same backing namespace list and restore every acknowledged chat and complete committed message history after restart. |
| AC-04 | Catalog summaries contain id/revision/timestamps/model/message count, sort by updated time descending then id ascending, omit tombstones, and return sanitized per-stream issues without hiding healthy sessions. |
| AC-05 | Same-process overlapping save/save, save/delete, and list/mutation operations linearize; exactly one same-revision mutation wins and stale/invalid revisions append nothing. |
| AC-06 | Cancellation before commit admission produces typed cancellation with no later mutation; cancellation after admission is commit-wins and returns success only after durable pointer acknowledgement. |
| AC-07 | Final partial lines recover to the latest complete record and are removed on the next commit; malformed internal lines, gaps, mismatches, unsupported versions, and bounds quarantine only that stream; crash-stage/orphan generations never become active. |
| AC-08 | Expected-revision delete survives restart, is absent from load/catalog, cannot be resurrected under the tombstoned id, and permits a new chat only under a fresh id; interrupted cleanup cannot reactivate old content. |
| AC-09 | Native production uses application-data filesystem JSONL and web production uses durable browser JSONL behind conditional injected storage; every backend failure is typed and there is no production in-memory fallback. |
| AC-10 | Production exposes the repository/catalog for future UI while the existing prompt workspace remains transient one-shot and creates no catalog entries. |
| AC-11 | `path_provider` and the browser storage package are direct dependencies, all configured platform declarations remain supported, formatting/analyze/tests pass, and web plus available native-host builds compile. |

## Heavy Slice Plan

**Recommended nearest Heavy slice — H1, tasks 1.1–2.5:** freeze the breaking core contract and deliver the storage-independent JSONL engine over deterministic atomic-storage fakes. Its independent result is a fresh repository instance that can list/restore/delete exact records and prove race, cancellation, version, corruption, and crash contracts without platform/plugin variability (AC-01–AC-08).

**Subsequent slices in this same change:** H2 tasks 3.1–3.3 adds native durable files; H3 tasks 4.1–4.3 adds durable browser storage and conditional compilation; H4 tasks 5.1–6.2 composes production, proves current prompt isolation, and completes integrated/formal verification. All slices use the user-selected Heavy route. No future backlog item starts until this change is accepted.

## 1. Core Repository and Catalog Contract

**Result:** replaceable core ports and in-memory parity are fixed before infrastructure depends on them.

**Expected paths:** `lib/core/agents/repository.dart`, optional `lib/core/agents/catalog.dart`, `lib/core/agents/agents.dart`, every `AgentSessionRepository` fake/implementation under `test/`, and `test/core/agents/repository_test.dart`.

- [x] 1.1 Add immutable catalog summary/snapshot/issue values and the companion catalog port; change delete to require expected revision plus operation cancellation, update exports and all compile-time implementers, and verify core source imports no `dart:io`, browser API, `path_provider`, or storage-package type (AC-01, AC-04).
- [x] 1.2 Bring `InMemoryAgentSessionRepository` to contract parity with deterministic listing, revision-checked cancellation-aware delete, retained minimal tombstones, and same-id resurrection rejection; verify ordering, summaries, create/update/delete conflicts, fresh-id creation, and serialized races in `flutter test test/core/agents/repository_test.dart` (AC-01, AC-04–AC-06, AC-08).
- [x] 1.3 Update runtime/fake delete call sites without changing checkpoint/restore semantics and verify existing delayed-save, cancellation, compaction commit-wins, malformed-record, and repository lifecycle tests still pass (AC-01, AC-05, AC-06).

## 2. Storage-Independent JSONL Engine — H1 Completion

**Result:** an injected atomic stream store provides deterministic fresh-instance persistence independent of native/web details.

**Expected paths:** new files under `lib/infrastructure/agents/jsonl/` such as `jsonl_agent_session_store.dart`, `jsonl_envelope.dart`, `jsonl_replay.dart`, and `jsonl_stream_storage.dart`; `test/infrastructure/agents/jsonl/jsonl_agent_session_store_test.dart`; focused fixtures/fakes under `test/support/`.

- [x] 2.1 Define the bounded opaque-key stream primitive, store coordinator, envelope-v1 upsert/tombstone codec, URL-safe id key mapping, and strict replay state machine; verify exact canonical fixtures for initial/update entries, newline framing, monotonic sequence/revision, key/envelope/record identity, configurable limits, and nested `AgentSessionCodec` round trips including continuation and compaction state (AC-01, AC-02, AC-07).
- [x] 2.2 Implement JSONL load/save and catalog projection over a deterministic persistent fake backend; reconstruct a new repository object over the same fake namespace and verify multiple sessions, complete message histories, metadata agreement, deterministic ordering, and replacement-store use (AC-01–AC-04).
- [x] 2.3 Implement mutation/list serialization and explicit cancellation admission; use controllable commit gates to verify save/save and save/delete winners, stale conflicts with no staged generation, list before-or-after snapshots, cancellation-before-admission with no late effect, and cancellation-after-admission commit-wins exactly once (AC-05, AC-06).
- [x] 2.4 Implement bounded recovery and issue isolation; verify final partial-line fallback and repair, internal malformed JSON, sequence gaps, identity/revision/transition mismatches, unknown envelope/record versions, line/stream limits, enumeration failure, pointer-before/after crash, orphan generation cleanup, and redacted issues with healthy sessions still listed (AC-02, AC-04, AC-07).
- [x] 2.5 Implement tombstone-only deletion and superseded-generation cleanup; reconstruct a fresh store and verify load/catalog absence, stale-delete conflict, cancelled delete, commit-wins delete, no same-id resurrection, fresh-id creation at revision zero, interrupted cleanup, and no repository recovery path to old messages (AC-05, AC-06, AC-08).

## 3. Native Filesystem Backend — H2

**Result:** Android, iOS, Linux, macOS, and Windows share a lazy application-data JSONL backend with crash-safe generation publication.

**Expected paths:** `pubspec.yaml`, `pubspec.lock`, new `jsonl_stream_storage_io.dart` and platform-neutral factory files under `lib/infrastructure/agents/jsonl/`, and `test/infrastructure/agents/jsonl/jsonl_filesystem_storage_test.dart`.

- [x] 3.1 Promote `path_provider` to a direct dependency and implement an injected/lazy application-support root resolver, opaque per-session namespace, immutable generation write+flush, atomic active-manifest replacement, bounded incremental reads, enumeration, and cleanup without leaking paths into core APIs; verify dependency resolution and static platform separation (AC-01, AC-09, AC-11).
- [x] 3.2 Using a temporary directory and fresh backend/repository instances, verify two-chat save/list/restore restart, full transcript/continuation/compaction round trip, ordering, update conflicts, delete/restart, tombstone reservation, and fresh-id replacement (AC-02–AC-05, AC-08, AC-09).
- [x] 3.3 Inject failures/crashes before generation completion, before manifest publication, and after publication plus partial/corrupt files and failed cleanup; verify old-or-new complete replay, typed no-fallback failures, orphan non-activation, per-chat quarantine, and no secret/path/raw-content error text (AC-06–AC-09).

## 4. Durable Browser Backend and Conditional Composition — H3

**Result:** web carries the same logical JSONL stream durably without importing native libraries or falling back to memory.

**Expected paths:** `pubspec.yaml`, `pubspec.lock`, new `jsonl_stream_storage_web.dart`, conditional factory/stub files under `lib/infrastructure/agents/jsonl/`, `test/infrastructure/agents/jsonl/jsonl_browser_storage_test.dart`, and focused platform-import checks.

- [x] 4.1 Add the chosen browser persistence package as a direct dependency and implement immutable generation keys plus final active-pointer publication using uncached/asynchronous APIs; verify key scoping, exact JSONL parity, bounded reads, enumeration, cleanup, and that write/pointer failures surface typed persistence errors (AC-02, AC-07, AC-09, AC-11).
- [x] 4.2 Run browser-targeted fresh-instance tests over the same origin-backed namespace for multi-chat list/restore, exact messages, ordering, conflict, cancellation gates, deletion/restart, tombstone reservation, quota/failure handling, and explicit absence of in-memory fallback (AC-03–AC-09).
- [x] 4.3 Complete conditional imports/exports so web compiles only the browser backend and IO platforms compile only filesystem code; verify analyzer/import-boundary tests reject `dart:io` from web/shared files and browser APIs from core/native files (AC-01, AC-09, AC-11).

## 5. Production Exposure and Integrated Restart

**Result:** future chat UI can consume production durable ports, while current visible prompt behavior remains unchanged.

**Expected paths:** `lib/app.dart`, JSONL infrastructure exports/factory, `test/app_composition_test.dart`, and focused integration support.

- [x] 5.1 Make `ProductionAgentStack`/`DomovoyDependencies` accept and expose the narrow repository/catalog ports, compose one lazy platform JSONL store in production, and inject it into the runtime; verify injected replacement identity and backend failures are surfaced rather than replaced by `InMemoryAgentSessionRepository` (AC-01, AC-09, AC-10).
- [x] 5.2 Add an integrated fresh-dependency restart test that commits two repository-backed sessions, reconstructs composition over the same storage, lists and restores every exact committed message/metadata field, deletes one, reconstructs again, and observes only the survivor (AC-03, AC-04, AC-08–AC-10).
- [x] 5.3 Preserve the prompt controller's one-call transient path and verify repeated prompt submissions remain separate, create no durable catalog entries, and retain existing streaming/settings/composition behavior (AC-10).

## 6. Formal Checks and Independent Heavy Verification

- [x] 6.1 Format with `dart format .`; run focused core/JSONL/filesystem tests, browser persistence tests with `flutter test --platform chrome test/infrastructure/agents/jsonl/jsonl_browser_storage_test.dart`, full `flutter analyze`, full `flutter test`, `flutter build web --debug`, and `flutter build linux --debug`; record cwd, commands, exit codes, concise outputs, exact checked diff/fingerprint, dependency versions, and unavailable-toolchain limitations (AC-01–AC-11).
- [x] 6.2 Freeze the implementation and have an independent DeepSeek verifier return PASS/FAIL/UNVERIFIED with evidence for AC-01–AC-11 and the negative race/recovery/delete/no-fallback scenarios; under selected Heavy mode no separate general Sol code review is required.
