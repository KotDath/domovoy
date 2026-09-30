# Domovoy repository contract

## Project and platforms

- Domovoy is a personal AI assistant. Keep one Flutter package named `domovoy`
  and one root `pubspec.yaml`; do not introduce nested packages or workspaces.
- Application identifier: `ru.kotdath.domovoy` on every platform; keep
  `organization: ru.kotdath` in the manifest for Aurora packaging.
- Required targets: Linux, Windows, macOS, Android, Web, and Aurora. Keep the
  existing iOS scaffold; iOS is outside the required verification matrix for now.
- Approved toolchains: upstream Flutter 3.41.4 and Flutter Aurora 3.41.4,
  both with Dart 3.11.1. SDK upgrades require explicit user approval.

## Repository navigation and layer boundaries

- `lib/main.dart`: entry point. `lib/app/`: application composition, root
  providers, and router. Wire concrete implementations and provider overrides here.
- `lib/core/`: shared contracts and infrastructure primitives, including a
  Flutter-independent HTTP transport. Core must not depend on features or app.
- `lib/features/<feature>/domain/`: entities and repository contracts; pure Dart,
  independent of Flutter, Riverpod, HTTP, and concrete storage implementations.
- `lib/features/<feature>/data/`: implements domain contracts and performs I/O.
  `application/`: use cases and Riverpod providers/notifiers, using domain
  contracts. `presentation/`: Flutter UI, using application and domain APIs.
- Dependency direction: presentation → application → domain; data → domain.
  Application and presentation must not import data implementations. App composes
  the layers. Cross-feature calls use public domain/application interfaces;
  never import another feature's data or presentation internals.
- Create directories when code needs them; do not generate empty layer scaffolds.
- Tests mirror `lib/` under `test/`; reusable test support belongs in `test/support/`.

## State, navigation, and networking

- Riverpod is the only application state and DI mechanism. Use generated
  providers and modern `Notifier`/`AsyncNotifier`/`StreamNotifier` APIs as needed.
  Do not use Riverpod's legacy providers or `legacy.dart`.
- Local widget state, animation controllers, and text controllers may use
  ordinary Flutter mechanisms, including `setState`; keep business state out of UI.
- Use auto_route and generated typed routes for screen navigation. Flutter
  dialogs and modal overlays are allowed. Do not build a parallel screen router
  with `Navigator.push`, named routes, or another routing package.
- Use `package:http` for HTTP in core transport and feature data adapters.
  Keep HTTP types and request details out of domain, application, and UI.
- The future network layer must support incremental LLM responses and request
  cancellation on every required target, including Web. SSE parsing belongs in
  the transport layer; selecting `http` does not implement SSE by itself.
- Isolate OS-specific code using conditional imports and `*_io.dart`,
  `*_web.dart`, and `*_stub.dart` adapters. No `dart:io` in portable files.
  Do not reference Aurora-only SDK APIs from code compiled by upstream Flutter.
- Never commit credentials or log authentication headers. Platform capabilities
  and permissions must be checked when adding platform functionality.

## Approved direct dependencies

This table is the authoritative allowlist. `pubspec.yaml` must match it exactly.
Adding, replacing, removing, or changing a direct dependency or its version
requires explicit user approval; update this table and the manifest together.

| Scope | Package | Version/source |
| --- | --- | --- |
| runtime | flutter | Flutter SDK |
| runtime | flutter_riverpod | 3.3.1 |
| runtime | riverpod_annotation | 4.0.2 |
| runtime | auto_route | 11.1.0 |
| runtime | http | 1.6.0 |
| dev | flutter_test | Flutter SDK |
| dev | flutter_lints | 6.0.0 |
| dev | build_runner | 2.15.1 |
| dev | riverpod_generator | 4.0.3 |
| dev | auto_route_generator | 10.4.0 |

- Competing solutions are prohibited: BLoC/flutter_bloc, Provider, GetX,
  get_it/injectable, alternative screen routers, and alternative HTTP clients.
- Transitive dependencies resolved by pub are allowed. Project code must only
  import declared direct dependencies; runtime code cannot import dev dependencies.
- No `dependency_overrides`, `pubspec_overrides.yaml`, or unapproved git/path
  dependencies. Commit both `pubspec.lock` (upstream) and `aurora_pubspec.lock`
  (Aurora fork); do not update packages opportunistically. Resolve and enforce
  each lockfile with its own SDK before its checks/builds.

## Generation and verification

- Use `dart run build_runner build` with the approved upstream SDK.
  Commit `.g.dart` and `.gr.dart` beside their sources; do not edit outputs manually.
- Keep `package:flutter_lints/flutter.yaml`; do not weaken lint settings just
  to make checks pass.
- Before completing code, dependency, architecture, or platform changes, use
  the project skill `.agents/skills/verify-project/SKILL.md`. Load it through
  your agent's native skill mechanism, or read the file directly if unavailable.
  It reports results and does not repair working files.
- Format implementation changes with `dart format .`. Required code checks:
  `dart format --output=none --set-exit-if-changed lib test`,
  `flutter analyze --no-pub`, and `flutter test --no-pub`.
- Platform/configuration/dependency changes also require relevant platform
  builds. Run upstream Flutter for standard targets and all unit/widget tests;
  run the Aurora fork for Aurora builds. An unavailable check is `NOT RUN`, never
  `PASS`; describe the missing toolchain or host instead of claiming coverage.
- Standard SDK on this machine: `/home/kotdath/flutter/bin/flutter`.
  Aurora SDK: `/home/kotdath/omp/shared/flutter_kits/flutter-aurora-3.41.4/bin/flutter`.
  Discover equivalent paths on other hosts; do not change global SDK settings.
- Current Aurora build baseline: PSDK 5.2.0.180, `aurora-arm` (armv7hl),
  `--psdk-dir=/home/kotdath/MyPSDKDir/sdks/aurora_psdk`. Preserve other platforms'
  migration entries when updating `.metadata`. Generated RPMs and build caches
  stay untracked. An RPM build alone does not certify on-device behavior.
- Use Conventional Commits, e.g. `chore(project): define project invariants`.

## Shared agent instructions and skills

- Maintain project skills in `.agents/skills/` using the Agent Skills format
  (`<name>/SKILL.md` with `name` and `description` frontmatter).
- Codex, OpenCode, and Pi discover this directory directly. Claude Code uses
  `.claude/skills`, a relative symlink to the same directory. Add future skills
  to the shared directory; keep one maintained copy of each skill.
- Keep `AGENTS.md` as the single repository contract. All agents must load it
  before project work and use `.agents/skills/` or their supported skill-path
  configuration. Native Claude Code loading of `AGENTS.md` requires 2.1.277
  or later; load it explicitly when using an older version.
- Invoke `verify-project` as `$verify-project` in Codex,
  `/verify-project` in Claude Code, `/skill:verify-project` in Pi, or through
  OpenCode's `skill` tool. Other agents can read its `SKILL.md` directly.

## Accepted Aurora RPM diagnostics

Ignore the following existing `rpmlint` diagnostics from the Flutter Aurora
3.41.4 template with PSDK 5.2.0.180, including those labelled `E` by the tool.
They are accepted, do not fail project verification, and do not require repairs
or repeated warnings in routine reports.

| Diagnostic | Accepted occurrence |
| --- | --- |
| `arch-dependent-file-in-usr-share` | `libapp.so`, `libaurora_embedder.so`, and `libflutter_engine.so` under `/usr/share/ru.kotdath.domovoy/lib/` |
| `shared-library-without-dependency-information` | The generated `libapp.so` |
| `no-changelogname-tag` | The application's generated RPM spec without `%changelog` |
| `unstripped-binary-or-object` | `/usr/bin/ru.kotdath.domovoy` |
| `summary-ended-with-dot` | The application summary `Personal AI assistant.` |
| `no-url-tag` | The application's generated RPM spec without a URL |
| `no-soname` | The generated `libapp.so` |
| `hidden-file-or-dir` | `/usr/share/ru.kotdath.domovoy/flutter_assets/.last_build_id` |

Apply these exceptions when interpreting output; keep the SDK and `rpmlint`
configuration unchanged. Evaluate diagnostics outside this list normally.
