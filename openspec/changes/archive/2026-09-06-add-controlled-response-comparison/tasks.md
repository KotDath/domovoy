## 1. Model Settings and Domain Contract

- [x] 1.1 Add a persisted DeepSeek model-settings value and store abstraction with Reasoning enabled by default and independent from API-key storage.
- [x] 1.2 Expand the settings controller and dialog into credential and model sections, including the Reasoning switch, saved-state restoration, loading, and sanitized failure handling.
- [x] 1.3 Extend provider-neutral agent input with immutable thinking mode and optional format, length, or stop control while preserving the Day 1 unrestricted constructor path.
- [x] 1.4 Extend successful terminal events with normalized finish reason and optional prompt, completion, and total token usage.
- [x] 1.5 Update shared fakes and domain/settings tests for defaults, persistence, input validation, backward compatibility, and terminal metadata.

## 2. OpenAI-Compatible Chat Completions Adapter

- [x] 2.1 Serialize enabled thinking as `thinking.type=enabled` plus high `reasoning_effort`, and disabled thinking as `thinking.type=disabled` with no reasoning-effort field.
- [x] 2.2 Serialize each controlled request independently: JSON-object response mode and a delimited format contract, a character instruction plus `max_tokens`, or one exact `stop` sequence, while unrestricted requests omit every control.
- [x] 2.3 Request streamed token usage, tolerate metadata-only chunks, normalize the last supported `finish_reason`, and emit terminal metadata only after `[DONE]`.
- [x] 2.4 Add request-construction tests for both thinking modes, all three controls, same-base-prompt preservation, JSON example requirements, stop-marker handling, and unrestricted field omission.
- [x] 2.5 Add stream tests for reasoning/answer deltas, usage-only chunks, stop/length/unknown reasons, malformed metadata, interrupted streams, partial failures, and credential redaction.

## 3. Format Contracts, Validation, and Repair

- [x] 3.1 Add editable JSON and Markdown contract models with safe demo presets and validation of the contract configuration itself.
- [x] 3.2 Implement JSON result validation for one parsed object, required keys, expected value types, and configured collection counts with structured diagnostics.
- [x] 3.3 Implement Markdown result validation for exact heading presence/order and configured list kind/item count with structured diagnostics.
- [x] 3.4 Implement a provider-neutral one-shot repair input containing the original task, contract, invalid answer, and diagnostics without message history or baseline output.
- [x] 3.5 Add deterministic validator and repair tests covering valid, malformed, empty, truncated, wrong-schema, wrong-order, wrong-count, and repair-input cases.

## 4. Experiment State and Orchestration

- [x] 4.1 Add separate Format, Length, and Stop experiment states with shared form values and independent baseline/controlled lanes for status, reasoning, answer, failure, terminal metadata, and disclosure state.
- [x] 4.2 Implement reusable baseline-then-controlled sequencing with one active subscription, two-call cost state, lane isolation, generation guards, partial-output preservation, and disposal cancellation.
- [x] 4.3 Implement Format execution, validation of both lanes, repair eligibility, one explicit repair stream, repaired validation, and permanent retry exhaustion.
- [x] 4.4 Implement Length execution and evidence for actual Unicode characters, configured character/token limits, available token usage, reasoning-budget warning, and token-limit truncation.
- [x] 4.5 Implement Stop execution using one identical marker-producing prompt for both lanes and evidence for marker/post-marker presence without unsupported causality claims.
- [x] 4.6 Add controller tests for each experiment's validation, sequential requests, same base prompt, resubmission clearing, lane isolation, baseline failure continuation, stale events, repair limits, metrics, and disposal.

## 5. Responsive Response Laboratory

- [x] 5.1 Preserve the Day 1 prompt workspace and add a clearly labeled Day 2 laboratory destination with Format, Length, and Stop selectors.
- [x] 5.2 Show the current Reasoning state in the laboratory, link to DeepSeek settings, and display the non-mutating warning for small token ceilings with reasoning enabled.
- [x] 5.3 Build experiment-specific controls: JSON/Markdown contract editing, character and maximum-token limits, and an exact stop marker with safe demonstration presets and inline validation.
- [x] 5.4 Render persistent "Без ограничений" and "С контролем" cards with independent progressive reasoning, answers, progress, sanitized errors, applied controls, finish reasons, usage, and local measurements.
- [x] 5.5 Render format diagnostics and the bounded "Исправить формат" flow while keeping the original controlled answer and repaired answer visibly distinct.
- [x] 5.6 Add per-experiment "Вывод" callouts that explain instruction versus validation, character target versus token ceiling, and exact stop-marker behavior using the displayed evidence.
- [x] 5.7 Keep result cards side by side on wide Linux windows and stacked on narrow windows with keyboard navigation, accessible names, non-secret request evidence, and disabled duplicate actions.
- [x] 5.8 Add widget tests for navigation, settings, all form errors, selectors, loading states, progressive lanes, evidence, conclusions, repair states, and responsive layouts.

## 6. Day 2 Verification and Delivery

- [x] 6.1 Add a concise Linux demo checklist covering Reasoning off, safe prompts and presets, three experiment runs, objective conclusions, first-pass-valid format behavior, and credential-safe capture.
- [x] 6.2 Run `dart format .`, `flutter analyze`, and `flutter test`, resolving every failure.
- [x] 6.3 Build the Linux release bundle and perform live smoke runs for Format, Length, Stop, and optional repair with the API key supplied only at runtime.
- [ ] 6.4 Record and review the Linux application-window video, confirm that real outputs and conclusions are legible and no credential or unrelated desktop content is visible, and deliver it with the code reference.
