## Purpose

Defines durable Project ownership, directory-access references, fail-closed
platform behavior, and safe lifecycle operations so multiple chats can belong to
a real workspace without fabricating filesystem permission.

## ADDED Requirements

### Requirement: Versioned Project identity and invariants
A Project SHALL have a stable opaque Project identity, optimistic revision,
normalized non-empty display name, one required typed root reference, zero or
more additional external grant references, creation/update timestamps, and an
active or deleting lifecycle. Project identity SHALL be distinct from provider,
model, chat, path, root, and grant identity. A root reference SHALL identify
either a desktop external read/write grant or an Android/iOS app-owned sandbox
root; these kinds SHALL NOT be interchangeable. Additional references SHALL be
ordered, unique, external read-only grants and SHALL be valid only for desktop
external roots. Ordinary Project/session records and transcripts SHALL contain no
native handle, bookmark, capability token, credential, raw path, or serialized
filesystem client. Active Project names SHALL be unique after trimming, control-
character removal, whitespace normalization, and locale-independent case folding.

#### Scenario: Desktop Project round-trips
- **WHEN** an active desktop Project with one external root grant and two additional read-only grant references is encoded and decoded
- **THEN** identity, revision, normalized name, typed root, ordered grant identities, requested access, and timestamps restore exactly without native grant material

#### Scenario: Mobile sandbox Project round-trips
- **WHEN** an Android or iOS Project with one app-owned sandbox root and no additional grants is encoded and decoded
- **THEN** its sandbox root kind and stable root identity restore exactly without a picker result, external grant, or native capability in Project JSON

#### Scenario: Invalid Project metadata is decoded
- **WHEN** a Project record has a blank/duplicate normalized name, invalid identity, missing/unknown root kind, duplicate grant identity, writable additional grant, additional grant on a sandbox root, negative revision, or invalid lifecycle
- **THEN** the record is rejected before any directory resolution, chat mutation, provider request, or tool execution

#### Scenario: Persisted content is inspected
- **WHEN** Project and session JSON plus chat transcripts are decoded
- **THEN** they contain declared Project/grant identifiers and metadata only, with no opaque OS token, credential, native object, or raw filesystem client

### Requirement: Independent durable Project repository and catalog
Projects SHALL use a platform-neutral repository and catalog backed by a separate
versioned logical storage namespace from session streams and directory grant
material. Each Project stream SHALL use strict typed/versioned newline-framed
operations, full-record snapshots, monotonically increasing sequence, optimistic
revision checks, atomic generation publication, and terminal tombstones.
Acknowledged Projects SHALL survive dependency reconstruction on Linux, Windows,
macOS, Android, and iOS application-data storage. Web SHALL not create or publish
Project streams in this version. Catalog output SHALL contain immutable healthy
summaries plus sanitized per-Project issues, ordered by updated timestamp
descending then identity ascending. Corruption of one Project SHALL NOT hide
healthy Projects; enumeration failure SHALL fail the whole listing instead of
returning a misleading empty catalog.

#### Scenario: Projects restore after restart
- **WHEN** two Project records are acknowledged and fresh dependencies open the same application-data backend
- **THEN** the Project catalog returns both in deterministic order and each repository load restores its exact last acknowledged record

#### Scenario: Project stream has a partial tail
- **WHEN** a Project stream ends with an incomplete non-newline fragment after a valid record
- **THEN** restart ignores only the fragment, restores the last complete acknowledged record, and removes the fragment on the next successful commit

#### Scenario: Project stream has internal corruption
- **WHEN** one Project stream has a malformed complete line, sequence gap, identity mismatch, unsupported envelope/record version, invalid transition, or configured size violation
- **THEN** that Project is reported as a sanitized unreadable issue, no later bytes are guessed, healthy Projects remain available, and directory access for the unreadable Project is denied

#### Scenario: Project mutation conflicts or is cancelled
- **WHEN** two mutations present the same expected revision or cancellation wins before one is admitted
- **THEN** exactly one eligible successor may commit, the loser appends nothing, and a pre-admission cancellation has no later effect

### Requirement: Platform-specific root provisioning and external grants
Project root provisioning SHALL pass through an injected platform abstraction
whose result is typed as desktop external, mobile app-owned sandbox, or
unsupported. Desktop selection/grant material SHALL use a dedicated grant store
separate from Project/session JSON. A desktop root SHALL be either an attached
existing directory or a newly created child folder and SHALL yield an opaque grant
identity, safe display label, canonical directory identity, platform kind,
read/write access, origin (`attached` or `created`), and runtime status. Desktop
additional directories SHALL yield the same descriptor shape with read-only
access. A desktop grant SHALL be persisted only after the adapter confirms the
requested access; Project creation SHALL be acknowledged only after every grant is
durably stored and immediately revalidated. Persisted desktop references SHALL
NOT be called active after restart until the adapter revalidates them.

Android and iOS SHALL instead allocate a stable app-owned project root inside the
application sandbox from the fresh Project identity. They SHALL invoke no root or
additional-directory picker, persist no external grant, and expose no external
grant or regrant control. Web SHALL return unsupported before any Project/root/
grant persistence call. Missing, revoked, stale, corrupt, unsupported, or
unverifiable access SHALL report a safe unavailable state and authorize no access.
Desktop regrant SHALL replace grant material only after canonical identity and
Project binding are rechecked.

#### Scenario: Desktop root and additional directories are granted
- **WHEN** Linux, Windows, or macOS confirms durable read/write access to an attached or newly created root and read-only access to selected additional directories
- **THEN** the grant store acknowledges them, immediate revalidation succeeds, and only then may an active Project reference their identities

#### Scenario: Android or iOS provisions a sandbox root
- **WHEN** mobile Project creation is admitted with a fresh Project identity
- **THEN** one app-owned sandbox directory is created for that identity without a picker or external grant, and only that typed root may be published in the Project

#### Scenario: Picker, folder creation, or permission is cancelled
- **WHEN** the user cancels a required desktop picker/folder step or cancellation wins before Project commit
- **THEN** no Project or chat is created, no grant is presented as active, and staged grant material plus any newly created empty same-identity folder are safely rolled back

#### Scenario: macOS grant is stale after restart
- **WHEN** a macOS security-scoped reference is absent, revoked, stale, corrupt, or cannot be revalidated after Project metadata restores
- **THEN** the Project and chats remain recoverable, the UI reports access unavailable or regrant required, and all filesystem resolution for that Project fails closed

#### Scenario: Stored grant material is inspected indirectly
- **WHEN** logs, errors, Project/session codecs, catalogs, semantics, or transcripts are observed
- **THEN** no opaque token/bookmark or raw grant payload is exposed

### Requirement: Canonical non-overlapping directory policy
Before activation or regrant, the platform abstraction SHALL canonicalize and
attest every root using platform identity rather than string-prefix comparison.
Desktop root and additional directories within one Project SHALL not be equal,
ancestors, or descendants of one another. No desktop active grant in one Project
SHALL equal, contain, or be contained by an active grant of another Project. An
app-owned mobile root SHALL be contained by the configured application sandbox,
be uniquely bound to one Project identity, and SHALL never be accepted as an
external grant. Selection or creation of a file, broken link, symbolic-link/
junction/reparse-point root, unverifiable canonical target, relative path, or
non-directory SHALL fail. The access boundary exposed for later consumers SHALL
reject absolute child inputs, empty/NUL/dot/dot-dot segments, separator injection,
canonical escape, symlink/junction escape, cross-Project root/grant identity,
stale handles, revoked grants, and Project switches. Additional grants SHALL never
authorize writes.

#### Scenario: Root collides with an existing Project
- **WHEN** a selected root equals, contains, or is contained by any active grant of another Project after canonical resolution
- **THEN** creation fails with a safe collision result and neither Project nor grant state changes

#### Scenario: Additional directory overlaps this Project
- **WHEN** an additional directory equals, contains, or is contained by the root or another additional directory
- **THEN** creation/regrant fails without weakening root or additional access

#### Scenario: Traversal or link escape is requested
- **WHEN** a future consumer supplies an absolute path, `..`, separator injection, a symlink/junction escape, or a path outside the selected grant
- **THEN** resolution returns denied before filesystem content is read, written, listed, or disclosed

#### Scenario: Project switches with a stale grant identity
- **WHEN** a grant identity from Project A is presented while Project B is active
- **THEN** resolution is denied even if both Projects reference the same display label or textual path

### Requirement: Atomic default-safe Project creation
Project creation SHALL require a validated unique name, a fresh Project identity,
and exactly one root successfully provisioned for the current platform. Desktop
creation SHALL either attach an existing exclusive root or create a new exclusive
child folder, then acquire/validate its read/write grant and optional external
read-only grants before publishing the Project. Android/iOS creation SHALL create
only the identity-bound app-owned sandbox root. Web SHALL reject creation before
any write. Every supported branch SHALL publish exactly one initial active Project
record only after root durability is acknowledged. Cancellation before Project
publication SHALL create no visible Project; cancellation after the atomic
Project commit point SHALL not roll it back and creation SHALL report the committed
result. A pre-commit failure SHALL leave no visible Project and SHALL revoke
orphan grants. A newly created root SHALL be removed on rollback only when it is
still empty and has the exact staged canonical identity; otherwise it SHALL be
retained without recursive deletion and a sanitized cleanup warning SHALL be
reported. Creating a Project SHALL NOT create a chat implicitly, create any file
inside the root, or register agent tools.

#### Scenario: Project is created successfully
- **WHEN** name and directory selections pass validation and all grants plus the initial Project record are durably acknowledged
- **THEN** the Project becomes selectable with zero chats and survives restart with access status revalidated

#### Scenario: Name or directory collision occurs
- **WHEN** the normalized name already exists or canonical directory policy detects a collision
- **THEN** creation reports an actionable conflict and commits no Project, session membership, or active grant

#### Scenario: New desktop folder collides
- **WHEN** the requested child folder already exists or appears between validation and creation
- **THEN** creation does not adopt, merge, overwrite, empty, or delete it; the user may explicitly choose the separate attach-existing flow

#### Scenario: Root creation rolls back
- **WHEN** a desktop or mobile root was newly created but grant/root persistence or Project publication fails before commit
- **THEN** the exact newly created directory is removed only if still empty and unchanged; a non-empty, replaced, or unverifiable directory is retained with a sanitized cleanup warning and no Project is published

#### Scenario: Crash leaves an orphan grant
- **WHEN** grant storage commits but the process ends before the initial Project record commits
- **THEN** restart exposes no Project for that grant and bounded orphan cleanup revokes the unreferenced material without touching user files

### Requirement: Project deletion retains chats and user files
Deleting a Project SHALL require confirmation bound to its identity and current
revision. The operation SHALL first publish deleting state, immediately deny new
directory resolutions and Project-scoped chat creation, durably clear that
Project identity from every member chat using ordinary successor revisions, then
publish a terminal Project tombstone, revoke desktop grant material, and retire
the root capability. It SHALL NOT delete chat records, transcripts, desktop or
mobile root/additional directories, or any user file.
Before the deleting-state commit cancellation SHALL leave all state unchanged;
after that commit the idempotent operation SHALL be commit-wins and restart SHALL
resume it. A conflict/failure SHALL remain visible and fail closed; it SHALL never
claim deletion while member references or an active Project record remain.

#### Scenario: Non-empty Project is deleted
- **WHEN** deletion of a Project with several chats is confirmed and completes
- **THEN** the Project is tombstoned, all chats remain recoverable under `Без проекта`, external grants/root capability are revoked, and no desktop/mobile directory or user file is removed

#### Scenario: Deletion is cancelled before admission
- **WHEN** the confirmation is dismissed or cancellation wins before deleting state commits
- **THEN** Project, chats, grants, files, and selection remain unchanged

#### Scenario: Process ends during deletion
- **WHEN** restart observes a Project in deleting state with only some chats unassigned
- **THEN** all its grants remain denied and recovery idempotently finishes unassignment, tombstone, and revocation without deleting chats or files

#### Scenario: Chat revision conflicts during deletion
- **WHEN** a member chat has a newer revision than the deletion operation observed
- **THEN** deletion refreshes/retries through the bounded recovery path or reports a conflict, and does not claim completion or tombstone the Project while that membership remains

### Requirement: Selected platform support matrix
Linux, Windows, and macOS SHALL provide full desktop adapters for attaching an
existing exclusive read/write root, creating a new exclusive project folder, and
adding external read-only directories. Linux and Windows SHALL revalidate their
durable canonical references and effective access after restart. macOS SHALL use
a durable security-scoped platform mechanism; a path string or picker result alone
SHALL be insufficient. An unavailable, stale, or revoked macOS reference SHALL
fail closed and MAY offer explicit regrant without hiding the Project or chats.

Android and iOS SHALL support Project creation only with an app-owned sandbox
root. Their creation UI SHALL expose neither root picker nor additional-directory
control and SHALL make no external grant-store call. Downloads/Documents and any
other external mobile location are outside this version. Web SHALL present Project
creation as unsupported with a safe explanation, keep `Без проекта` chats usable,
and perform no Project repository, root-provisioner, grant-store, or filesystem
write in response to the unavailable action. No platform SHALL accept a typed raw
path or save a placeholder grant.

#### Scenario: Linux and Windows use full desktop adapters
- **WHEN** a user attaches or creates a root and optionally selects additional directories
- **THEN** canonical identity, requested access, collision policy, durable storage, restart revalidation, and read-only additional access are proven before the Project is active

#### Scenario: macOS durable scope is unavailable or revoked
- **WHEN** the adapter cannot create, persist, resolve, or reactivate the required security-scoped reference
- **THEN** no grant is labeled active, new Project publication is denied or the restored Project is marked unavailable/regrant-required, and no filesystem access occurs

#### Scenario: Android or iOS creates a Project
- **WHEN** the user confirms valid Project creation
- **THEN** the app provisions only its own sandbox root, shows no root/additional picker or regrant control, and persists no external grant

#### Scenario: Web user reaches Project creation
- **WHEN** Project creation is shown or activated on web
- **THEN** truthful unsupported UI is returned, `Без проекта` remains usable, and no Project/root/grant/filesystem write is attempted

### Requirement: Grants are not filesystem tools
This capability SHALL expose validated Project/grant state and a default-deny
resolution boundary for future consumers, but SHALL NOT register agent tools,
read, list, index, modify, create, move, or delete user files. A later capability
that adds any filesystem operation MUST bind every operation to the active Project
and revalidate grant identity, requested access, relative path, canonical target,
revocation, and platform status at operation time.

#### Scenario: Agent requests filesystem work before tools exist
- **WHEN** a model or runtime attempts to locate a Project filesystem tool after this change
- **THEN** no such tool is registered and no Project grant is consumed

#### Scenario: Project is active
- **WHEN** Project metadata and grants are healthy but no later filesystem capability is installed
- **THEN** users can manage the Project and its chats, while the application performs no project-file read or write
