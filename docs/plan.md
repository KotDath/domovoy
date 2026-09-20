# Day 11 implementation plan

## Outcome

Domovoy exposes three observable memory layers:

- short-term: the current agent transcript;
- working: confirmed records owned by the current project;
- long-term: confirmed records shared by the local user across projects.

The app creates a protected default project with an application-managed root so
that every chat has a project scope and future file tools have a safe directory.
An LLM may propose memory candidates in batches, but only user confirmation
makes a record active and eligible for retrieval.

## Implementation order

1. Add the default project kind, schema migration, managed root, bootstrap, and
   migration of unassigned sessions.
2. Add provider-neutral memory types, validation, lifecycle, and repository
   contracts in `lib/core/memory/`.
3. Add independent JSONL stores for working memory, long-term memory, candidates,
   and extraction checkpoints with native/web conditional adapters.
4. Add deterministic retrieval, prompt rendering, context budgets, and an
   auditable trace to agent requests without adding memory to the transcript.
5. Add explicit commands and a batch extractor using the existing LLM registry.
6. Add adaptive desktop/mobile memory UI and candidate confirmation.
7. Complete integration, restart, isolation, lifecycle, and security tests.

## Extraction policy

- A full automatic window contains 40 completed user/assistant messages.
- The next window retains a two-message overlap and advances by 38 messages.
- An idle flush becomes due 30 minutes after the last completed response.
- A manual `Analyze now` action flushes the pending batch immediately.
- Explicit project/global remember phrases create candidates without an LLM call.
- Only one extractor runs per session; failures do not advance its checkpoint.
- Mobile backgrounding persists scheduling state and cancels timers. On resume,
  an overdue flush runs in the foreground.

## Acceptance

- The default project is created exactly once and cannot be deleted.
- Existing unassigned chats are migrated; deletion of a user project reassigns
  its chats to the default project.
- Working memory never crosses project boundaries; long-term memory crosses
  projects; candidates never enter prompts.
- Retrieval does not require an LLM call. Extraction is not invoked per turn.
- Context traces identify the exact records supplied to the provider.
- Linux and Android smoke scenarios pass. iOS shares the native adapter and has
  platform/lifecycle tests; a physical iOS smoke requires a macOS host.
- `dart format .`, `flutter analyze`, `flutter test`, and
  `flutter build apk --debug` succeed.

