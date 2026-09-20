# Memory architecture

## Boundaries

Dependencies remain `presentation -> application -> domain`. Memory contracts
live in `lib/core/memory/`; JSONL and platform adapters live in
`lib/infrastructure/memory/`; composition remains explicit in `lib/app.dart`.
No state-management, DI, database, or embedding dependency is added.

## Scopes and ownership

| Layer | Canonical source | Scope | Lifetime |
|---|---|---|---|
| Short-term | `AgentTranscript` | session | current chat |
| Working | working JSONL | project | until edited, forgotten, or project deletion |
| Long-term | long-term JSONL | local user/global | across projects and chats |

The protected project `default` is a real `ProjectRecord` with an app-managed
sandbox root. Desktop and mobile use application-support storage; user-created
desktop projects continue to use explicit filesystem grants. Web retains the
reserved default identity while filesystem operations remain unsupported.

## Write flow

```text
completed transcript messages
  -> deterministic explicit-command parser
     -> match: candidate immediately, with no LLM call
     -> no match: isolated LLM classifier sees only the latest user message
  -> periodic extraction policy (window, idle, manual)
  -> isolated LLM batch extractor
  -> schema/source/scope/secret validation
  -> persisted candidate
  -> user confirm/edit/reject
  -> active working or long-term record
```

The command classifier decides only `none`, project working memory, or global
long-term memory; it cannot see chat history or call tools. The batch extractor
receives source message IDs and a bounded set of active records and may propose
create, update, or noop. Semantically equivalent pending/accepted candidates
and active records are deduplicated across both paths. The host owns scopes,
IDs, revisions, project membership, and persistence. Automatic deletion is
forbidden.

An update candidate is discarded when its target already has the proposed
content. Confirming a real update extends the target's source provenance rather
than replacing it.

## Read flow

```text
user request
  -> current project working records
  -> global preferences + lexical long-term facts/procedures
  -> deterministic budget and render
  -> dynamic system prompt + existing transcript
  -> provider request + MemoryContextTrace
```

Working requirements and decisions have priority. Confirmed preferences are
always eligible; other long-term records use lexical ranking with a maximum of
five. The rendered memory block is capped at 12,000 characters and labels its
contents as untrusted data rather than instructions. It is never appended to the
transcript, continuation state, or compaction input.

## Persistence

Working, long-term, candidate, and extraction-state streams use independent
namespaces, optimistic revisions, append/replay validation, atomic generation
publication, and tombstones. Missing streams mean empty state; corrupt streams
surface sanitized persistence errors rather than silently returning no memory.

## Mobile lifecycle

Timers and LLM calls are foreground-only. Pausing the app records the last
activity and pending source IDs, cancels the timer, and leaves the checkpoint
unchanged. Resuming recomputes the deadline and performs an overdue flush in the
foreground. Reprocessing is idempotent by source IDs.

## Trust model

- API keys and detected secrets are never memory records.
- Model output is an untrusted candidate until confirmed.
- Retrieved memory is data, not policy or executable instructions.
- Project and global scopes are assigned by the host.
- UI inspection, edit, forget, and context trace are required behavior.
- Bulk clearing is explicit and confirmed: entries become forgotten tombstones
  and pending candidates become rejected audit records.

## Final implementation notes

- Composition lives in `lib/app.dart`: one `MemoryJsonlStack`, layered
  retrieval, a live `MemoryReadTogglesController` behind the dynamic context
  provider, a registry-backed `LlmMemoryCommandClassifier`, a
  `LlmMemoryBatchExtractor`, and a `MemoryExtractionCoordinator`.
- `ChatWorkspaceController.onTurnCompleted` records each completed turn without
  delaying the chat command; attaching a session restores its pending
  extraction and reschedules the idle deadline.
- Candidate identities are derived deterministically from the session, source
  identities, and proposal index, and confirmed creates recover idempotently, so
  retried batches cannot duplicate records.
- Confirmed records are editable in place; forgetting is a tombstone revision.
  Only an accepted candidate produces an active record, and extraction itself
  only ever writes candidates.
- Android/iOS pause and resume extraction with the application lifecycle;
  desktop and web are foreground-only.
