## Context

See `proposal.md` for motivation and the three delta specs for behavior. Sessions
currently use `AgentSessionRecord` v2 inside independent v1 JSONL operation
streams. Native storage uses atomic filesystem generations; web uses origin-local
browser generations. Session catalogs are flat. There is no Project domain,
directory picker, native grant store, path authority, filesystem tool, or
cross-platform permission adapter.

The approved `final-01` remains the eventual visual source. This change creates
the durable and permission-aware facts that the later shell must render; it does
not redesign that composition.

## Goals / Non-Goals

**Goals:**

- Make Project identity, Project→Chats membership, and `Без проекта` recovery
  durable and independently testable.
- Separate inspectable Project metadata from opaque platform grant material.
- Fail closed across corruption, cancellation, stale handles, revocation,
  traversal, symlink/junction escape, Project switches, and deletion recovery.
- Deliver only the minimal UI needed to create/select Projects and chats and to
  communicate real platform/access state.

**Non-Goals:**

- Reading, listing, indexing, writing, moving, or deleting user files.
- Agent filesystem tools, attachment/context composition, Project instructions,
  sync, sharing, pricing, or final-shell styling.
- Pretending raw persisted paths are OS grants, or claiming equal folder support
  on platforms whose adapter cannot prove durable revalidation.

## Decisions

### 1. Project is a separate aggregate; sessions carry only membership

Add `ProjectId`, `ProjectRootId`, and `DirectoryGrantId` value types under a new
`lib/core/projects/` boundary. `ProjectRecord` v1 contains:

- `id`, `revision`, normalized `name`;
- a required tagged root reference: `externalGrant` for Linux/Windows/macOS or
  `appSandbox` for Android/iOS, plus ordered `additionalGrantIds` permitted only
  with a desktop external root;
- `createdAtMicros`, `updatedAtMicros`;
- lifecycle `active` or `deleting` plus a stable deletion operation identity when
  deleting.

The Project codec contains no path or native grant payload. A sandbox root ID is
an application identity, not an external capability or path. `ProjectSummary`
contains only safe catalog fields and counts resolved by the application layer.
Names are 1–60 grapheme clusters after trimming/control removal/whitespace
normalization and are unique under locale-independent case folding among
non-tombstoned Projects. Stable IDs, not names, define ownership.

`AgentSessionRecord` becomes v3 with nullable `ProjectId projectId`;
`AgentSessionSummary` exposes it. `Agent.createSession` accepts optional Project
membership so initial session creation is one acknowledged record, not a create-
then-attach window. The runtime treats the ID as metadata; the Project application
service validates active Project state before calling it. Membership successors
preserve all other session fields and use ordinary optimistic revisions.

Alternative rejected: infer Project from path/title/provider or maintain an
external session-ID list in Project records. Both create two authorities and make
session deletion/migration inconsistent. The session record is authoritative for
its own membership; Project chat lists are catalog projections.

### 2. Projects use their own JSONL store and namespace

Create `ProjectRepository`/`ProjectCatalog` contracts and an in-memory
implementation mirroring session semantics. Add a Project record codec v1,
Project operation envelope v1, replay, key codec (`project-v1_…`), optimistic
store, tombstones, limits, and sanitized issues. Reuse/generalize the existing
native atomic `JsonlStreamStorage` implementation by parameterizing its storage
directory; do not mix Project keys into the session namespace, because the
current session catalog correctly treats unknown keys as issues.

The native production namespace is independently versioned, for example
`project-workspaces-jsonl-v1`. Linux, Windows, macOS, Android, and iOS use it in
their application-data storage. Web does not instantiate or publish a production
Project stream in this version: browser Project persistence is explicitly future
work. Project record/envelope versions can evolve without changing session
envelopes.

Alternative rejected: place Projects in one global JSON file. Per-Project streams
retain existing crash isolation, optimistic revision, tombstone, and corruption
behavior and avoid rewriting an unbounded global document.

### 3. Migration is lazy and non-destructive

`AgentSessionCodec` v3 accepts supported v1/v2 records and derives
`projectId = null`; no JSONL envelope or stream is rewritten on read. A legacy
session receives v3 only on its next real acknowledged mutation. New Project
streams are additive. A session whose Project is missing/unreadable remains an
unchanged readable session with unresolved membership; projection places it under
recovery/`Без проекта`, while all directory access fails closed.

Rollback before any v3 session write is code-only. After v3 exists, rollback must
use a compatibility build that understands v3; old binaries are not allowed to
silently reinterpret it. No down-migration drops Project IDs. Project deletion
explicitly clears memberships before tombstoning, so normal completed deletion
leaves sessions readable by a compatibility build.

Alternative rejected: eagerly rewrite every session when the app starts. It
creates an unnecessary destructive migration and turns one bad record into a
global rollout blocker.

### 4. Root provisioning and external grants are distinct capabilities

Define a platform-neutral `ProjectRootProvisioner` with tagged results
`desktopExternal`, `mobileSandbox`, and `unsupported`, plus a
`ProjectDirectoryGrantStore` used only for desktop external references.
Domain-facing external descriptors contain grant ID, Project ID, role
(`root`/`additional`), requested access (`readWrite`/`readOnly`), origin
(`attached`/`created`), safe display label, canonical directory fingerprint,
platform kind, and timestamps/status. Sandbox descriptors contain root ID,
Project ID, platform kind, canonical sandbox-relative identity, and runtime
status, but no external grant ID. Project records retain only typed IDs. Native
path/bookmark/handle material is stored only behind platform infrastructure and is
never returned through codecs, logs, errors, semantics, transcripts, or model
context.

Desktop acquisition returns staged material. Creation stores and immediately
revalidates all staged grants before publishing Project metadata. Android/iOS
provision an identity-bound directory beneath the app-owned projects container
and validate sandbox containment, without using the external grant store.
Ordering is root/grant-first, Project-second: a crash can produce an unreferenced
staged root/grant but never an acknowledged Project whose root was never durable.
Startup cleanup revokes an external orphan or removes a newly created root only
after a complete healthy Project catalog proves its Project ID absent/tombstoned
and the root is still empty with the exact staged identity; ambiguity quarantines
rather than deleting.

Runtime access status is a projection, never a persisted `active=true` claim.
States include `active`, `requiresRegrant`, `revoked`, `missing`, `unsupported`,
`corrupt`, and `unverifiable`. Only a fresh `active` result authorizes a later
resolver.

Alternative rejected: represent every root as an external grant. Mobile sandbox
ownership is not a user-selected OS capability, and conflating it would create
fake picker/regrant states. Also rejected: store native handles in
`ProjectRecord`; that leaks capabilities into generic backups/codecs.

### 5. Desktop roots attach or create; mobile roots are app-owned

Linux, Windows, and macOS offer two explicit root modes. Attach selects an
existing directory through the platform picker. Create selects/authorizes a
parent and creates one new child folder with a validated non-empty name; if the
target exists, the operation reports collision and never adopts, merges,
overwrites, empties, or deletes it. Typed raw paths are not accepted. Both modes
request durable root read/write access. Desktop additional directories use a
picker and request read-only access.

Android and iOS derive a fresh root location from Project ID beneath an app-owned
projects container. They expose no root/additional picker and no external grant.
If that supposedly fresh target already exists, creation quarantines/reports a
collision rather than adopting unknown content. Web returns unsupported before
root provisioning. Apart from creating the root directory itself, this change
creates no marker, metadata, or project file. Actual project-file operations
remain a later capability.

After resolving links according to the platform's canonical identity API, active
desktop grants may not overlap (equal/ancestor/descendant) within or across Projects.
Overlapping additional grants are unnecessary and ambiguous; cross-Project
sharing needs a future explicit contract. Root/additional selection rejects files,
relative paths, broken links, link/junction roots, and any target whose canonical
identity cannot be attested. Comparison uses path components plus platform case
rules, not string prefixes.

The broker also defines the mandatory future child resolver: only relative clean
segments, active Project/grant match, fresh revalidation, canonical containment,
and read-only enforcement. The resolver rejects absolute inputs, NUL, empty, `.`/
`..`, embedded separators, alternate data/path syntax, symlink/junction escapes,
stale handles, revoked grants, and a grant from another active Project. It performs
no file operation in this change.

### 6. Creation uses a platform-root-first commit boundary

The application service serializes Project mutations:

1. validate normalized name and allocate Project/root/grant IDs;
2. branch by reported platform kind: desktop attach/create plus optional
   additional pickers, mobile sandbox provisioning, or web unsupported;
3. canonicalize the root, prove sandbox containment or requested desktop access,
   and compare applicable active descriptors;
4. durably store desktop grant material or acknowledge the app-owned root;
5. immediately revalidate the stored/provisioned root and desktop grants;
6. atomically publish one revision-0 active Project record;
7. expose success only after Project catalog refresh.

Cancellation before step 6 cleans staged external material and publishes no
Project. A newly created desktop/mobile root is removed only if it remains empty
and has the exact staged canonical identity; otherwise it is retained and a
sanitized cleanup warning is surfaced. Once step 6 enters its atomic commit,
commit wins and success is returned after acknowledgement. If step 6 fails,
external grants are revoked immediately or by the conservative orphan recovery
above. Project creation does not create a chat or any project file.

Name, existing target, and canonical overlap collisions are typed conflicts.
Picker/folder cancellation is a non-error cancelled result. Raw path and grant
error details are sanitized.

### 7. Deletion is an idempotent fail-closed saga

There is no atomic transaction across Project and many session streams. Use an
explicit persisted `deleting` state and deletion operation ID:

1. confirm identity/revision and publish `deleting`;
2. deny all root/additional resolution and reject new Project chats immediately;
3. stop/close the selected member session through the existing controller;
4. enumerate current member summaries and write `projectId = null` successors,
   refreshing/retrying bounded optimistic conflicts;
5. prove no healthy session summary still references the Project;
6. publish the Project tombstone;
7. revoke desktop grants and best-effort capability cleanup; retain every desktop
   or mobile root directory and its files.

Cancellation before step 1 is no-op; after the deleting commit the saga is
commit-wins and resumes on restart. An unreadable session that may reference the
Project blocks completion rather than risking tombstone plus undiscovered member;
all root access remains denied and the UI reports recovery blocked. User files and
root directories are never deleted. Chats are never tombstoned by Project deletion.

Alternative rejected: cascade-delete chats/files. It is irreversible and not
required by the user. Also rejected: tombstone Project first and clear sessions
later, because it creates an apparently completed delete with stale membership.

### 8. Minimal UI is a domain proving surface, not the final shell

Add a `ProjectWorkspaceController` over Project catalog/repository, root
provisioner, external grant store, and current chat controller. It projects Projects, grouped session summaries,
`Без проекта`, active selection, platform capability, access state, mutation
state, and sanitized issues. It owns create/select/delete orchestration; widgets
never access stores directly.

The UI adds only:

- Project and `Без проекта` list/selection;
- desktop creation form with name, attach/create root mode, required picker or
  parent+folder flow, optional additional pickers, and explicit root read/write/
  additional read-only descriptions;
- Android/iOS name-only creation with an app-owned-root explanation and no
  root/additional/regrant controls; web unsupported explanation with no writes;
- Project-scoped/unassigned new-chat action;
- empty/loading/unsupported/regrant-required/corrupt/deleting/error states;
- confirmed safe delete.

It reuses the current timeline/composer and existing responsive/accessibility
rules. No visual attempt is made to approximate `final-01`; the dependent shell
will replace the composition after this contract is accepted.

### 9. Selected platform capability matrix

The user selected this exact rollout:

| Platform | Version status | Required contract |
| --- | --- | --- |
| Linux | Full desktop adapter | Attach or create exclusive read/write root; external read-only additions; canonical identity and restart access revalidation |
| Windows | Full desktop adapter | Same, with volume/case rules and junction/reparse fail-closed checks |
| macOS | Full desktop adapter | Same UX backed by durable security-scoped mechanism/bookmark and restart/stale/revoked tests; a path alone never counts |
| Android | Sandbox-only Project creation | Create identity-bound app-owned root; no root picker, external additions, external grant store, or Downloads/Documents claim |
| iOS | Sandbox-only Project creation | Same app-owned-only contract; no document-provider/security-scope claim in this version |
| Web | Unsupported | Truthful explanatory UI; no Project/root/grant/filesystem write; `Без проекта` remains usable |

Future Android/iOS Downloads/Documents access and browser Project storage require
separate platform capability changes. They are not dormant or partially active
adapters here.

### 10. Expected implementation paths and evidence

Expected paths for the selected rollout:

- `pubspec.yaml`, `pubspec.lock` for desktop picker/security-scope dependencies;
- `lib/core/projects/**` (new domain, codecs, repository/catalog, grants/policy);
- `lib/core/agents/{agents,catalog,record,runtime}.dart` for nullable Project
  membership and initial scoped session creation;
- `lib/infrastructure/projects/**` (Project JSONL store, root provisioners,
  desktop grants, mobile sandbox roots, and web unsupported adapter);
- `lib/infrastructure/agents/jsonl/jsonl_stream_storage_io.dart` and its shared
  native factory boundary only if needed to parameterize the independent native
  Project namespace; do not alter session semantics or web session storage;
- `lib/features/projects/{application,presentation}/**` (new controller/minimal UI);
- `lib/features/chat/application/{chat_workspace_controller,chat_workspace_state}.dart`
  and `lib/features/chat/presentation/{chat_workspace_page,chat_sidebar,workspace_shell}.dart`
  only for grouping/selection/scoped creation integration;
- `lib/app.dart` production composition;
- matching tests under `test/core/projects/**`,
  `test/infrastructure/projects/**`, `test/features/projects/**`, existing agent
  persistence/runtime/chat tests, platform import tests, and composition/restart
  tests;
- Linux/Windows/macOS/Android/iOS platform adapter/config files required by the
  selected matrix; web production composition only to enforce unsupported/no-write.

No provider, credentials, LLM transport, token-accounting, approved design, or
unrelated OpenSpec change path is expected. Implementation evidence must include
targeted migration/replay/grant/path/deletion/restart/widget tests plus
`dart format .`, `flutter analyze`, and `flutter test`, with cwd, exit codes,
concise output, changed-path set, and tested diff fingerprint.

## Risks / Trade-offs

- **[T2 persistence/schema]** A v3 session or new Project stream could make old
  data unreadable. → Lazy v1/v2 decode, independent envelopes/namespaces,
  compatibility fixtures, no eager rewrite, and explicit rollback floor.
- **[T2 permission capability]** Treating a path/token as active could expose
  files. → Separate desktop opaque store, truthful macOS security-scoped adapter,
  typed mobile sandbox roots, immediate/restart revalidation, no file tools.
- **[Traversal/link escape]** Textual containment is bypassable. → Canonical
  platform identity, component checks, link/junction rejection and negative fake
  filesystem tests before any later consumer exists.
- **[Cross-store crash]** Root/grant and Project commits cannot be one
  transaction. → Root/grant-first ordering, no visible Project before commit,
  conservative orphan cleanup, and missing-root/grant fail-closed recovery.
- **[Deletion partial failure]** Some chats can remain assigned. → Persisted
  deleting state, immediate access denial, idempotent restart saga, proof of zero
  remaining healthy memberships before tombstone.
- **[Platform overclaim]** Picker libraries differ from durable grants and mobile
  sandbox ownership. → Explicit tagged adapters and matrix tests; web unsupported,
  macOS fail-closed, and mobile external controls absent.
- **[Scope size]** Domain, persistence, three root modes, desktop grants,
  migration, and UI are coupled. → Complexity stays high; user explicitly selected
  Light, so one frozen snapshot receives parallel code review and verification.

## Migration Plan

1. Add Project/grant domain contracts and compatibility codecs with pure tests.
2. Add the independent Project store and v1/v2→v3 lazy session decode.
3. Add Linux/Windows/macOS external adapters, Android/iOS sandbox provisioners,
   web unsupported adapter, and the default-deny path policy.
4. Compose creation/recovery/deletion services and restart tests.
5. Add minimal Project UI and Project-scoped chat creation.
6. Run full Flutter checks and platform-specific adapter evidence.

No existing stream is rewritten during deployment. Rollback is safe before a v3
session is written; afterward use a compatibility binary, not an older decoder.
Existing user directories/files are never migration or rollback targets. A root
created by the current uncommitted operation may be removed only when still empty
and identical to the staged root; Project deletion never removes any root.

## Selected Execution Route

Risk remains T2 and refined complexity remains high. Heavy was the architectural
recommendation, but the user explicitly selected `light` for this slice:

1. coder `opencode-go/grok-4.6#xhigh` implements the complete selected matrix;
2. the implementation snapshot is frozen;
3. reviewer `openai/gpt-5.6-sol#high` and independent verifier
   `opencode-go/deepseek-v4.1-flash#max` run in parallel on that same snapshot;
4. reviewer owns code findings, while verifier returns AC-01…AC-12 evidence and
   formal check status. No implementation begins in this planning assignment.
