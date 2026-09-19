# Project workspaces · blocked

## Карточка участка · 19 сентября 2026

- **scope_id:** `add-project-workspaces-impl-01`
- **attempt_id:** `1`
- **stage:** `blocked`
- **change:** `add-project-workspaces`
- **base_revision:** `635c53abf571860fc8211e1b6569039eb94db6d0`
- **стартовый implementation fingerprint:**
  `9f68ac980d80eb36a59fbfd23d99e05f4a354b4e9f3b554139d82600604b788a`
- **стартовый dirty/untracked diff:** approved `design/`,
  `.opencode/workflow/feature-state/redesign-workspace-shell.md`, both OpenSpec
  changes, and the existing partial Project implementation; preserved without
  reset/delete/discard.
- **rework_count:** `1` (maximum `2`).
- **execution_mode:** `light`; **current_tier:** `T2`.
- **writer:** `openai/gpt-5.6-sol#high`, replacing Grok by explicit user
  direction; no delegation and no Grok usage.
- **gates:** `final-01` approved; `redesign-workspace-shell` remains
  `waiting_dependency`.
- **full dirty/untracked normalized fingerprint:** `61e5f74f02ad5f58e5d4d0337914309c23c0d5d75617c416686320638213f936`.
  Algorithm: SHA-256 over sorted dirty/untracked path + bytes, with only this
  fingerprint value normalized to `PENDING` so the state file can identify
  itself.

## Fix cycle 1 findings

All code fixes below are **fixed_pending_review**; only the finding author may
close them. The snapshot is not accepted or frozen because the mandatory widget
test command does not terminate.

- `PW-REV-001` **fixed_pending_review** — production composition now uses
  `file_selector` native directory UI, `IoDesktopFilesystem`, durable native-only
  file grant storage, a macOS security-scoped bookmark MethodChannel, and
  physical app-support sandbox directories. Production composition contains no
  scripted/in-memory/fake adapters. Added reconstruction/composition tests.
- `PW-REV-002` **fixed_pending_review** — default Project/grant/deletion IDs now
  include secure random material and timestamp; reconstruction regression added.
- `PW-REV-003` **fixed_pending_review** — desktop revalidation checks descriptor
  status, Project/role/access/platform binding, stored and current canonical
  identity, effective access, and macOS restored scope; revoked/cross-Project/
  changed-target tests added.
- `PW-REV-004` **fixed_pending_review** — Project session creation is a service
  command under the same serial lock as deletion and reloads active/healthy
  Project state before the durable chat callback; delete-vs-create race added.
- `PW-REV-005` **fixed_pending_review** — Project/startup selection aligns to a
  deterministic group member or closes the foreign session; presentation hides
  timeline/composer unless the selected chat belongs to the visible group;
  controller and widget regressions added.
- `PW-REV-006` **fixed_pending_review** — controller subscribes to chat catalog
  projections and refreshes groups after create/delete/title/message mutations;
  selection/deletion UI commands route through it; regression added.
- `PW-REV-007` **fixed_pending_review** — deletion converts Agent/unknown
  persistence failures to sanitized results while preserving `deleting`;
  controller refreshes in `finally` and clears busy; resumability and controller
  failure regressions added.

## Changed paths in fix cycle

- `pubspec.yaml`, `pubspec.lock`, generated Linux/macOS/Windows plugin registrants
- `lib/core/projects/provisioning.dart`
- `lib/infrastructure/projects/**` production picker/filesystem/grant/scope/mobile
  adapters and stricter revalidation
- `macos/Runner/MainFlutterWindow.swift`
- `lib/features/projects/application/{project_application_service,project_workspace_controller,project_workspace_state}.dart`
- `lib/features/chat/presentation/chat_workspace_page.dart`
- targeted tests under `test/infrastructure/projects/**` and
  `test/features/projects/**`
- this state file and `tasks.md` checkbox 6.3 only

## Evidence and blocker

cwd for every command:
`/home/kotdath/orca/workspaces/domovoy/feature-rework-ui`

| command | exit/result | concise output |
| --- | --- | --- |
| `flutter pub get` | 0 | added `file_selector` 1.1.0 and platform packages |
| initial targeted `dart format ...` | 65 | included Swift by mistake and exposed misplaced mobile imports; imports fixed, subsequent Dart formatting passes |
| `flutter analyze` (latest) | 0 | `No issues found! (ran in 1.2s)` |
| targeted provisioner/import/service/controller tests | 1 first run | one canonical-target expectation failed; implementation fixed |
| `flutter test test/infrastructure/projects/provisioner_test.dart` | 0 | `+11: All tests passed!` after fix |
| combined mandatory finding tests | 1 | newly added widget test missed `ProjectCreateDraft` import; import fixed |
| `flutter test test/features/projects/project_workspace_page_test.dart` | timeout/SIGTERM | first widget test completes initialization but command remains in finalization/disposal; repeated after two fixes (non-awaited close, then explicit widget unmount) and still did not terminate |

Successful tests before the widget blocker include production composition,
desktop/mobile reconstruction, ID restart, revoked/cross-Project/current-target
revalidation, admission-vs-delete, selection alignment, direct catalog refresh,
and deletion persistence/finally regressions. The combined command reached
`+30` with only the widget compile issue before that import was fixed.

**BLOCKER:** mandatory targeted widget evidence and therefore `flutter test`
cannot be completed because the Flutter tester process hangs during disposal and
is killed by the command timeout. Two attempted fixes did not resolve that same
failure, so policy forbids another fix attempt in this assignment. `dart format
.` and full `flutter test` are not claimed. Task 6.3 is reopened. No commit or
push was made.

Environment: Linux Flutter/Dart VM. Live macOS TCC/bookmarks, Windows junctions,
and Android/iOS devices were not exercised on-device; their production adapters
are source/contract tested only.
