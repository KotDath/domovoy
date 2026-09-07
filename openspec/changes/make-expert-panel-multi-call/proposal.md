## Why

The Day 3 “Expert group” currently asks one model invocation to role-play three experts and synthesize their answers. That presentation overstates the independence of the evidence and understates the real API-call cost of a genuine expert ensemble.

## What Changes

- Replace the single expert-group prompt with three independent streamed requests for an analyst, engineer, and critic.
- Add a fourth synthesis request that receives the immutable task plus the three expert outputs and produces the strategy's final answer.
- Preserve each expert's output and failure evidence in the Day 3 UI, and make synthesis behavior explicit when one or more expert requests fail.
- Update per-strategy and total call accounting from one expert-group call and five total calls to four expert-group calls and eight total calls.
- Update automated tests, live-smoke expectations, and Day 3 documentation to describe the real multi-call ensemble.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `reasoning-strategy-comparison`: Make Expert group a real three-expert-plus-synthesizer request chain and expose its evidence, failure behavior, and eight-call experiment cost.

## Impact

- Affects Day 3 prompt builders, domain state, sequential orchestration, strategy cards, progress/cost labels, tests, and demonstration documentation.
- Reuses the existing provider-neutral streaming `Agent` abstraction and OpenAI-compatible Chat Completions transport; no agent framework or new dependency is introduced.
- A full Day 3 comparison makes three additional paid provider calls.
