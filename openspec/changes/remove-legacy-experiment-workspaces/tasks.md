## 1. Retain a single prompt application surface

- [ ] 1.1 Simplify the application composition root to construct only the retained one-shot prompt workspace and remove the Day 2–5 navigation, state, factories, and lifecycle wiring.
- [ ] 1.2 Update the prompt-level widget and dependency-injection tests so they verify the sole workspace still exposes prompt input, streaming output, settings access, responsive layout, and another independent submission after termination.
- [ ] 1.3 Run the prompt transport, credential, controller, and widget tests that remain relevant, then create an intermediate commit containing only the coherent single-workspace transition.

## 2. Remove legacy experiment slices

- [ ] 2.1 Delete the `lab`, `reasoning`, `temperature`, and `comparison` feature trees without retaining experiment-specific profile, pricing, lane, evaluation, prompt-preset, or persistence abstractions.
- [ ] 2.2 Delete every unit, widget, fake-stream, and opt-in live smoke test whose behavior belongs only to Days 2–5, while retaining tests for the one-shot prompt, SSE decoding, credentials, settings, and current reasoning toggle.
- [ ] 2.3 Delete the Day 2–5 demonstration checklists and remove the now-empty integration-test setup and dependency when no retained test requires it.
- [ ] 2.4 Remove unused direct dependencies such as `cupertino_icons`, refresh dependency metadata with `flutter pub get`, and remove or ignore the untracked Eclipse Android project artifacts without staging unrelated files.
- [ ] 2.5 Search the repository for stale feature imports, navigation labels, experiment preset identifiers, comparison types, and `day5_*` storage access; resolve every executable or user-facing remainder, then create an intermediate removal commit.

## 3. Align repository documentation

- [ ] 3.1 Update README documentation to describe the retained one-shot prompt baseline and remove references that imply the deleted laboratories or profile settings remain available.
- [ ] 3.2 Update `openspec/config.yaml` so the current baseline is the prompt workspace rather than the already-replaced generated counter application, without modifying archived change history.
- [ ] 3.3 Create a documentation/configuration commit that stages only files owned by this change.

## 4. Verify the cleanup

- [ ] 4.1 Run `dart format .` and confirm formatting completes successfully.
- [ ] 4.2 Run `flutter analyze` and resolve every diagnostic introduced or exposed by the deletion.
- [ ] 4.3 Run `flutter test` and confirm all retained tests pass on the cleaned application.
- [ ] 4.4 Inspect `git status` and the complete implementation diff to confirm all six Flutter platform folders and unrelated modified agent-tooling files remain untouched and no generated/cache artifacts are staged.
