## Context

See `proposal.md` for motivation and `specs/response-control-comparison/spec.md` for observable behavior. Day 1 established a provider-neutral `Agent` event stream, a direct DeepSeek Chat Completions adapter, credential resolution, and a single-result Flutter workspace. Day 2 must reuse those boundaries, keep Chat Completions compatibility, and produce a comparison that is easy to demonstrate on Linux desktop.

The current DeepSeek Chat Completions contract supports streamed `max_tokens`, `stop`, and `finish_reason` fields. A `stop` finish reason can mean either natural completion or a supplied stop sequence, so the client cannot prove which one occurred from `finish_reason` alone. The comparison must therefore display normalized provider evidence without claiming a distinction the API does not expose.

## Goals / Non-Goals

**Goals:**

- Represent optional response controls without adding DeepSeek-specific fields to presentation state.
- Construct two auditable requests from one base prompt, with no control fields leaking into the baseline request.
- Preserve separate reasoning and answer streaming for each comparison result.
- Make the format, length, stop configuration, and terminal reason visible enough for a short Day 2 demonstration.
- Keep tests deterministic through injected agents and HTTP clients.

**Non-Goals:**

- Conversation history, arbitrary message editing, simultaneous model providers, statistical response-quality scoring, or automatic semantic grading.
- Token counting before generation or a guarantee that the model will obey a natural-language format instruction.
- Artificial typewriter animation; text remains progressive at the provider chunk cadence established on Day 1.
- Committing credentials or automating publication of the demonstration video to an external service.

## Decisions

### 1. Add provider-neutral response controls to the agent input

Extend the prompt input with an optional immutable response-control value containing a format instruction, maximum completion-token count, and one stop sequence. An absent value means an unrestricted request. The domain validates normalized non-empty strings and a positive, provider-supported token range before any stream starts.

The DeepSeek profile remains responsible for translating these concepts to request JSON. `max_tokens` and `stop` are emitted only for the controlled request. The format instruction and an instruction to emit the exact stop marker are appended to the base prompt in a clearly delimited response-contract block inside the existing sole user message. This preserves the one-message Chat Completions shape and keeps the base prompt identifiable in both requests.

A system message was rejected because it would change the Day 1 sole-user-message contract and make it less obvious in the demo that the same user prompt is being compared. JSON mode was rejected for this slice because a trailing textual stop marker conflicts with the requirement that the entire generated payload remain a valid JSON object; free-form explicit format instructions demonstrate the requested control without that ambiguity.

### 2. Normalize terminal metadata before it reaches the UI

Extend successful completion with a provider-neutral reason such as `stop`, `length`, `contentFilter`, `toolCalls`, `insufficientResources`, or `unknown`. The Chat Completions adapter records the last non-null `choices[0].finish_reason`, continues consuming until `[DONE]`, and then emits one completed event carrying the normalized reason. Unknown future strings map to `unknown`; raw provider data never leaves the adapter.

The UI labels `length` explicitly as a token-limit termination and renders `stop` as normal/provider stop. It also shows the configured stop marker next to the controlled result, but does not assert that the marker caused termination because DeepSeek reports both natural and configured stops as `stop`.

Treating `finish_reason` as completion immediately was rejected because Day 1 intentionally requires `[DONE]` before success. Keeping the terminal marker rule avoids silently accepting truncated SSE streams.

### 3. Orchestrate two sequential lanes in one comparison controller

Replace the single-result controller state with a comparison state containing shared form values and two independent result lanes. Each lane owns status, reasoning, answer, failure, completion reason, and reasoning expansion. Submission validates the entire form once, clears both lanes, runs the unrestricted stream to a terminal event, and then runs the controlled stream even if the first lane failed. A new comparison is disabled until both lanes terminate.

Sequential execution preserves the existing one-active-request invariant, makes the baseline-then-controlled sequence clear on video, and avoids doubling instantaneous provider load. Parallel execution was rejected because it complicates cancellation and makes side-by-side streaming harder to narrate without improving the challenge result.

The controller uses a generation identifier and cancels the current subscription on disposal or replacement, as Day 1 does. Result-lane updates are immutable so existing test patterns remain usable.

### 4. Make controls and comparison evidence explicit in the workspace

The input area keeps one base-prompt field and adds a compact controlled-request section with defaults suitable for demonstration: a concrete format-description example, a conservative token limit, and a distinctive stop marker. The user can edit all three. Validation errors appear on their respective fields before either request begins.

The output area contains persistent cards labeled “Без ограничений” and “С ограничениями”. Each reuses the reasoning disclosure and progressive answer treatment, has its own progress/error state, and ends with a completion-reason label. The controlled card also summarizes the exact non-secret controls applied. Wide layouts place the result cards side by side; narrow layouts stack them.

Computing an automatic quality score or textual diff was rejected because the challenge asks for human comparison and model outputs are nondeterministic. Clear labels and request evidence are sufficient and less misleading.

### 5. Treat the video as a verified delivery artifact, not application state

Add a short repository demo script/checklist describing a safe prompt, visible control values, expected baseline/controlled differences, Linux release launch, and recording steps. The API key is provided only through `DEEPSEEK_API_KEY`; settings and terminals containing the value stay outside the capture region. The resulting video is delivered as a separate artifact unless the user explicitly chooses to track the binary in Git.

Automated tests cover all deterministic behavior. A final Linux smoke run verifies the live provider and supplies the video evidence, but assertions do not depend on exact model prose.

## Risks / Trade-offs

- **Thinking tokens consume the completion budget and a very small `max_tokens` value may leave no final answer** → Use a conservative default, explain that the bound covers generated completion tokens, and test the `length` terminal state independently with a fake stream.
- **The model may naturally stop before emitting the requested marker** → Display the configured marker and normalized `stop` reason without claiming causation; use a distinctive marker and explicit emission instruction in the demo preset.
- **Model nondeterminism can obscure the comparison** → Use one descriptive prompt likely to produce a long baseline and a tightly specified controlled format; compare observable structure and bounds rather than semantic quality.
- **Two paid calls are made for every comparison** → Label the action clearly, run sequentially, prevent duplicate submissions while active, and document that each comparison consumes two API requests.
- **Appending control instructions changes the full controlled message** → Preserve the base prompt verbatim as a distinct first block and expose the appended response contract in the UI so the comparison remains auditable.
- **Video capture could expose credentials or unrelated desktop content** → Launch with an environment key, never open key settings during recording, capture only the application window, and review the video before delivery.

## Migration Plan

1. Extend domain request/completion types with optional controls and normalized finish reasons while keeping an unrestricted constructor path.
2. Update the DeepSeek provider profile and stream adapter to serialize controls conditionally and capture `finish_reason` before `[DONE]`.
3. Add the two-lane comparison controller and replace the single-result workspace with the shared form and responsive result cards.
4. Update existing tests for the extended completion event, then add request, validation, sequencing, partial-failure, responsive-layout, and control-evidence coverage.
5. Run formatting, analysis, tests, and the Linux release build; perform a live two-request smoke comparison with a runtime-only API key.
6. Record and review the Linux demonstration video using the safe checklist. Rollback restores the Day 1 single-result controller and ignores the optional control fields without changing stored credentials.
