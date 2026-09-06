## Context

See `proposal.md` for motivation and `specs/` for behavior. Domovoy already has a provider-neutral one-shot `AgentInput`, a direct OpenAI-compatible DeepSeek Chat Completions adapter, three persistent `IndexedStack` destinations, and sequential streaming controllers for Days 2–3.

The official DeepSeek Chat Completions reference documents `temperature` as a number from `0` through `2`, defaulting to `1`; lower values are more focused/deterministic and higher values more random. It recommends changing either temperature or `top_p`, not both. The official thinking-mode guide states that temperature has no effect while thinking is enabled. The provider's temperature guide gives examples—coding/math `0.0`, data analysis `1.0`, general conversation/translation `1.3`, creative writing/poetry `1.5`—but does not specifically recommend the exercise values `0.7` or `1.2`.

Sources checked 2026-09-07:

- https://api-docs.deepseek.com/api/create-chat-completion/
- https://api-docs.deepseek.com/guides/thinking_mode/
- https://api-docs.deepseek.com/quick_start/parameter_settings/

## Goals / Non-Goals

**Goals:**

- Make temperature the only sampling variable by forcing thinking off and omitting `top_p` in Day 4.
- Preserve the exact same prompt snapshot across three sequential, independently visible requests.
- Support the required `0.0`, `0.7`, and `1.2` demonstration while allowing safe exploration across DeepSeek's documented range.
- Separate deterministic text measurements from subjective accuracy, creativity, diversity, and task-fit judgments.
- Preserve all earlier screens and provider behavior for callers that omit temperature.

**Non-Goals:**

- Statistically proving temperature behavior from one sample, automatically judging factual accuracy or creativity, or declaring a universal best value.
- Changing `top_p`, enabling reasoning for Day 4, adding conversation history, comparing models/providers, or using an LLM as a judge.
- Adding an SDK, agent framework, Responses API, automatic video recording, or long-term experiment persistence.

## Decisions

### 1. Add optional temperature directly to the provider-neutral input

Extend `AgentInput` with `double? temperature`. Validate finiteness and the inclusive `0.0…2.0` range in the constructor. The DeepSeek profile adds `temperature` to the JSON body only when non-null. Existing Day 1–3 inputs remain source-compatible and continue omitting the field, so provider-default sampling is preserved.

A new `ResponseControl` subtype was rejected because response format/length/stop are mutually exclusive Day 2 contracts, whereas sampling can coexist with any future response control. A settings-level temperature was rejected because Day 4 needs independent per-request values and immutable experiment snapshots.

### 2. Use three adjustable lanes initialized to the required values

The screen owns three horizontal sliders with min `0`, max `2`, divisions `20`, and formatted one-decimal labels. They initialize and reset to `0.0`, `0.7`, and `1.2`. The run action rejects equal values, snapshots all three values and the trimmed prompt, then freezes prompt/sliders/reset until completion.

One slider plus repeated manual execution was rejected because it weakens same-prompt guarantees and makes the three-way video harder to audit. Fixed noninteractive values were rejected because the user explicitly wants temperature regulation. Allowing arbitrary text entry was rejected because sliders prevent out-of-range/non-finite UI values; domain validation still protects non-UI callers.

The built-in prompt should combine factual and creative demands so all three requested dimensions are discussable: explain why the sky appears blue to a ten-year-old, remain scientifically accurate, use one memorable metaphor, and stay under 120 words. The prompt remains editable.

### 3. Run exactly three independent streams sequentially

Introduce an isolated Day 4 controller with immutable configuration/result lane state. The schedule follows the configured lane order and creates three `AgentInput` values containing the same prompt snapshot, the exact lane temperature, `ThinkingMode.disabled`, and no `ResponseControl`. Failures, silent stream endings, and synchronous `Agent.prompt` throws become sanitized lane failures and do not stop later lanes.

The controller stores one active subscription, cancels it at every terminal event, uses a generation id to ignore stale events, rejects duplicate runs, and cancels on disposal. Sequential execution avoids a three-request burst and matches the audit-friendly Day 2/3 pattern.

### 4. Keep result evidence and evaluation explicit

Each card shows its applied temperature, progressive answer, terminal/error state, finish reason, token usage, and Unicode character count. Reasoning deltas are ignored and no empty disclosure is rendered because Day 4 fixes thinking off.

Each terminal lane exposes three independent optional `1…5` ratings—accuracy, creativity, diversity—and an optional local task-fit note. Ratings and notes are never sent to the model and reset on a new comparison. The summary does not calculate a winner: it presents the human-entered values and provider-informed guidance.

Dropdown ratings were chosen over three five-chip rows to limit card height on Linux. A single aggregate score was rejected because it hides the trade-off the assignment asks to discuss.

### 5. Add deterministic lexical evidence without claiming semantic judgment

Normalize answers by lowercasing, extracting Unicode letter/digit word runs, and discarding empty runs. Compute unique-word ratio as `unique words / total words`; compute pairwise Jaccard similarity as `intersection / union` over normalized word sets. Empty text yields unavailable evidence rather than a misleading zero.

These measurements are labeled lexical heuristics. They support visible comparison but do not measure factual accuracy or creative quality. The UI states that one response per value cannot characterize the model's probability distribution; repeat runs can provide additional examples but are not aggregated in this version.

### 6. Distinguish provider documentation from exercise inference

Show the documented range, default, thinking limitation, and `top_p` rule. Present DeepSeek's published use-case examples separately. For the exercise values, phrase `0.7` as a balanced intermediate and `1.2` as a higher-variation setting inferred from the documented direction, not as exact provider recommendations.

This prevents the UI from overstating what the official documentation says and provides a defensible conclusion for the video.

### 7. Extend navigation and responsive presentation

Add a fourth persistent child/destination. Use compact bottom-navigation labels (`Запрос`, `День 2`, `День 3`, `День 4`) to avoid Linux overflow while keeping full screen titles. Preserve state because the `IndexedStack` continues owning all screens.

Use a three-column row/grid at wide widths and a vertical stack on narrow widths, all inside one scrollable page. Keys and injected `Agent` dependencies follow existing widget-test patterns.

### 8. Verify deterministically and with an opt-in real provider

Unit tests cover finite/range validation, exact request-body serialization, omission for existing callers, prompt/value snapshots, order, failure continuation, cancellation, and text metrics. Widget tests cover navigation/state retention, sliders/reset, locking, streaming, ratings/notes, guidance, and wide/narrow layouts.

An opt-in Linux integration test wraps the real DeepSeek agent to record only non-secret `AgentInput` metadata. It asserts three successful non-empty outputs at `0.0`, `0.7`, and `1.2`, disabled thinking, no response controls, and aggregate safe logs. The API key is supplied only at process runtime.

## Risks / Trade-offs

- **Temperature can have limited observable effect in one run** → Preserve real outputs, show lexical evidence and the single-sample limitation, and never fabricate differences.
- **Higher temperature can reduce factual accuracy** → Use a hybrid factual/creative starter prompt and transparent human ratings rather than automatic claims.
- **Editable values can diverge from the assignment presets** → Initialize/reset to the required trio and use those exact values in the live smoke and checklist.
- **An upstream API could accept but ignore a parameter** → Force thinking off, omit `top_p`, inspect request-body tests, and display the applied request values.
- **Three sequential requests increase latency and cost** → Disclose three calls before execution and retain progressive output.
- **Long answers can make a three-column grid unwieldy** → Use scrollable cards, wrapping text, and a stacked narrow layout.
- **Credentials can leak during demonstration** → Use the existing secure settings/runtime environment path and document window-only recording.

## Migration Plan

1. Extend `AgentInput` and the DeepSeek profile with optional validated temperature plus regression tests for omission.
2. Add Day 4 models, metrics, controller, and deterministic tests without changing existing destinations.
3. Add the Day 4 screen, fourth navigation destination, responsive UI, evaluation controls, and widget tests.
4. Add the opt-in live smoke and demo checklist; run formatting, analysis, unit/widget tests, Linux release build, and real-provider smoke.
5. Verify against OpenSpec, sync all three delta specs, and archive the change. Video remains a manual deliverable.

Rollback removes the Day 4 feature/destination and optional temperature field serialization; earlier callers already omit the field and retain their previous behavior.
