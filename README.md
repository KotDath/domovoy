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
