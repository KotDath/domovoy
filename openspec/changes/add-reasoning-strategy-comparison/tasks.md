## 1. Day 3 domain and reference puzzle

- [ ] 1.1 Add provider-neutral strategy, stage, lane-result, verdict, and experiment-state models for Direct, Step by step, Generated prompt, and Expert group.
- [ ] 1.2 Add the editable Russian four-house preset with explicit one-to-one and left-to-right rules plus the six clues from the design.
- [ ] 1.3 Implement a pure-Dart exhaustive reference solver and prove that the preset has exactly the documented unique four-house grid.
- [ ] 1.4 Add unit tests for every prompt transformation, disabled-thinking inputs, every reference clue, category uniqueness, and the exact single solution.

## 2. Sequential strategy orchestration

- [ ] 2.1 Implement the Day 3 controller that snapshots one non-empty task and executes the five planned API stages sequentially through the existing `Agent` stream.
- [ ] 2.2 Preserve independent progressive output, prompt-builder evidence, terminal metadata, actual call count, sanitized errors, and continuation after non-dependent failures.
- [ ] 2.3 Add generation guards and subscription cancellation so duplicate runs, disposal, empty generated prompts, and stale stream events are handled deterministically.
- [ ] 2.4 Add controller tests for stage order, identical snapshots, five-call accounting, generated-stage branching, partial failures, cancellation, and verdict reset.

## 3. Linux desktop user interface

- [ ] 3.1 Add a persistent Day 3 navigation destination without clearing Day 1, Day 2, or Day 3 state when switching screens.
- [ ] 3.2 Build the editable task panel, reasoning-off explanation, five-call disclosure, run-all progress, and four independent streamed strategy cards.
- [ ] 3.3 Display the generated prompt separately, show the unique reference grid only for the unchanged preset, and provide per-card verdicts plus a user-selected most-accurate summary.
- [ ] 3.4 Make the laboratory readable in two columns on wide Linux windows and as a non-clipping stack on narrow windows.
- [ ] 3.5 Add widget tests for navigation/state retention, disabled execution, progressive rendering, generated-prompt disclosure, reference applicability, ratings, summary, and responsive layouts.

## 4. Integration and verification

- [ ] 4.1 Add an opt-in credential-safe Day 3 live integration smoke that exercises all five stages and reports only aggregate non-secret evidence.
- [ ] 4.2 Add a Day 3 Linux demonstration checklist covering the four prompts/results, generated prompt, unique reference, ratings, conclusion, and credential-safe recording.
- [ ] 4.3 Run `dart format .`, `flutter analyze`, `flutter test`, the Linux release build, and the opt-in live-provider smoke with a runtime-only API key.
- [ ] 4.4 Verify the completed implementation against this OpenSpec change, sync its delta specs, and archive it; manual video recording is explicitly outside automated implementation.
