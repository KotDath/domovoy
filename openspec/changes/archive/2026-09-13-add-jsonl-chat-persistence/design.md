## Context

See `proposal.md` for motivation and the two delta specs for normative behavior. `AgentSessionRecord` already contains the complete restorable transcript, usage, immutable definition/model selection, timestamps, continuation metadata, and compaction state; `AgentSessionCodec` already enforces its typed record version. `AgentSessionRepository` currently has only load/save/delete, its production instance is in-memory, and the prompt controller deliberately uses transient one-call runs. There is no list projection or durable platform adapter. `path_provider` is currently transitive, and a `dart:io` implementation cannot compile as the web backend.

The design reuses the supplied OpenCode research rather than reopening it: append-only provenance, deterministic replay, optimistic sequence checks, crash-safe commit admission, derived listing, and cascade deletion. The legacy per-entity files/locks remain a useful comparison, but JSONL is the selected current format and the storage seam must permit later replacement.

## Goals / Non-Goals

**Goals:**

- Preserve core independence from files, browser APIs, package-specific storage types, and platform paths.
- Make a repository acknowledgement mean that a fresh store instance can replay the committed state after restart.
- Keep record serialization centralized in `AgentSessionCodec` while versioning the storage envelope separately.
- Make list/load/save/delete deterministic under same-process races, cancellation, corruption, and process loss.
- Isolate one unreadable chat from healthy catalog entries without silently restoring stale state.
- Give later workspace UI an injected repository/catalog while leaving today's one-shot prompt behavior unchanged.

**Non-Goals:**

- Chat workspace UI, titles, token-accounting changes, model/reasoning controls, tool/reasoning rendering, stop controls, or delete dialogs.
- Database/index engine, encryption, secure erase, cloud sync, cross-device synchronization, import/export, attachments, or multi-process writers.
- Persisting mailboxes, active runs/tools, approvals, cancellation resources, raw provider clients, credentials, partial assistant output, or removed pre-compaction history.
- Same-identifier recreation after deletion, log vacuum policy beyond deletion cleanup, or a general migration framework for unknown future versions.

## Decisions

### 1. Pair the repository with a small core catalog contract

Keep `AgentSessionRepository` as the record owner and add a separate `AgentSessionCatalog` implemented by the same concrete store. The repository continues to load and optimistic-save complete `AgentSessionRecord` values; delete becomes expected-revision and cancellation aware. The catalog returns `AgentSessionCatalogSnapshot(available, issues)`, where immutable summaries expose only id, revision, created/updated microseconds, model reference, and message count. Issues carry an optional parsed session id plus a typed sanitized reason, never raw bytes, paths, or browser keys.

Separating listing avoids turning the runtime into a storage browser and lets a replacement derive summaries from another index later. A convenience aggregate contract may implement both ports, but callers depend on the narrow interfaces. The in-memory adapter is updated to the same list/delete/tombstone semantics so tests and alternate composition do not hide contract differences.

Alternative: add `list()` directly to `AgentSessionRepository`. That is smaller but forces every runtime-only repository fake to implement a UI-oriented projection and makes future independently optimized catalogs harder. Alternative: list complete records. That copies transcripts unnecessarily and makes ordering/error isolation less explicit.

### 2. Store one logical JSONL operation stream per session

Each stream uses UTF-8 and a final newline. Envelope v1 has a stable typed discriminator, `version: 1`, `sessionId`, `sequence`, `operation`, and optimistic revision fields. `upsert` carries exactly one full map from `AgentSessionCodec.encode(record)`; `delete` carries no record content. Initial upsert is sequence 0 with record revision 0, each later upsert increments both sequence and record revision according to its expected revision, and delete uses the next sequence plus the active record revision. After deletion cleanup, that final tombstone is also valid as a standalone compacted terminal stream: its retained final sequence/revision prove the reserved identity without retaining earlier transcript entries.

Replay validates every field and transition before adopting the entry. Full snapshots intentionally trade space for simple deterministic restart, independent records, and migration clarity. They also avoid replaying runtime actions: replay selects data, never re-executes provider/tool effects. A future store can retain the core ports and codec while replacing physical JSONL.

Alternative: one global log gives a natural global sequence but couples every chat's corruption, growth, deletion, and rewrite. Alternative: one latest-state JSON file is smaller but loses append provenance and offers less direct recovery evidence. Alternative: event-level transcript persistence would duplicate runtime transactional semantics and require a much larger migration contract.

### 3. Use an injected atomic logical-stream primitive below JSONL

Infrastructure defines a package-private/platform-neutral primitive that enumerates opaque stream keys, reads one bounded logical stream, and atomically publishes a complete successor generation. The JSONL repository owns envelopes, codec, optimistic checks, replay, summaries, and locking; backends own only bytes/strings and generation publication. Session identifiers are encoded to URL-safe opaque keys, then verified again against every envelope, so arbitrary identifier text never becomes a path.

The native backend uses an application-support subdirectory resolved lazily through a direct `path_provider` dependency. It writes and flushes a new immutable generation, then atomically replaces a small active-generation manifest; manifest publication is the commit point. The browser backend uses a direct browser-capable persistence package (planned: `shared_preferences` asynchronous APIs) with immutable generation keys and a final active-pointer key. It carries the identical newline-delimited logical string. Writing the generation before the pointer means a crash exposes the old complete stream; writing the pointer selects the new complete stream. No web branch imports `dart:io`, and no production branch falls back to memory.

The repository is constructed synchronously with lazy asynchronous path/backend initialization so the existing synchronous Flutter dependency factory need not become an application-startup state machine. Initialization failure appears on the first requested operation as a sanitized persistence error.

Alternative: use shared preferences on every platform. That would avoid filesystem code but rewrite potentially large chat logs through settings APIs and not satisfy the preferred native JSONL-file representation. Alternative: use IndexedDB or a database abstraction. That is heavier than this independently verifiable change and contradicts the no-database boundary.

### 4. Define one explicit mutation linearization point

One store instance owns a coordinator that serializes mutation admission and catalog snapshots within the process. Per-session checks remain independent, but a simple store-wide queue is preferred initially because it makes list-vs-delete and pointer cleanup deterministic. Production exposes a singleton store; opening multiple writer instances over the same namespace and cross-process writes are unsupported rather than falsely safe.

Before queue entry and again at commit admission, save/delete inspect the operation cancellation token. If cancellation has won, the operation returns typed cancellation and never stages a logical successor. After admission, backend publication is deliberately non-cancellable: commit wins, later cancellation is ignored for that operation, and success is returned only after the active pointer is acknowledged. Expected revision is checked under the same coordinator. Conflict never stages or publishes an entry.

This is the concrete contract for the risky race: there is no state where an operation reports cancellation/conflict yet later becomes visible. The unavoidable platform write is moved wholly to the commit-wins side of the boundary.

Alternative: race cancellation directly against filesystem/browser writes. Those writes cannot reliably be rolled back and would violate the existing repository promise. Alternative: one lock per file plus unlocked catalog enumeration. That scales better but permits mixed list projections and is unnecessary for the current local assistant.

### 5. Treat a final fragment as uncommitted and internal damage as quarantine

Production defaults are configurable and initially cap one decoded line at 32 MiB and one stream at 256 MiB. Tests inject small limits. Native replay reads incrementally; browser replay checks stored string size before splitting/decoding. A final non-empty fragment lacking `\n` is ignored as an uncommitted append and removed when a later generation is built. An invalid complete line, sequence gap, identity mismatch, invalid transition, unsupported envelope, codec rejection, or size violation makes the session unreadable. Replay does not skip forward or return an older record as if current.

Catalog projection continues for other streams and returns a sanitized issue for the bad stream; direct load fails. Enumeration failure still fails the whole list because an allegedly complete catalog cannot be proven. Temporary files, generation values not selected by a valid manifest, and stale pre-commit pointers are orphan data and never replayed. Startup/access performs bounded best-effort cleanup.

Alternative: skip malformed internal lines and continue. That can combine states that were never a valid sequence. Alternative: fail the whole catalog on one chat. That lets one damaged file hide all healthy user history.

### 6. Delete by tombstone, reserve identifiers, and clean old generations

Delete requires the listed/loaded current revision. Under the coordinator it publishes a tombstone-only generation and flips the active pointer. This immediately makes load absent and catalog omit the id. Old transcript-bearing generations are then cleanup candidates; their failure or survival after a crash cannot make them active. Recovery removes them best-effort. This is logical cascade deletion, not secure media erasure.

The tombstone reserves the identifier permanently in that store. All later creates/updates of that id conflict, including stale writers from before deletion. A user-created replacement chat receives a fresh id and revision zero. This explicitly avoids the ABA bug where an old `expectedRevision: 0` writer could overwrite a newly recreated revision-zero chat.

Alternative: physically remove every file/key and permit same-id creation. Without adding an incarnation token to every record/save contract, stale work can resurrect or delete the replacement. A permanent minimal tombstone is the smaller and safer contract.

### 7. Expose durable storage without changing the prompt feature

`ProductionAgentStack` and `DomovoyDependencies` expose both narrow ports and accept an injected combined store for tests/future composition. Production creates the conditional JSONL store and injects its repository into `InMemoryAgentRuntime`; the runtime class name remains an execution implementation detail, not a statement about repository durability. The prompt controller continues calling one-shot `agent.run`, which creates transient sessions by contract, so this change does not invent a hidden chat lifecycle or UI state.

Restart integration tests create repository-backed sessions, commit distinct transcripts, close runtime/store owners, construct fresh repository/runtime instances over the same backend, list summaries, and restore exact records. Separate tests prove delete survives another reconstruction and that transient prompt calls never enter the catalog.

Alternative: silently change prompt submission to a repository-backed session. That would create chat selection/lifetime behavior with no UI contract and couple this storage change to the later workspace.

### 8. Dependencies and cross-platform verification are explicit

Promote `path_provider` to a direct dependency because production imports it to locate native application data. Add `shared_preferences` directly because its web implementation provides persistent origin-local strings/keys for the browser backend. Do not rely on transitive declarations. Conditional files isolate native and web APIs, with one shared interface checked by contract tests.

Implementation evidence must include `dart format .`, `flutter analyze`, `flutter test`, `flutter build web --debug`, and a debug build for the available native host (`flutter build linux --debug` in this workspace). Analyzer/contract tests cover both conditional source branches; dependency platform declarations must cover Android, iOS, web, Linux, macOS, and Windows. If a required toolchain is unavailable, the verifier records that platform build as UNVERIFIED rather than treating another platform as evidence.

### 9. Complexity, risk, and selected execution mode

- **Estimated complexity:** high. The slices touch a public repository contract, record projection, asynchronous cancellation, storage transactions, deletion, corruption recovery, conditional Flutter composition, and two durable backends.
- **Risk:** initial/current **T2**, separately from complexity, because this changes persistence format/migration, deletion, concurrency/cancellation linearization, and an architectural contract.
- **Unknowns contained by the design:** browser quota/commit failures and host filesystem behavior are isolated behind the atomic stream primitive; test fakes make admission, pointer publication, crash, and cancellation states deterministic. No product-level requirement remains unknown.
- **AC verifiability:** codec/envelope/replay and races are deterministic unit tests; fresh-instance restart and delete are integration tests; production no-fallback/composition and web/native conditional builds are formal checks.
- **Execution mode:** **heavy**, globally selected by the user and also the recommended mode for these linked states. Sol implements one frozen slice at a time; an independent DeepSeek verifier reports each AC/formal result. No general Sol code review or separate contract-review gate is required.
- **Planning boundary:** no product approval gate remains, but this assignment authorizes planning artifacts only; application/test implementation does not begin inside this assignment.

## Risks / Trade-offs

- [Full snapshots make per-chat logs grow quadratically with long transcripts] → enforce explicit bounds, isolate each chat, keep the backend replaceable, and leave vacuum/database work to a separately specified need.
- [Browser storage quota is materially smaller than native disk] → surface typed persistence failure, never report an in-memory success, use per-chat keys/generations, and verify restart through a fresh browser-backed instance.
- [Atomic rename/pointer guarantees vary by platform] → stage and flush immutable generations before one pointer publication, replay only a valid selected generation, and test both crash sides through the primitive.
- [Cancellation arrives during an uncancellable platform write] → declare admission as the linearization boundary and require commit-wins completion after it.
- [Malformed data could hide acknowledged content] → accept only an incomplete final fragment as uncommitted; quarantine internal/unknown-version damage and expose a sanitized catalog issue.
- [Deletion can leave physical remnants after crash or storage wear] → tombstone makes them unreachable and recovery cleans superseded generations; explicitly make no secure-erasure claim.
- [Permanent tombstones consume small space and forbid same-id recreation] → preserve only minimal metadata and generate a fresh identifier for every replacement chat, preventing stale-writer ABA.
- [A broad core signature change affects test fakes] → make it once in the first slice, update in-memory parity and all implementers, then freeze the contract before infrastructure work.

## Migration Plan

1. Add catalog/result values and strengthen delete semantics; update in-memory behavior and all repository fakes before adding durable adapters.
2. Add storage-envelope v1, strict replay/projection, limits, tombstones, and deterministic storage/coordinator fakes.
3. Add native generation/manifest storage and fresh-instance filesystem restart/delete/recovery tests.
4. Add browser generation/pointer storage, conditional factory, direct dependencies, and web restart/no-fallback tests.
5. Inject/expose the durable store in production composition while retaining transient one-shot prompts; run integrated and platform checks.

There is no existing production durable session data to import: prior production sessions are process memory and cannot be recovered. Rollback may restore the old in-memory composition while leaving JSONL data untouched; it must not claim those durable chats are visible. Future envelope migration adds a new reader/writer version or a replacement adapter while continuing to delegate nested records to `AgentSessionCodec`; unsupported versions remain fail-closed.
