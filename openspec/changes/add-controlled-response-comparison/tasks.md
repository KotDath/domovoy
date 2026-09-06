## 1. Domain Contract

- [ ] 1.1 Add an optional provider-neutral response-control value with normalized format instruction, maximum completion tokens, and one stop sequence while preserving the unrestricted `AgentInput` path.
- [ ] 1.2 Add a provider-neutral completion-reason enum to successful terminal events, including stop, length, content-filter, tool-call, insufficient-resource, and unknown cases.
- [ ] 1.3 Update shared fakes and domain tests for control validation, unrestricted compatibility, normalized values, and completion reasons.

## 2. Chat Completions Controls

- [ ] 2.1 Extend the provider profile to build an unrestricted request with no control fields and a controlled request with a delimited response-contract block in the sole user message plus `max_tokens` and `stop` fields.
- [ ] 2.2 Track the last streamed `finish_reason`, normalize supported values, and emit it only with successful completion after `[DONE]` while preserving existing interrupted-stream behavior.
- [ ] 2.3 Add adapter tests proving that both requests preserve the same base prompt, the baseline omits controls, the controlled request serializes all controls, and prior results/history are absent.
- [ ] 2.4 Add adapter tests for stop, length, unknown and metadata-only terminal chunks, malformed finish reasons, partial failures, and credential redaction.

## 3. Comparison State and Sequencing

- [ ] 3.1 Introduce immutable comparison state with shared validation state and independent baseline/controlled lane status, reasoning, answer, failure, completion reason, and disclosure expansion.
- [ ] 3.2 Implement form validation that rejects blank prompts, blank format descriptions, invalid provider token limits, and blank stop sequences before starting either request.
- [ ] 3.3 Implement baseline-then-controlled execution using one active subscription, continuing to the controlled lane after a baseline terminal failure and preventing concurrent comparisons.
- [ ] 3.4 Preserve partial lane output, clear both lanes on a new comparison, ignore stale generations, and safely cancel the active stream on disposal.
- [ ] 3.5 Add controller tests for sequencing, identical base prompts, validation, lane isolation, resubmission, partial failure, finish reasons, and disposal.

## 4. Responsive Comparison Workspace

- [ ] 4.1 Replace the single-submit form with one base-prompt field and editable controlled-request fields for format description, maximum tokens, and stop sequence, including safe demonstration defaults and a two-request cost notice.
- [ ] 4.2 Present persistent “Без ограничений” and “С ограничениями” result cards that stream reasoning and answers independently and summarize the non-secret controls applied to the controlled lane.
- [ ] 4.3 Display per-lane progress, sanitized errors, and human-readable completion reasons without claiming whether provider `stop` was natural or caused by the configured sequence.
- [ ] 4.4 Keep result cards side by side on wide Linux windows and stacked on narrow windows, with accessible labels and independently toggleable reasoning disclosures.
- [ ] 4.5 Update widget tests for all form validation, loading/disabled states, responsive layouts, progressive two-lane rendering, control evidence, errors, and completion labels.

## 5. Day 2 Verification and Delivery

- [ ] 5.1 Add a concise Linux demo checklist with a shared prompt, visible format/length/stop controls, expected comparison evidence, and credential-safe recording steps.
- [ ] 5.2 Run `dart format .`, `flutter analyze`, and `flutter test`, resolving every failure.
- [ ] 5.3 Build the Linux release bundle and run a live baseline/controlled smoke comparison with the API key supplied only through `DEEPSEEK_API_KEY`.
- [ ] 5.4 Record and review the Linux application-window video, confirming it shows both requests and their differences while revealing no credential or unrelated desktop content, and deliver it alongside the code reference.
