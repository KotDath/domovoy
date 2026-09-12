# Agent Session Persistence Specification

## Purpose

Defines durable, replaceable, cross-platform storage and catalog behavior for committed agent sessions so chats can be listed and restored after application restart.

## Requirements

### Requirement: Replaceable durable session storage on every configured platform
The production application SHALL expose one injected session repository and companion catalog through platform-neutral contracts. Repository-backed sessions acknowledged by that store SHALL survive disposal and reconstruction of the application dependencies on Android, iOS, Linux, macOS, Windows, and web. Native/mobile/desktop production SHALL use application-data filesystem storage, web production SHALL use durable browser storage carrying the same logical JSONL streams, and backend initialization or access failure SHALL surface as a typed sanitized persistence failure rather than substitute an in-memory store. The existing one-call prompt operation SHALL remain transient until the separately planned chat workspace adopts repository-backed sessions.

#### Scenario: Native application restarts
- **WHEN** two repository-backed sessions with committed messages are closed, production dependencies are disposed, and fresh dependencies open the same native application-data location
- **THEN** the catalog lists both sessions and each identifier restores its exact last acknowledged record and complete committed transcript

#### Scenario: Browser application restarts
- **WHEN** a repository-backed session is acknowledged in browser storage and a fresh application instance opens the same browser origin
- **THEN** the catalog lists the session and restoration returns its exact last acknowledged record without using process memory from the prior instance

#### Scenario: Durable backend is unavailable
- **WHEN** production cannot initialize, enumerate, read, or commit its platform durable backend
- **THEN** the requested storage operation fails with a typed sanitized persistence error and no in-memory success is reported

#### Scenario: Current one-call prompt runs
- **WHEN** the existing prompt workspace submits multiple one-call requests after durable storage is composed
- **THEN** those calls remain distinct transient sessions and do not appear in the durable session catalog

#### Scenario: Caller injects another store
- **WHEN** composition receives a conforming replacement repository and catalog
- **THEN** runtime checkpoints, listing, restoration, and deletion use that replacement without importing filesystem or browser types into core agent APIs

### Requirement: Versioned JSONL operation streams
Each stored session SHALL have one logical UTF-8 JSONL stream. Every newline-terminated entry SHALL be a strict typed envelope with an independently versioned storage format, session identity, monotonically increasing stream sequence, operation kind, optimistic revision metadata, and either one complete `AgentSessionCodec` record snapshot or a deletion tombstone. A tombstone-only stream SHALL be a valid compacted terminal representation carrying its final sequence and deleted record revision. Replay SHALL validate envelope type/version, identity, sequence, operation transition, record revision, and the nested record codec before projecting state. The storage envelope SHALL be migration-ready independently of record schema versions. Stored entries SHALL contain no credentials, raw provider clients, runtime services, callbacks, cancellation objects, active streams, approvals, or queued session messages.

#### Scenario: A session receives several checkpoints
- **WHEN** creation and later revisions are acknowledged for one session
- **THEN** its logical stream contains ordered full-record entries whose replay deterministically returns only the highest valid acknowledged revision

#### Scenario: Record state round-trips through JSONL
- **WHEN** a valid record contains transcript, usage, definition/model, timestamps, continuation metadata, and compaction provenance
- **THEN** JSONL replay delegates the nested payload to `AgentSessionCodec` and restores those values exactly

#### Scenario: Envelope version is unsupported
- **WHEN** replay reaches a complete entry with an unknown storage-envelope version or operation kind
- **THEN** that session is reported unreadable with a typed sanitized compatibility/persistence issue and no earlier revision is silently presented as current

#### Scenario: Nested record version is unsupported
- **WHEN** an envelope is supported but its complete record uses an unsupported record version
- **THEN** the codec rejection makes that session unreadable before any provider request or tool side effect

#### Scenario: Serialized content is inspected
- **WHEN** persisted JSONL is decoded as JSON values
- **THEN** it contains only the declared envelope metadata, tombstones, and credential-free `AgentSessionCodec` payloads

### Requirement: Deterministic session catalog projection
The catalog SHALL return an immutable snapshot containing available session summaries and sanitized unreadable-stream issues. Each available summary SHALL contain stable session identity, record revision, creation/update timestamps, selected model reference, and committed message count without exposing the full transcript. Available summaries SHALL be ordered by `updatedAtMicros` descending and then session identifier ascending. Deleted sessions SHALL be absent. One unreadable session SHALL NOT hide healthy sessions; a failure to enumerate the backing store SHALL instead fail the complete listing operation.

#### Scenario: Sessions have equal and different update times
- **WHEN** the catalog projects healthy sessions with different update timestamps and two share the same timestamp
- **THEN** newer sessions appear first and equal timestamps are ordered by ascending session identifier

#### Scenario: One stream is malformed
- **WHEN** one stored session is unreadable and two other streams replay successfully
- **THEN** listing returns the two healthy summaries in deterministic order plus one sanitized issue and exposes no malformed raw content

#### Scenario: A listed session is restored
- **WHEN** a caller loads an available catalog identifier
- **THEN** the loaded record identity, revision, timestamps, model, and message count agree with its summary

#### Scenario: Store enumeration fails
- **WHEN** the backend cannot enumerate its session streams
- **THEN** listing fails with a typed sanitized persistence error rather than returning a misleading empty or partial catalog

#### Scenario: Listing overlaps an admitted commit
- **WHEN** catalog listing overlaps a save or delete in the same store instance
- **THEN** every projected session reflects either the complete state before that commit or the complete state after it, never a partial entry or mixed revision for one session

### Requirement: Optimistic serialized mutation and cancellation linearization
Mutating operations for one configured store instance SHALL serialize admission within the Dart process and SHALL evaluate expected revisions against the latest committed projection. Creation SHALL require an absent non-tombstoned identifier, expected revision zero, and record revision zero. Update SHALL require the current record revision and exactly its successor. Delete SHALL require the current record revision. A conflict SHALL append nothing. Cancellation that wins before mutation admission SHALL return the typed cancelled error and guarantee no later logical mutation from that operation. Once an operation is admitted to the non-cancellable atomic backend commit, commit SHALL win: later cancellation SHALL NOT roll it back, and the operation SHALL complete successfully only after the backend acknowledges the new durable generation.

#### Scenario: Two saves race on one revision
- **WHEN** two same-process saves for one session present the same expected revision
- **THEN** exactly one successor is durably acknowledged and the other fails with a typed conflict without appending another logical entry

#### Scenario: Saves target different sessions
- **WHEN** simultaneous saves target distinct session identifiers
- **THEN** each is checked against its own stream and neither can overwrite or inherit the other's record

#### Scenario: Cancellation wins while waiting for admission
- **WHEN** a save or delete is cancelled before entering its atomic commit section
- **THEN** it returns the typed cancelled error, appends no entry, changes no catalog result, and cannot mutate later

#### Scenario: Commit wins a cancellation race
- **WHEN** a save or delete has entered atomic commit before cancellation is observed
- **THEN** the durable generation is acknowledged, the operation completes successfully, and replay/catalog state includes that commit exactly once

#### Scenario: Expected revision is stale
- **WHEN** save or delete supplies a revision older or newer than the active record
- **THEN** it fails with a typed conflict and leaves stream, loaded record, and catalog summary unchanged

### Requirement: Crash recovery and bounded corruption handling
The store SHALL bound per-entry and per-stream input through configurable positive limits and SHALL parse without exposing unbounded malformed content. A final non-empty fragment without a newline SHALL be treated as an uncommitted trailing write: replay SHALL ignore it, return the latest complete valid record, and remove the fragment before the next successful commit. A malformed complete internal line, sequence gap, identity mismatch, invalid transition, supported-envelope record rejection, or limit violation SHALL quarantine only that session as unreadable; load SHALL fail and no later line SHALL be guessed as current. Atomic backend generations and their active pointer SHALL ensure restart selects either the complete pre-commit stream or complete committed stream; abandoned temporary/orphan generations SHALL never become active.

#### Scenario: Process ends during a trailing append
- **WHEN** a stream ends with a partial JSON fragment after one or more complete valid entries
- **THEN** restart ignores only that fragment and loads/lists the last complete acknowledged record

#### Scenario: Save follows trailing-fragment recovery
- **WHEN** a valid successor is saved after replay ignored a trailing fragment
- **THEN** the newly committed stream contains the valid prefix and successor with no retained fragment

#### Scenario: Malformed line occurs inside a stream
- **WHEN** a newline-terminated malformed entry occurs before the physical end of a session stream
- **THEN** load fails for that session, listing reports one sanitized issue, later bytes are not replayed, and other sessions remain available

#### Scenario: Crash occurs around pointer publication
- **WHEN** the process ends before or after publication of a staged complete generation
- **THEN** restart selects exactly the old or new complete generation and never combines their bytes

#### Scenario: Configured storage bound is exceeded
- **WHEN** an entry or stream exceeds its configured positive limit
- **THEN** the operation fails with a typed sanitized persistence error without decoding or committing bytes beyond that bound

### Requirement: Tombstoned cascade deletion and identifier safety
Successful delete SHALL atomically publish a terminal tombstone and remove the session from load and catalog results. The active logical stream SHALL then contain only the minimum tombstone metadata needed to prevent stale resurrection; prior transcript-bearing generations SHALL be cleanup data and SHALL never be selected again. A deleted `AgentSessionId` SHALL remain reserved in that store and SHALL NOT be recreated; a new chat SHALL use a new identifier. Physical cleanup SHALL make a best effort to remove superseded generations, but secure media erasure SHALL NOT be claimed.

#### Scenario: Session is deleted and the app restarts
- **WHEN** delete acknowledges the current revision and fresh dependencies open the same store
- **THEN** load returns absent, the catalog omits the session, and no record or messages can be restored through the repository

#### Scenario: Delete is cancelled before admission
- **WHEN** cancellation wins before a delete enters atomic commit
- **THEN** the session remains loadable/listed at the same revision and no tombstone appears later

#### Scenario: Delete races a newer save
- **WHEN** a delete presents an older revision after a successor save commits
- **THEN** delete conflicts and the successor remains loadable and listed

#### Scenario: Stale save follows deletion
- **WHEN** any save attempts to create or update the deleted identifier after its tombstone is active
- **THEN** the save conflicts and cannot resurrect prior or replacement content under that identifier

#### Scenario: User creates a chat after deletion
- **WHEN** a deleted chat is followed by creation of a new chat with a fresh identifier
- **THEN** the new chat starts at revision zero and is listed independently while the deleted identifier remains absent

#### Scenario: Cleanup was interrupted
- **WHEN** a crash leaves superseded transcript-bearing generation files or browser keys after the tombstone became active
- **THEN** restart honors only the tombstone, does not expose old content, and may remove the orphaned generations during recovery without changing the logical result
