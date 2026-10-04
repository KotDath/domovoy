# Personalization: profiles and interview

## Profile model

A profile contains two independent Markdown documents:

| Document | Purpose | Limit |
|---|---|---:|
| `SOUL.md` | Assistant role, manner, and truthfulness rules | 4,000 characters |
| `USER.md` | User preferences and durable working context | 2,500 characters |

`USER.md` must contain the exact sections `STYLE`, `FORMAT`, `CONSTRAINTS`, and
`CONTEXT`. The editor rejects control characters and text that resembles a
credential. Profiles do not own chats, projects, models, API keys, or memory.
Changing a profile therefore changes communication behavior without moving or
duplicating any other user data.

The first launch creates and activates a safe default profile. New profiles can
start from the universal, learning, or experienced-developer template. A clone
copies both Markdown documents and receives a new identity and revision chain.

## Persistence and request path

Profiles and the active selection use separate append-only JSONL streams with
optimistic revisions. Native platforms store them in application-support data;
web uses origin-local browser preferences. Import and export use real Markdown
files while JSONL remains the canonical application store.

For every model turn, `PersonalizationDynamicContextProvider` reloads the
active selection and its latest profile revision. The profile block is escaped,
labeled as user-configured communication context, and combined before the
separate memory block. It enters only the provider system prompt and never the
chat transcript, continuation state, or compaction input. The profile screen
shows the profile name, revision, and rendered character count from the last
request trace.

## Interview behavior

The **Интервью при создании** switch controls whether profile creation offers
the interview by default. The same interview can be started later for any
profile.

The interview uses the currently selected chat model in a transient, tool-free,
single-turn agent. It asks one concise question for each topic: role, style,
format, constraints, and context. The model then drafts only `USER.md`.
Domovoy validates the four required sections and displays the result for review.
Cancelling leaves the repository untouched. For a new profile, **Применить**
creates it with the reviewed draft. For an existing profile, **Применить**
copies the draft into the editor and **Сохранить** creates a new revision.
`SOUL.md` is never changed by the interview.

## Reproducible demo

```sh
flutter pub get
flutter run -d linux
```

1. Open **Персонализация** in the sidebar. The default profile is active.
2. Create an **Обучение** profile without the interview. Inspect both tabs and
   activate it.
3. Create another profile with the interview. Answer the five questions, review
   `USER.md`, and apply it. No profile appears if the dialog is cancelled.
4. Edit `SOUL.md` or `USER.md`, save it, then send a chat message. Return to the
   profile screen and inspect the last-request revision trace.
5. Activate the other profile and send the same prompt. The next answer uses the
   newly active profile while the chat and memory remain unchanged.
6. Export either document, change it in a text editor, import it, and save the
   new revision.

## Verification

The automated suite covers document validation and escaping, JSONL replay and
truncated-tail recovery, switching the active profile between consecutive
requests, ordered composition with memory, interview validation, and the main
profile editor flow.
