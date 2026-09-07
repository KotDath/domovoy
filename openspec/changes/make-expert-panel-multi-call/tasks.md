## 1. Expert ensemble domain and prompts

- [x] 1.1 Expand Day 3 stages/state to retain analyst, engineer, critic, and synthesis lanes while exposing synthesis as the Expert-group comparable result.
- [x] 1.2 Replace the role-play prompt with three role-specific independent request builders and one synthesis builder that safely labels complete, partial, failed, or unavailable evidence.
- [x] 1.3 Update planned strategy and experiment call accounting from 1/5 to 4/8 and cover prompt isolation, thinking-off inputs, and labels with unit tests.

## 2. Sequential orchestration

- [x] 2.1 Schedule the three expert streams and synthesis after the existing strategies, ensuring each expert receives only the immutable task and its own role instruction.
- [x] 2.2 Preserve each expert's partial output and sanitized failure, continue remaining expert attempts after failures, and always attempt synthesis unless the run is cancelled or superseded.
- [x] 2.3 Extend controller tests for the eight-call success path, intermediate expert failures, synthesis failure, end-of-stream interruption, cancellation, disposal, and stale-generation protection.

## 3. Day 3 presentation

- [x] 3.1 Update the Expert-group card to explain its four-call decomposition and display three separately labeled streamed expert evidence sections followed by the primary synthesis answer.
- [x] 3.2 Update full-run action, progress, native-reasoning explanation, accessibility semantics, and responsive narrow/wide layouts for eight total calls.
- [x] 3.3 Extend widget tests to verify the expert evidence lifecycle, failure visibility, synthesis result, eight-call completion, and overflow-safe Linux layouts.

## 4. Documentation and verification

- [x] 4.1 Update Day 3 README/demo guidance and opt-in live-smoke assertions to describe and exercise eight stages without exposing credentials.
- [x] 4.2 Run `dart format .`, `flutter analyze`, and `flutter test`, then validate the OpenSpec change and review the final diff for unrelated modifications.
