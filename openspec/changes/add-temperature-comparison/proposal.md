## Why

Day 4 needs an observable, repeatable comparison of how sampling temperature changes the same DeepSeek request. A dedicated temperature laboratory makes the three request values, streamed outputs, human evaluation, and practical conclusions visible without mixing the experiment with conversation history or native reasoning.

## What Changes

- Add a Day 4 screen that snapshots one editable prompt and sequentially runs it at temperatures `0.0`, `0.7`, and `1.2`, with all three values and the three-call cost visible before execution.
- Provide horizontal temperature controls initialized to the required presets, constrained to DeepSeek's documented `0.0…2.0` range in `0.1` steps, plus an action that restores the required Day 4 values.
- Explicitly disable native thinking and omit `top_p` for every Day 4 request because DeepSeek documents that temperature has no effect in thinking mode and recommends changing temperature or `top_p`, not both.
- Stream and retain each result independently with sanitized errors, completion metadata, and the exact applied temperature.
- Let the user rate accuracy, creativity, and diversity for every result, add a practical-use note, and view a comparison summary without an LLM-as-judge.
- Add provider-body, domain, controller, widget, and opt-in live-provider integration tests plus a credential-safe Linux demonstration checklist; video recording remains manual.

## Capabilities

### New Capabilities

- `temperature-comparison`: Configurable three-lane Day 4 temperature execution, streamed evidence, transparent human evaluation, and practical conclusions.

### Modified Capabilities

- `llm-prompt-streaming`: Extend provider-independent prompt input and the DeepSeek Chat Completions request with an optional validated sampling temperature while preserving existing request defaults.
- `prompt-workspace`: Extend persistent day navigation with a distinct Day 4 temperature destination while preserving Day 1–3 state.

## Impact

- Extends the existing `AgentInput` and OpenAI-compatible Chat Completions body with an optional temperature value; existing callers continue to omit it unless they opt in.
- Adds isolated Day 4 domain/controller/UI code, a fourth persistent application destination, manual comparison state, and deterministic similarity indicators.
- Adds tests covering `0.0`, `0.7`, `1.2`, the full documented range, request-body omission for existing flows, sequential failure handling, responsive Linux layout, and a real three-call DeepSeek smoke.
- Uses three paid API calls for each default comparison and does not add an SDK, agent framework, conversation history, or Responses API dependency.
