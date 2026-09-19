## Why

The approved workspace hierarchy requires real Project → Chats ownership, while
production currently stores only flat durable sessions and has no trustworthy
directory-access contract. Projects must therefore be established as a durable,
fail-closed domain and persistence boundary before the approved shell can be
implemented without fake grouping or permissions.

## What Changes

- Add a versioned Project entity, repository, catalog, optimistic mutations,
  tombstones, corruption isolation, and restart recovery independent from chat
  transcript storage.
- Add nullable durable `projectId` membership to sessions. Existing records
  decode as unassigned and remain recoverable under `Без проекта` without eager
  rewrite.
- Add a platform-neutral root/access abstraction that distinguishes desktop
  external grants from mobile app-owned sandbox roots. Linux, Windows, and macOS
  can attach an existing exclusive read/write root or create a new exclusive
  project folder and can add external read-only directories. Android and iOS
  create only an app-owned sandbox project directory, with no root picker or
  external additional-directory grants. No native token or grant material enters
  a transcript or ordinary Project/session JSON.
- Make Project creation commit only after its platform-specific root is created or
  attached, canonicalized, checked for collision, durably recorded, and
  revalidated where applicable. Desktop additional directories follow the same
  grant checks. Missing, stale, revoked, unsupported, corrupt, or unverifiable
  access is never presented as active and authorizes no filesystem access.
- Add a minimal truthful project-first workspace: create/select Project, create a
  chat in the selected Project, list legacy/unassigned chats under `Без проекта`,
  and surface loading, empty, unsupported, permission-lost, and corruption states
  across restart. This milestone is functional scaffolding, not a competing
  redesign of approved `final-01`.
- Define safe Project deletion as a recoverable multi-step operation: deny new
  access, unassign chats, tombstone the Project, and revoke stored grants without
  deleting user files or chat transcripts.
- Keep agent filesystem tools, file reads/writes, attachment/context composition,
  indexing, and tool permission prompts out of this change. A later change must
  consume the validated root/grant boundary and enforce its child-path policy.
- Deliver full adapters on Linux, Windows, and macOS; macOS uses a truthful
  durable security-scoped mechanism and fails closed when it is unavailable,
  stale, or revoked. Deliver sandbox-only Project creation on Android and iOS.
  Web Project creation is explicitly unsupported and performs no Project/root/
  grant write; browser project storage is future work.

## Capabilities

### New Capabilities

- `project-workspaces`: Project domain, directory-grant references and
  fail-closed platform abstraction, persistence/recovery, lifecycle operations,
  and the minimal truthful project-first milestone.

### Modified Capabilities

- `agent-session-persistence`: Persist nullable Project membership in session
  records/catalog summaries with backward-compatible unassigned restoration and
  safe missing/corrupt-Project handling.
- `chat-workspace-ui`: Add real Project selection, Project-scoped chat creation,
  `Без проекта` recovery, and capability/error states before the final shell
  redesign.

## Impact

- Affects core Project contracts, session record/catalog codec versioning,
  JSONL-style Project persistence, production composition, project/chat
  application state, a minimal Project UI, platform directory selection/grant
  adapters, dependencies, and recovery/security tests.
- Does not modify provider protocols, credentials, token accounting, agent tool
  registration, or the accepted `add-provider-discovery-and-api-usage` change.
- `redesign-workspace-shell` remains a dependent planned change and must not
  enter implementation until this change is accepted. Platform rollout and the
  Light execution route for this change are now selected.
