## ADDED Requirements

### Requirement: Minimal truthful Project workspace milestone
Before the final approved shell redesign, production SHALL expose a minimal
functional Project workspace that lists healthy Projects and their member chats
from durable catalogs, lists null/unresolved legacy memberships under
`Без проекта`, and permits selection of a healthy Project or unassigned context.
Selecting a Project SHALL reveal its chats and safe directory-access status
without reading project files. Creating a chat while an active healthy Project is
selected SHALL create exactly one durable session with that Project identity;
creating from `Без проекта` SHALL create exactly one session with null membership.
The milestone SHALL reuse the existing chat timeline/composer behavior and SHALL
not imitate a decorative or partial version of `final-01`.

#### Scenario: Projects and chats load after restart
- **WHEN** fresh dependencies restore two Projects, their member sessions, and legacy null-membership sessions
- **THEN** each chat appears exactly once beneath its real Project or `Без проекта`, Project identity survives restart, and no group is inferred from title/provider/path

#### Scenario: Chat is created in selected Project
- **WHEN** the user selects an active healthy Project and activates new chat
- **THEN** one repository-backed session is created with that Project identity and appears only in that Project

#### Scenario: Chat is created without a Project
- **WHEN** the user selects `Без проекта` and activates new chat
- **THEN** one repository-backed session is created with null Project identity and appears only under `Без проекта`

#### Scenario: Project has no chats
- **WHEN** a newly created Project is selected before any chat exists
- **THEN** a truthful empty state offers Project-scoped new chat and shows no fabricated conversation

### Requirement: Project creation and platform/access states
The minimal workspace SHALL adapt Project creation to the selected support matrix.
On Linux, Windows, and macOS it SHALL collect a bounded valid name and require an
explicit root mode: attach an existing exclusive read/write directory or create a
new exclusive project folder; it MAY collect external additional directories and
SHALL label them read-only. On Android and iOS it SHALL collect the Project name
only and explain that the root is app-owned; root-picker, additional-directory,
external-grant, and regrant controls SHALL be absent. On web Project creation
SHALL be unavailable with a truthful explanation and no writable fallback.

Desktop picker/folder cancellation SHALL return to the prior state without a
Project. Loading, unsupported-platform, permission-lost/regrant-required, Project
corruption, grant/root corruption, collision, cleanup warning, cancellation,
persistence failure, and deletion-in-progress SHALL remain distinct sanitized
states. The UI SHALL call application commands rather than mutate Project/session/
grant storage directly and SHALL never display an access status stronger than the
latest platform result.

#### Scenario: Desktop creation succeeds
- **WHEN** Linux, Windows, or macOS acknowledges a valid name, attached or newly created root, and optional additional selections
- **THEN** the new empty Project becomes selectable with the adapter-reported active access state and no chat or project file is created implicitly

#### Scenario: Android or iOS creation succeeds
- **WHEN** the user submits a valid Project name on Android or iOS
- **THEN** the new empty Project uses its app-owned sandbox root and the flow never displays or calls a root picker, additional-directory picker, external grant, or regrant action

#### Scenario: Web Project creation is unavailable
- **WHEN** the workspace runs on web
- **THEN** Project creation is disabled or returns a truthful unsupported explanation, typed path entry and placeholder grants are absent, no Project-related write occurs, and `Без проекта` chats remain fully usable

#### Scenario: Access is lost after restart
- **WHEN** Project metadata and chats restore but root or additional grant revalidation fails
- **THEN** the Project remains visible, its chats remain usable, access is labeled unavailable/regrant-required, and no filesystem capability is claimed

#### Scenario: macOS security-scoped grant is stale
- **WHEN** the macOS adapter reports its persisted root or additional security-scoped reference stale or revoked
- **THEN** the Project remains visible, all filesystem access is denied, no active grant claim appears, and a supported explicit regrant action may be offered

#### Scenario: Corrupt Project is referenced by chats
- **WHEN** the Project catalog reports an unreadable Project referenced by healthy sessions
- **THEN** those chats remain recoverable under `Без проекта` with one sanitized warning and no directory path/token/raw corrupt content

### Requirement: Safe Project deletion presentation
The workspace SHALL request explicit confirmation bound to the selected Project
identity and explain that chats will move to `Без проекта`, grants will be
revoked, and user files will remain untouched. While deletion is admitted or
being recovered, that Project SHALL reject new chats and show non-active access.
Completion SHALL remove the Project, retain its chats under `Без проекта`, and
return focus/selection to a deterministic remaining Project, unassigned chat, or
new-Project action. Cancellation or failure SHALL not be presented as success.

#### Scenario: User cancels Project deletion
- **WHEN** the confirmation is dismissed before deletion admission
- **THEN** Project, chat grouping, grant status, files, selection, and focus return remain unchanged

#### Scenario: Project deletion completes
- **WHEN** the confirmed operation unassigns chats, tombstones the Project, and revokes grants
- **THEN** all former chats appear under `Без проекта`, the Project disappears, the UI states that files were not deleted, and focus moves predictably

#### Scenario: Deletion recovery is incomplete
- **WHEN** restart or conflict leaves deletion pending
- **THEN** the Project is shown as deleting/error, grants and new Project chats remain disabled, and the UI does not claim completion

### Requirement: Accessible Project navigation without final-shell redesign
Project creation, selection, disclosure, new chat, regrant where supported,
deletion confirmation, and `Без проекта` SHALL be keyboard reachable with visible
focus, stable semantics, deterministic test keys, and at least 44 logical-pixel
targets. Narrow layouts SHALL keep these states reachable without horizontal
overflow. The approved `final-01` remains the source for the later shell change;
this milestone SHALL limit visual work to clear functional structure and error/
permission communication.

#### Scenario: Keyboard creates and selects a Project
- **WHEN** a keyboard user completes supported Project creation and navigates its chat list
- **THEN** focus order is deterministic, status/name/access labels are announced without native token/path leakage, and focus reaches Project-scoped new chat

#### Scenario: Narrow unsupported platform renders
- **WHEN** the web workspace is shown at 390 by 844 logical pixels
- **THEN** `Без проекта`, existing chats, Project unavailability explanation, and settings remain reachable without clipping, horizontal overflow, or a hidden writable Project action
