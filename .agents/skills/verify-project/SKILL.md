---
name: verify-project
description: Verify Domovoy changes against AGENTS.md, approved dependencies, layer boundaries, generated sources, and required Flutter checks before completion or when an invariant audit is requested. Report findings without repairing project files.
---

# Verify Domovoy

Read the repository's current `AGENTS.md` as the contract. Do not copy its package
versions into this skill. This workflow verifies changes; it does not authorize
dependency changes, repairs, commits, pushes, or modifications to SDK configuration.

## Establish the scope

1. Confirm the repository root, branch, and upstream/Aurora SDK versions. Inspect
   `git status`, the requested diff (including staged and unstaged changes), and
   new files. For a whole-project audit, review the whole maintained source tree.
   Do not assume a clean working tree or remove pre-existing changes.
2. Record baseline status and the contents of any tracked files checks could
   affect. Run generation and builds in an isolated temporary copy, not a Git
   worktree. Include current source, platform files, manifest, both lockfiles, metadata,
   assets, and relevant untracked source; exclude `.git`, build output, SDK caches,
   and secrets. Do not compare against HEAD when verifying uncommitted work.
   For Aurora PSDK builds, place the copy under the user's home directory: the
   chroot mounts home, while host `/tmp` is not visible at the same path inside it.
3. Distinguish changes to handwritten/generated Dart, dependencies, native platform
   files, build configuration, and documentation. Documentation-only changes need
   a contract/skill consistency review, not unrelated application builds.

## Contract checks

- Compare every runtime/dev manifest entry and its exact version or SDK source
  with the allowlist in `AGENTS.md`. Reject extras, missing entries, wrong scopes,
  overrides, and git/path sources unless the user has explicitly approved a new
  contract. Review both lockfile diffs and SDK constraints too.
- Inspect project imports/exports, including untracked source and conditional
  imports. Reject undeclared direct use of transitive packages, dev imports in
  runtime code, competing libraries, and legacy state APIs.
- Trace imports and dependency creation across affected layers. Check that domain
  remains pure Dart, application uses contracts, data owns I/O, app composes
  implementations, and portable code isolates platform APIs. Static searches are
  evidence to inspect, not proof of all architecture rules.
- Check screen routing, the allowed local-state exception, identifier consistency,
  unchanged lint baseline, and any applicable secrets/platform permissions rules.

## Executable checks

Run Flutter commands sequentially to avoid concurrent pub/plugin-generation
updates. Use the upstream SDK's Dart for formatting and codegen as well.

- Resolve in the temporary copy with upstream `flutter pub get --enforce-lockfile`
  to validate `pubspec.lock`. Before Aurora builds, run the same command using
  the Aurora SDK to validate its separate `aurora_pubspec.lock` and select that
  SDK's packages. Switch back with upstream resolution before upstream checks.
  A stale/missing lockfile is a failure; do not regenerate it in the working tree.
- Check formatting with `dart format --output=none --set-exit-if-changed lib test`.
  Run `flutter analyze --no-pub` and `flutter test --no-pub` for code/config changes.
- When generated inputs change, or during a whole-project audit with annotated
  sources, run `dart run build_runner build` in the copy. Compare generated files
  byte-for-byte against the current working sources, including missing/new outputs.
  A difference is a failure, not permission to repair or commit it. If there are no
  annotated sources, report generation as `NOT RUN — not applicable`.
- Dependency, native-platform, SDK/build-config changes require relevant builds
  in the copy. Shared dependency changes require Linux, Web, Android, Windows,
  macOS, and Aurora; native changes require their affected targets. Windows/macOS
  need suitable hosts. Use debug standard builds and the documented release Aurora
  baseline. Report unavailable hosts/tools explicitly.
- Apply the accepted Aurora RPM diagnostics in `AGENTS.md` when interpreting
  `rpmlint` output. Those occurrences do not fail verification, trigger repairs,
  or appear as violations in routine reports. Preserve raw tool output and
  evaluate other diagnostics normally; do not change SDK or linter configuration.
- If the app does not yet use approved libraries, a plain scaffold build does not
  test them. Add a separate temporary smoke entrypoint using generated Riverpod,
  typed auto_route, and `http` stream/cancellation APIs, then generate/analyze/build
  it on available targets. Do not copy this test application into the repository.
  Compile checks do not prove runtime SSE, CORS, device behavior, or permissions.

## Report

Provide a compact table: check, `PASS` / `FAIL` / `NOT RUN`, evidence or reason.
List violations with file/line and the applicable contract rule; list commands
actually executed and unavailable targets. `NOT RUN` is not a successful check.
Conclude whether the requested change passed its available checks and which
required checks remain unverified. Confirm working sources were preserved.

Do not silently format, regenerate, weaken rules, add packages, or substitute
versions. On failure, report the concrete next repair step for the implementing
task. If the skill itself changed, also run the installed `skill-creator`
`quick_validate.py` against its folder; this checks skill structure, not behavior.
