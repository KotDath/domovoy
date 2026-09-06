## Why

Domovoy can stream a one-shot DeepSeek answer, but Day 2 needs a visible and repeatable way to demonstrate how explicit format, length, and stop controls change the same request. A response laboratory turns those API concepts into independently testable experiments and distinguishes model instructions from guarantees enforced by the application or provider.

## What Changes

- Add a dedicated response laboratory reachable from the existing prompt workspace, with separate Format, Length, and Stop experiments rather than one combined comparison.
- Run each experiment as a sequential pair using the same base prompt: an unrestricted baseline followed by a controlled request, with independent streamed results and objective evidence.
- Extend DeepSeek model settings with a persisted Reasoning switch. Enabled requests use thinking mode with high effort; disabled requests set thinking off and omit reasoning effort.
- Let the Format experiment use editable JSON or Markdown contracts, validate the returned structure, and offer one user-triggered repair request when validation fails.
- Use JSON response mode for the controlled JSON preset while retaining application validation of required fields and types; Markdown uses an explicit structural contract and application validation.
- Let the Length experiment combine a visible natural-language character instruction with an API max-token ceiling, then report actual character count, available token usage, and completion reason.
- Let the Stop experiment submit the same marker-producing prompt with and without an API stop sequence so post-marker output can be compared directly.
- Add deterministic automated coverage and a credential-safe Linux desktop demonstration checklist for the required video-plus-code submission.

## Capabilities

### New Capabilities

- `response-control-comparison`: A UI response laboratory for comparing unrestricted and controlled format, length, and stop behavior, including reasoning configuration, validation evidence, and one-shot format repair.

### Modified Capabilities

None.

## Impact

- Extends provider-neutral agent input and terminal metadata with thinking configuration, optional response controls, completion reason, and optional token usage.
- Extends the OpenAI-compatible DeepSeek Chat Completions request profile with conditional thinking fields, `response_format`, `max_tokens`, `stop`, and streamed usage reporting.
- Expands application settings from credential-only configuration to DeepSeek model configuration without exposing the stored API key.
- Adds experiment orchestration, structural validators, one-shot repair handling, and a responsive laboratory UI while preserving the Day 1 one-shot prompt workspace.
- Adds unit and widget tests plus Linux demo documentation; no API key or recorded video is committed by default.
