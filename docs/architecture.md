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
  -> extraction policy (window, idle, manual, explicit phrase)
  -> isolated LLM candidate extractor
  -> schema/source/scope/secret validation
  -> persisted candidate
  -> user confirm/edit/reject
  -> active working or long-term record
```

The extractor receives source message IDs and a bounded set of active records.
It may propose create, update, or noop. The host owns scopes, IDs, revisions,
project membership, and persistence. Automatic deletion is forbidden.

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

