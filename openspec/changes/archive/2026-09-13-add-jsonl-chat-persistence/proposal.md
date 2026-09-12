## Why

Repository-backed agent sessions currently survive only inside one Dart process, and production composition hard-codes the in-memory adapter. A durable, listable, replaceable store is the next dependency for reopening every committed chat and message after an application restart.

## What Changes

- Add a versioned JSONL session store whose logical per-chat streams retain full `AgentSessionCodec` snapshots and deterministic operation history.
- Add native/mobile/desktop filesystem storage and a durable browser-compatible storage backend behind the same injected JSONL stream primitive; web must never silently fall back to memory.
- **BREAKING**: strengthen the core persistence boundary with a minimal catalog result and revision/cancellation-aware deletion, including deterministic ordering, optimistic conflict handling, same-process serialization, and an explicit no-reuse rule for deleted session identifiers.
- Define crash and corruption recovery for an incomplete trailing line, malformed internal entries, unsupported envelope/record versions, interrupted deletion, and storage failures.
- Expose and permit injection of the production durable repository/catalog for the later chat workspace while preserving the current prompt workspace's transient one-shot behavior.
- Keep `AgentSessionCodec` authoritative for records and exclude credentials, provider clients, runtime services, cancellation objects, and other executable state from storage.
- Add only focused repository, restart, catalog, deletion, recovery, race, composition, and cross-platform compile coverage. No application UI is implemented by this change.

## Sequenced Follow-up Backlog

Only `add-jsonl-chat-persistence` is active. After it is accepted, work continues one item at a time in the user-selected Heavy mode without another mode confirmation:

1. **`add-jsonl-chat-persistence` (current):** durable replaceable JSONL session persistence, listing, restoration, and deletion.
2. **Token accounting:** report the current request, full conversation, and assistant response; distinguish input, output, reasoning, cache read, cache write, cache hit, and overall values, using provider-reported values where available.
3. **Chat workspace UI and design system:** left chat list and right current conversation; chat bubbles; collapsed reasoning; tool blocks; calm composer with a provider-grouped model selector and a separate reasoning selector; next-message model switching with compact-before-smaller-model behavior; stop; delete confirmation; and one unified visual source of truth. OpenCode is the primary implementation reference, with Codex Desktop, Grok's calm composer/model visibility, and ZCode/Zed agent UI as supporting references.
4. **Final independent cross-feature review and critical fixes:** independently verify persistence, accounting, and workspace interactions together, then fix only critical findings before final acceptance.

Future items remain dependencies/non-goals here and do not create additional active OpenSpec changes.

## Capabilities

### New Capabilities

- `agent-session-persistence`: Durable versioned JSONL storage, catalog projection, cross-platform backends, replay/recovery, deletion, and production composition.

### Modified Capabilities

- `agent-runtime`: Extend the replaceable session persistence contract from load/save/delete to catalog-aware, optimistic, cancellation-safe storage while retaining codec and runtime checkpoint semantics.

## Impact

- Core API: `lib/core/agents/repository.dart`, exports, and implementations/tests of `AgentSessionRepository`.
- Infrastructure: new JSONL envelope/replay repository, abstract stream storage, conditional filesystem/browser backends, and focused tests.
- Composition: `lib/app.dart` exposes/injects one production durable store without changing prompt presentation behavior.
- Dependencies: promote `path_provider` to a direct dependency for application data paths and add a direct browser persistence dependency only for the durable web backend; any path utility imported by production code must also be direct.
- Data: a migration-ready envelope version wraps existing versioned `AgentSessionCodec` payloads. No database, encryption, cloud sync, import/export, attachments, token-accounting behavior, or UI is added.
