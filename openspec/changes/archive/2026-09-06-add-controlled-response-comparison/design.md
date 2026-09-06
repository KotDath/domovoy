## Context

See `proposal.md` for motivation and `specs/response-control-comparison/spec.md` for observable behavior. Day 1 established a provider-neutral `Agent` event stream, a direct DeepSeek Chat Completions adapter, credential resolution, and a single-result Flutter workspace. Day 2 must preserve those paths while adding an auditable Linux desktop laboratory.

DeepSeek Chat Completions supports conditional thinking, `response_format`, `max_tokens`, `stop`, streamed usage, and `finish_reason`. These controls provide different strengths of guarantee: instructions influence model behavior, JSON-object mode guarantees JSON syntax but not an application schema, `max_tokens` caps completion tokens rather than characters, and `stop` only acts when an exact marker is emitted. The UI must make those distinctions visible.

## Goals / Non-Goals

**Goals:**

- Represent thinking and response controls without exposing DeepSeek response objects to presentation code.
- Isolate format, length, and stop behavior into separately runnable baseline/controlled experiments.
- Validate observable output using deterministic application logic and retain the original evidence.
- Make the selected model settings, request controls, measurements, completion metadata, and experiment conclusion visible in a short video.
- Keep live-provider behavior replaceable with injected fakes for deterministic tests.

**Non-Goals:**

- Conversation history, arbitrary multi-message chat editing, tool calls, multiple providers, or statistical model evaluation.
- Guaranteeing semantic truth, pre-counting provider tokens, converting a token ceiling into an exact character limit, or silently repairing every model response.
- Proving that a configured stop sequence caused `finish_reason: stop`; the provider does not distinguish it from natural completion.
- Artificial typewriter animation; streamed text remains progressive at provider chunk cadence.
- Recording or publishing the video automatically, or storing credentials in source code.

## Decisions

### 1. Add a dedicated response laboratory without replacing Day 1

The existing one-shot prompt page remains available. A visible Day 2 entry opens a dedicated response laboratory with a selector for Format, Length, and Stop. Each experiment owns its form values and most recent comparison so switching experiments does not turn results into conversation context.

The laboratory uses one consistent frame: shared prompt and experiment controls above two persistent result cards, followed by evidence and a concise "Вывод" callout. Wide Linux layouts place result cards side by side; narrow layouts stack them.

Replacing the Day 1 page was rejected because the original one-shot behavior remains useful and the challenge should be independently demonstrable. A script-only interface was rejected as the primary deliverable because it weakens the required video, while the same domain logic remains directly testable from Dart.

### 2. Persist reasoning as a model setting and snapshot it per run

Rename the credential dialog conceptually to DeepSeek settings and add a model section with a persisted Reasoning switch. The setting is not secret and is stored behind a small preferences interface; credential storage and priority rules remain unchanged.

At submission, the controller snapshots the setting into provider-neutral immutable agent input so both lanes of a comparison use the same mode even if settings are changed later. Enabled maps to `thinking.type = enabled` and `reasoning_effort = high`. Disabled maps to `thinking.type = disabled` and omits `reasoning_effort`; no synthetic off effort value is sent.

The laboratory displays the current reasoning state and links back to settings. The Length experiment warns, but does not automatically switch modes, when reasoning is enabled with a small token ceiling. Hidden automatic mutation was rejected because it would undermine an auditable comparison.

### 3. Model three independent control types on provider-neutral agent input

Extend `AgentInput` with immutable inference options and at most one experiment control:

- format: a user-visible contract plus an optional provider-neutral JSON-object response mode;
- length: a maximum-character instruction plus maximum completion tokens;
- stop: one exact stop sequence.

An absent control builds the unrestricted baseline. The profile translates supported concepts into Chat Completions JSON and appends only the necessary instruction block to the sole user message. The baseline omits those additions. The Stop experiment is the exception in which the visible base prompt itself contains the marker and post-marker instruction for both lanes; only the controlled request adds the API `stop` field.

One combined control object was rejected because it obscures which mechanism produced an observed effect and creates avoidable conflicts such as placing a textual stop marker after a JSON document.

### 4. Run one sequential baseline/controlled pair per experiment

Each experiment controller has shared form state plus independent baseline and controlled lanes. A run validates inputs, clears that experiment's previous lanes, executes the baseline to a terminal state, and then executes the controlled lane even if the baseline failed. Each lane owns status, reasoning, answer, sanitized failure, completion reason, usage, and reasoning disclosure state.

Sequential execution preserves the existing one-active-request invariant, avoids doubling instantaneous provider load, and is easy to narrate on video. Parallel execution and a six-request "run all" action were rejected for the initial version because they add cost, cancellation complexity, and noisy results without improving the individual conclusions.

A generation identifier prevents stale events from updating a replacement run. Active subscriptions are cancelled on disposal. Each comparison action is labeled as two paid API calls; format repair, if requested, is a third call.

### 5. Validate JSON and Markdown contracts in application code

Format presets provide editable contracts and deterministic validators:

- JSON first parses exactly one object, then checks required keys, primitive/container types, and configured collection counts. The controlled JSON request also sends `response_format: {"type":"json_object"}`, explicitly says JSON in the prompt, and includes an example.
- Markdown checks the configured heading text and order plus required list kind and item count. It does not claim that arbitrary Markdown syntax constitutes contract compliance.

Both baseline and controlled answers are evaluated against the same selected contract after successful completion. Results are `valid` or `invalid` with structured, user-readable diagnostics. Empty or truncated output is invalid. Validation never mutates or hides the provider answer.

JSON Schema transport was rejected because the selected provider contract exposes JSON-object mode rather than a portable strict-schema guarantee. A generic Markdown parser alone was rejected because it cannot enforce the demonstration's document structure.

### 6. Make format repair explicit, bounded, and independent

When the controlled format answer is invalid, show an "Исправить формат" button. It starts at most one repair request containing the original task, the visible contract, the invalid answer, and validator diagnostics in one new user message. It does not include a message history or baseline output.

The repaired answer streams into a separate area and is validated after completion, leaving the original controlled answer and diagnostics visible for comparison. A valid first answer disables the action with an explanation; a failed or still-invalid repair ends the flow.

Automatic hidden repair and unlimited retries were rejected because they conceal the model's first behavior, increase cost unpredictably, and make the educational video harder to follow.

### 7. Treat length instruction, token ceiling, and exact validation as different evidence

The controlled Length message includes the requested maximum-character instruction, and the API body includes `max_tokens`. The baseline omits both. After either lane terminates, the client counts Unicode characters in the returned answer and displays the count next to the configured character target.

The adapter requests streamed usage and normalizes available prompt, completion, and total token counts into terminal metadata. It also normalizes the last non-null `finish_reason` before requiring `[DONE]`. A length finish reason is labeled as hard token truncation, not successful character compliance.

The static conclusion explains that natural-language character limits are behavioral, `max_tokens` is a hard token ceiling that may truncate structure, and exact application requirements need post-response validation and possibly a new request. Client-side truncation was rejected because it can corrupt JSON, Markdown, or meaning while falsely appearing compliant.

### 8. Demonstrate stop with an observable post-marker instruction

The Stop preset asks for a short answer, then an exact marker such as `<END_OF_ANSWER>`, then a distinctive sentence that must appear only if generation continues. Both lanes receive this exact prompt. The controlled lane alone sends `stop: ["<END_OF_ANSWER>"]`.

The UI displays the configured marker, whether the marker and post-marker sentence are present, and the normalized terminal reason. It states that an exact emitted sequence stops generation and is excluded from returned content, while a marker the model never emits has no effect. It does not infer configured-stop causation solely from `finish_reason: stop`.

Merely asking the model to finish with a code word was rejected because natural completion can make baseline and controlled results look identical.

### 9. Normalize completion evidence before presentation

Extend successful completion metadata with a provider-neutral finish reason and optional token usage. The adapter records supported values, tolerates usage-only streamed chunks, continues until `[DONE]`, and maps future finish reasons to unknown. Raw provider payloads do not leave the data layer.

The laboratory derives its evidence from immutable answer text, validator results, local character/marker checks, normalized usage, and normalized finish reason. It does not compute a subjective quality score or assert causality unsupported by the response.

### 10. Keep delivery credential-safe and deterministic

Automated tests use injected agents, clients, settings stores, and validators. Adapter tests prove exact request serialization; domain tests cover validators and repair construction; controller and widget tests cover sequencing and responsive presentation. No test depends on a live model choosing to violate a format.

A repository checklist defines safe presets, Reasoning state, expected evidence, Linux launch/build steps, recording boundaries, and conclusions to narrate. The live key is supplied through the existing application override or `DEEPSEEK_API_KEY`, but its value and settings input remain outside the recording.

## Risks / Trade-offs

- **The model may satisfy a format contract on the first attempt** → Show the real valid result and "repair unnecessary"; demonstrate invalid/repair behavior deterministically in tests without fabricating video evidence.
- **Thinking tokens can consume a small completion budget** → Display the current Reasoning state and a Length warning; use Reasoning off in the recommended demo preset while allowing the user to demonstrate the trade-off.
- **JSON-object mode can still return the wrong schema or be truncated** → Always run the application validator and surface parsing/schema diagnostics.
- **A character target and token ceiling are not equivalent** → Display both inputs and both measurements, and avoid claiming exact conversion.
- **The model may omit or alter the stop marker** → Treat that outcome as evidence that stop only acts on an exact emitted sequence and avoid claiming configured-stop causation from finish reason alone.
- **Up to three paid calls can be made in Format** → Label two calls on comparison and one additional call on explicit repair; prevent duplicate submissions while active.
- **Persisted model settings can change during a run** → Snapshot settings when the comparison starts and apply the same snapshot to both lanes.
- **Video capture could expose credentials or unrelated desktop content** → Capture only the application window, do not open credential fields, avoid terminal output containing secrets, and review the video before delivery.

## Migration Plan

1. Add model-setting storage and provider-neutral thinking/control/completion metadata while retaining constructors that preserve the Day 1 enabled-thinking behavior.
2. Extend the Chat Completions profile and SSE adapter with conditional thinking fields, format/length/stop controls, usage parsing, and normalized finish reasons.
3. Add JSON and Markdown contract models, validators, evidence models, and bounded repair-request construction.
4. Add independent experiment state/controllers and integrate a dedicated laboratory destination with the existing prompt workspace and DeepSeek settings.
5. Add adapter, validator, controller, settings, and responsive widget coverage; run formatting, analysis, and tests.
6. Build and smoke-test the Linux desktop application, then record all three experiments using the credential-safe checklist.

Rollback removes the laboratory destination and optional input controls while keeping the original Day 1 prompt constructor and credential behavior. Stored reasoning preference may remain unused without affecting credentials or one-shot prompting.
