# Memory: behavior, demo, and smoke

This guide describes the shipped memory behavior and how to reproduce it.

## Layers and scopes

| Layer | Source | Scope | Lifetime |
|---|---|---|---|
| Short-term | `AgentTranscript` | current chat | until compaction/chat deletion |
| Working | `memory-v1_` JSONL | current project | until edited, forgotten, or project deletion |
| Long-term | `memory-v1_` JSONL | local user | across projects and chats |

Working records require a project; long-term records are user-global. Retrieval
never mixes them: a working record is only ever returned for its own project.

## Extraction policy

- A full automatic window contains **40** completed user/assistant messages.
- The next window retains a **2**-message overlap and advances by **38**.
- An idle flush becomes due **30 minutes** after the last completed response and
  runs in the foreground only.
- **Analyze now** (memory inspector) flushes every pending source immediately.
- **Analyze now** also replays deterministic explicit phrases, so it can recover
  a missed automatic callback without relying on the extraction model.
- Explicit phrases create candidates with no LLM call:
  `remember project: ...`, `remember global: ...`, `remember: ...`,
  `remember that ...`, `запомни проект: ...`, `запомни глобально: ...`,
  `запомни, что ...`.
- When the deterministic parser finds no command, an isolated LLM classifier
  checks only the latest user message. It returns `none`, `working`, or
  `longTerm` with a self-contained fact, so typos and natural wording such as
  `Запомни гглобально, что меня зовут Даниил` remain usable.
- Equivalent candidates and already-confirmed active records are deduplicated
  across the command and periodic batch paths.
- No-op update proposals whose target already contains the same content are
  discarded. A real confirmed update preserves old source IDs and appends the
  new provenance.
- Only one extractor runs per session; a failure never advances the checkpoint,
  so the same batch is retried. Candidate identities are deterministic per
  session/source/proposal, so a retried batch cannot duplicate records.
- Command classification may run once after a completed user turn; periodic
  batch extraction still runs only at the configured window, idle deadline, or
  manual action.

## Confirmation and gating

Candidates are untrusted proposals. They never enter prompts. From the memory
inspector you can:

- **confirm** a candidate (creates a working/long-term record; an `update`
  candidate revises its target in place);
- **edit** a candidate's content and kind before confirming;
- **reject** a candidate (terminal, kept for audit);
- **edit** or **forget** a confirmed record.

The trash action in the inspector header clears the currently selected
persistent surface after confirmation: current-project working entries are
forgotten, global long-term entries are forgotten, and pending candidates are
rejected. The short-term tab has no clear action because it is the chat
transcript; clear it by deleting the chat.

## Read path and trace

Retrieval is deterministic and never calls a provider. Working records are
supplied first, then always-eligible long-term preferences, then lexically
ranked facts/procedures/profiles/policies capped at five. The rendered block is
capped at 12,000 characters. The memory inspector can show the exact
`MemoryContextTrace` (included/excluded, reason, rendered size, truncation).

Read toggles in the inspector disable a layer at runtime; disabled records are
still listed in the trace with reason `layerDisabled`.

## Security and trust

- Detected secrets (provider keys, key assignments, PEM keys, long opaque
  tokens) never become candidates or records.
- The rendered block is labeled as untrusted data, never instructions, and
  `<`/`>`/`&` are escaped so stored data cannot close the block or inject
  markup.
- Memory is only supplied to provider requests; it is never appended to the
  transcript, continuation state, or compaction input.

## Composition and lifecycle

`lib/app.dart` wires the JSONL memory stack, layered retrieval, a live read
toggle provider, the registry-backed command classifier and batch extractor,
and the extraction coordinator. `ChatWorkspaceController.onTurnCompleted`
records completed turns without delaying the chat command. On Android/iOS the
app lifecycle pauses extraction when backgrounded and resumes an overdue flush
in the foreground; desktop/web remain foreground-only.

## Reproducible desktop demo

Requires `libsecret` (see `README.md`) and a DeepSeek key in settings or
`DEEPSEEK_API_KEY`.

```sh
flutter pub get
flutter run -d linux
```

1. Create a project and a chat.
2. Send `Запомни, что деплой делается только через kubernetes`.
3. Open the memory inspector (brain icon in the header). Under **Кандидаты**
   confirm the candidate.
4. Under **Рабочая** the confirmed record appears. Edit or forget it.
5. Send a normal question; open **Показать трассу** to see the exact records
   supplied (reason `workingPriority`/`confirmedPreference`/`lexicalMatch`).
6. Toggle **Долговременная память** off; the trace now shows
   `layerDisabled` for long-term records.
7. Press **Анализировать** to run a manual extraction; new candidates appear
   for confirmation.
8. Restart the app: confirmed records and pending candidates persist; the
   inspector reloads them.

## Mobile constraints

- Extraction timers and LLM calls are foreground-only.
- Pausing records the last activity and pending sources and cancels timers;
  resuming recomputes the deadline and flushes overdue work in the foreground.
- Confirmed memory persists in application-support storage on Android/iOS;
  the web build stores streams in origin-local browser preferences.
- Android and iOS share the same Flutter lifecycle bridge and native storage
  adapter contract; a physical iOS smoke still needs a macOS host.

## Smoke checklist and results

Environment: Fedora Linux 44, Flutter 3.41.4, Android SDK 36.1.0, Linux
toolchain available.

| Check | Command | Result |
|---|---|---|
| Formatting | `dart format .` | ✅ no changes required |
| Static analysis | `flutter analyze` | ✅ `No issues found!` |
| Test suite | `flutter test` | ✅ 722 passed, 1 skipped |
| Android debug build | `flutter build apk --debug` | ✅ `build/app/outputs/flutter-apk/app-debug.apk` |
| Linux debug build | `flutter build linux --debug` | ✅ `build/linux/x64/debug/bundle/domovoy` |
| Linux launch | `./build/linux/x64/debug/bundle/domovoy` | ✅ Dart VM service started; GTK window remained alive until the smoke timeout (only a non-fatal `Gdk-Message: Unable to load … cursor theme` warning) |
| Android emulator UI smoke | `flutter run -d <emulator>` | ⛔ not run: no emulator/device was booted in this environment |
| iOS smoke | macOS host required | ⛔ not run in this environment |

Interactive UI automation was not performed; the desktop app was launched to
confirm the debug bundle starts. Re-run the demo steps above on a graphical
machine to exercise the inspector end to end.
