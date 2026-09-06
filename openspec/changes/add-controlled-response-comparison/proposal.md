## Why

Domovoy can stream a one-shot DeepSeek answer, but it does not yet demonstrate how API-level response controls change the result for the same underlying prompt. Day 2 adds a repeatable comparison between an unrestricted request and a request with an explicit output contract, length bound, and stop condition.

## What Changes

- Add a comparison workflow that submits the same base prompt twice: once without output constraints and once with response controls.
- Allow the controlled request to define an explicit format instruction, a maximum completion-token count, and a stop sequence paired with an instruction telling the model when to emit it.
- Map the hard controls directly to the OpenAI-compatible Chat Completions request using `max_tokens` and `stop`, while expressing the requested presentation format as an explicit instruction in the sole user message and retaining direct HTTP/SSE streaming.
- Present baseline and controlled outputs as clearly labeled results so their format, length, and completion behavior can be compared.
- Surface a provider-neutral completion reason derived from `finish_reason` without exposing provider-specific response objects to presentation code.
- Add automated coverage and prepare a Linux desktop demonstration suitable for the required video-plus-code submission without recording or displaying the API key.

## Capabilities

### New Capabilities

- `response-control-comparison`: Configuring output format, completion length, and stop behavior for one controlled request and comparing it with an unrestricted request using the same base prompt.

### Modified Capabilities

None.

## Impact

- Extends the provider-neutral prompt input and terminal metadata used by the existing agent stream.
- Extends the DeepSeek Chat Completions request profile with optional `max_tokens` and `stop` fields supported by the official API.
- Adds comparison orchestration and responsive baseline/controlled result presentation to the prompt workspace.
- Adds unit and widget tests for request construction, control validation, independent streams, finish reasons, and comparison rendering.
- Adds a Linux desktop demo/recording checklist for the Day 2 video and code deliverables; no API key is stored in source code or captured in the video.
