## 1. Provider sampling contract

- [x] 1.1 Extend provider-neutral prompt input with optional finite `0.0…2.0` temperature validation while keeping existing constructors source-compatible.
- [x] 1.2 Serialize an explicitly supplied temperature in the DeepSeek Chat Completions body and omit it for all existing callers; never add `top_p` implicitly.
- [x] 1.3 Add unit tests for exact `0.0`, `0.7`, `1.2`, boundary values, non-finite/out-of-range rejection, and request-body omission regressions.

## 2. Day 4 domain and orchestration

- [x] 2.1 Add the hybrid factual/creative starter prompt, required preset values, immutable temperature-lane state, and accuracy/creativity/diversity evaluation models.
- [x] 2.2 Implement deterministic Unicode-aware character count, normalized unique-word ratio, and pairwise word-set Jaccard similarity with empty-text handling.
- [x] 2.3 Implement a controller that validates a non-empty prompt and distinct temperatures, snapshots both, and runs exactly three independent streams sequentially with thinking disabled.
- [x] 2.4 Preserve partial outputs, sanitized failures, applied values, finish reasons, usage, call count, and continuation after synchronous, stream, or terminal failures.
- [x] 2.5 Add cancellation/generation guards, duplicate-run protection, evaluation/note updates, and reset of results/evaluations on a new valid run.
- [x] 2.6 Add domain/controller tests for metrics, preset order, identical prompt snapshots, exact inputs, progressive deltas, failures, cancellation, stale events, locking, and evaluation reset.

## 3. Linux desktop interface

- [x] 3.1 Add a fourth persistent Day 4 destination and compact navigation labels without clearing state in Days 1–4.
- [x] 3.2 Build the editable prompt, three horizontal `0.0…2.0` sliders with `0.1` steps, reset action, three-call disclosure, validation, and run-all progress.
- [x] 3.3 Build three independent streamed result cards showing applied temperature, answer/error state, finish reason, usage, character count, and lexical-diversity evidence without a reasoning disclosure.
- [x] 3.4 Add terminal-only accuracy/creativity/diversity rating controls, local task-fit notes, pairwise similarity, and a summary that never invents scores or a winner.
- [x] 3.5 Add provider-informed guidance that distinguishes official DeepSeek recommendations from exercise inferences and states the single-sample limitation.
- [x] 3.6 Implement a readable three-column wide layout and non-clipping stacked narrow layout.
- [x] 3.7 Add widget tests for navigation retention, sliders/reset/distinct validation, execution locking, streaming/error evidence, ratings/notes, metrics, guidance, and responsive layouts.

## 4. Integration and completion

- [x] 4.1 Add an opt-in Linux live smoke that records non-secret input metadata and requires three successful non-empty outputs at `0.0`, `0.7`, and `1.2` with thinking disabled.
- [x] 4.2 Add a credential-safe Day 4 demonstration checklist covering same-prompt proof, all three values/results, evaluations, lexical evidence, conclusions, and video secrecy.
- [x] 4.3 Run `dart format .`, `flutter analyze`, `flutter test`, the Linux release build, and the opt-in live-provider smoke using only a runtime API key.
- [x] 4.4 Verify implementation against OpenSpec, sync all three delta specs, and archive the change; manual video recording is outside automated implementation.
