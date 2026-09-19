## ADDED Requirements

### Requirement: Backward-compatible durable Project membership
The current nested session record SHALL persist an optional Project identity and
the session catalog summary SHALL expose the same value without loading the full
transcript. A null identity SHALL mean deliberately unassigned. Earlier supported
record versions without this field SHALL decode as null without changing the
JSONL storage-envelope version or eagerly rewriting the stream. Project identity
SHALL contain no directory path, grant identity, opaque token, permission status,
or Project record. Creating or assigning a Project-scoped session SHALL validate
that the referenced Project is active at mutation admission; changing membership
SHALL use an ordinary optimistic successor revision and preserve transcript,
title, selection, continuation, and accounting exactly.

#### Scenario: Legacy session is restored
- **WHEN** a supported v1 or v2 session record without Project membership is replayed
- **THEN** it remains readable with exact transcript and metadata, its Project identity is null, and no rewrite occurs until a later real session mutation

#### Scenario: Project chat survives restart
- **WHEN** a session with an acknowledged Project identity is closed and restored with the same healthy Project catalog
- **THEN** repository and catalog expose the exact membership and all existing session data remains unchanged

#### Scenario: Membership successor conflicts
- **WHEN** assignment or unassignment presents a stale session revision
- **THEN** it appends nothing, refreshes or reports conflict through the caller, and cannot overwrite newer transcript or selection state

#### Scenario: Serialized session is inspected
- **WHEN** a Project-scoped session record and transcript are decoded
- **THEN** only the Project identity is added and no path, grant reference/material, native token, or permission status appears

### Requirement: Missing or unreadable Project preserves chat recovery
Session replay SHALL remain independent of Project replay. If a session names a
missing, deleting, tombstoned, unreadable, or access-unavailable Project, the
session record and transcript SHALL remain loadable and SHALL NOT be silently
rewritten or discarded. Workspace projection SHALL place that chat in a
recoverable `Без проекта` state with a sanitized Project warning while retaining
the unresolved identity for repair or deletion recovery. Such a chat SHALL
authorize no Project directory access and SHALL NOT create new Project-scoped
work until the Project is healthy or membership is durably cleared.

#### Scenario: Project stream is corrupt
- **WHEN** a healthy session references a Project whose stream cannot be decoded
- **THEN** the chat remains readable under recovery/unassigned presentation, a sanitized warning is shown, and every Project filesystem resolution is denied

#### Scenario: Project was tombstoned during interrupted cleanup
- **WHEN** a session still references a tombstoned Project after restart
- **THEN** the chat remains recoverable, deletion recovery clears membership idempotently, and no stale grant or Project record is resurrected

#### Scenario: Session stream is corrupt but Project is healthy
- **WHEN** a Project catalog contains a healthy Project and one member session stream is unreadable
- **THEN** the Project remains available, the session catalog reports its existing sanitized issue, and no replacement chat or membership is invented
