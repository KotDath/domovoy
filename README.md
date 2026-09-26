# Domovoy

Personal AI assistant built with Flutter. The application is a chat workspace
with projects, streaming reasoning and answers, provider/model settings, and a
layered memory inspector.

## Memory

Domovoy exposes three observable memory layers:

- **short-term** — the current chat transcript (never rewritten by memory);
- **working** — confirmed records owned by the current project;
- **long-term** — confirmed records shared across projects by the local user.

Candidates proposed by extraction are untrusted until you confirm them. Open the
memory inspector with the brain icon in the workspace header: desktop and tablet
show it as a side pane, phones open a bottom sheet. From the inspector you can
confirm, edit, or reject candidates; edit or forget confirmed records; toggle
whether working and long-term layers are supplied to the provider; run a manual
analysis; and inspect the exact context trace.

See [docs/memory.md](docs/memory.md) for reproducible demo steps, the extraction
policy, security behavior, mobile constraints, and smoke results.

## Personalization

Domovoy keeps one active assistant profile and can store multiple alternatives.
Each profile has a `SOUL.md` persona and a structured `USER.md` with style,
format, constraints, and user context. Open **Персонализация** in the sidebar to
create, clone, edit, import/export, activate, or delete profiles. An optional
five-step LLM interview prepares a preview of `USER.md`; nothing is written
until you confirm it.

The active profile is resolved for every provider request, so activation or an
edit affects the next message without recreating the chat. Profile data and
memory remain separate. See [docs/personalization.md](docs/personalization.md)
for the data model, request path, and demo script.

## MCP

Two standalone Streamable HTTP MCP servers provide Internet Archive search and
persistent scheduled digests. Domovoy discovers their tools at startup and makes
them available beside the local workspace tools. See
[docs/mcp-integration.md](docs/mcp-integration.md) for setup, the five-day demo
flow, tests, and VPS deployment notes.

## Linux development

The application stores an optional DeepSeek API-key override with Secret
Service. Install the `libsecret` runtime and development packages before
building the Linux desktop app. On Debian and Ubuntu:

```sh
sudo apt install libsecret-1-0 libsecret-1-dev
```

At runtime, Domovoy first uses the API key saved in its settings and otherwise
falls back to the `DEEPSEEK_API_KEY` process environment variable.

```sh
flutter pub get
flutter run -d linux
```

## Checks

```sh
dart format .
flutter analyze
flutter test
flutter build apk --debug
```
