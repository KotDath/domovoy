## 1. Provider-neutral LLM core, registry, and credentials

- [x] 1.1 Create the Dart-only `lib/core/llm` public boundary with validated provider/model/wire-family/call identifiers and deep-frozen JSON helpers; add round-trip and malformed-value unit tests.
- [x] 1.2 Implement immutable model metadata/capabilities, generation config, ordered messages and text/reasoning/tool-call/tool-result content parts with role/correlation validation and versioned JSON serialization; test mixed histories, invalid role/part combinations, equality, and defensive copying.
- [x] 1.3 Implement tool descriptors, request/context snapshots, optional non-negative usage counters, normalized finish/error values, and the provider event grammar with terminal-state helpers; test partial usage, unknown finish reasons, secret-free serialization, and invalid numeric fields.
- [x] 1.4 Implement provider/profile/model registry and idempotent cooperative-cancellation contracts using only `dart:*`; enforce exact provider/model ownership and wire-family compatibility and add fake-provider tests for resolution, event order, one terminal, cancellation, and unexpected stream closure.
- [x] 1.5 Implement the exact curated catalog for DeepSeek (`deepseek-v4-flash`, `deepseek-v4-pro`), Moonshot AI (`kimi-k2.6`, `kimi-k2.7-code`, `kimi-k3`), and OpenAI (`gpt-4o-mini`, `gpt-5-mini`, `gpt-5.4`); test enumeration, capability/context/output validation, exact eight-entry scope, and local rejection of undeclared pairs.
- [x] 1.6 Generalize credentials to provider-scoped resolver/store contracts and secure namespaced storage with stored-override-before-profile-environment precedence; preserve read-through/migration of `deepseek_api_key_override` and test cross-provider isolation, missing keys, sanitization, and unchanged DeepSeek settings behavior.

## 2. OpenAI-compatible Chat Completions family

- [x] 2.1 Move/reshape existing HTTP/SSE behavior under `lib/infrastructure/llm/openai_compatible` as the Chat Completions wire adapter, retaining one shared `http.Client`, cancellation, arbitrary SSE chunk handling, and no vendor SDK dependency.
- [x] 2.2 Add typed DeepSeek, Moonshot AI global, and caller-defined compatible profiles with validated endpoint/credential/dialect/model metadata; reject insecure custom endpoints outside explicit development/test policy and reject implicit models or arbitrary secret headers.
- [x] 2.3 Translate ordered context, assistant tool calls, tool results, schemas, reasoning modes, optional temperature/output cap, streaming usage, and selected models into profile-correct requests; normalize fragmented/interleaved reasoning/text/tool-call/usage/finish/error chunks and reject unsupported capabilities before dispatch.
- [x] 2.4 Add fixture/transport tests for both curated DeepSeek models, all three curated Moonshot Kimi models, custom compatible registration, preserved DeepSeek one-shot behavior, multi-turn tools, reasoning differences, malformed/no-terminal streams, HTTP/network/missing-key sanitization, and cancellation without live network calls.

## 3. OpenAI Responses family

- [x] 3.1 Implement the raw-HTTP/SSE OpenAI Responses adapter/profile under `lib/infrastructure/llm/openai_responses` using the shared core contract, provider-scoped `OPENAI_API_KEY`, common cancellation/sanitization utilities, and no OpenAI SDK.
- [x] 3.2 Translate instructions, ordered input items, text/reasoning history, function tools/calls/outputs, supported generation controls, and output-token bounds into Responses requests for the three curated OpenAI models; reject unsupported model capabilities locally.
- [x] 3.3 Normalize interleaved output text, reasoning, incremental function-call arguments, usage, completion, refusal/error, malformed events, and missing terminal state into the common event grammar with one terminal and late-event suppression.
- [x] 3.4 Add deterministic fixtures and contract tests for `gpt-4o-mini`, `gpt-5-mini`, and `gpt-5.4`, including text, reasoning, tool continuation, partial usage, refusal/error, arbitrary SSE fragmentation, missing credentials, cancellation, and secret-free failures without live requests.

## 4. Agent facade and persistent-ready session lifecycle

- [x] 4.1 Create the Dart-only `lib/core/agents` boundary with serializable `AgentDefinition`, nullable run/token policies, stable `AgentSessionId`, immutable transcript/snapshot values, and eager provider/model/tool/policy resolution; test round trips, unlimited defaults, invalid finite values, and missing resources.
- [x] 4.2 Implement `runtime.agent(definition)`, one-call `agent.run(...)`, typed-input convenience, caller-owned `agent.createSession()`, and `agent.restoreSession(id)`; prove ephemeral run-owned cleanup, distinct one-call identities, reusable sequential session history, and one active run per session.
- [x] 4.3 Implement explicit idle/running/closing/closed lifecycle, idempotent run/session cancellation and close, run failure retry semantics where safe, close-without-delete behavior, and suppression of late events/futures after one guarded terminal.
- [x] 4.4 Implement versioned/revisioned `AgentSessionRecord`, committed `AgentTranscript`, strict `AgentSessionCodec`, optimistic `AgentSessionRepository` port, and in-memory repository; exclude credentials, callbacks, mailboxes, active runs/tools/streams, and partial fragments from serialization.
- [x] 4.5 Integrate repository-backed create/restore/delete and checkpoints after accepted input/inbound content, complete assistant messages, complete tool results, and terminal counters; stop safely on persistence failures and reject malformed/unknown-version/conflicting/unavailable-resource restores without claiming exact-once tool recovery.
- [x] 4.6 Add codec/repository/session contract tests for record round trips, defensive copying, revision conflicts, process-local restore, live-ID collision, checkpoint order/failure, close then restore, explicit delete, partial-output exclusion, no active-operation replay, and independent sessions from one definition.
- [x] 4.7 Extend the shared cancellation API with race-safe detachable registrations, require an operation-scoped cancellation token on optimistic repository `save`, update the in-memory adapter/callers/fakes, and add contract tests for cancellation-before-commit, commit-winning-the-race, no mutation after cancelled/failure completion, idempotent disposal, and no listener accumulation.
- [x] 4.8 Replace scheduler/microtask checkpoint abandonment with serialized immutable saves and a runtime-only positive persistence-shutdown policy (five-second default): normal saves await actual settlement, while run cancellation/idle/duration/session close share one absolute deadline, cancel the active operation, and attempt at most one final frozen-snapshot flush when its revision outcome is known.
- [x] 4.9 Add deterministic fake-clock/repository tests for delayed successful file/SQLite/Drift-like saves under varied scheduler interleavings, cancellation during save, close during save, successful and typed-cancelled settlement before the deadline, deadline-winning never-settling/non-cooperative saves, exactly one terminal, reliable return-to-idle, close-future error semantics, unreliable-session closure, same-runtime restore quarantine, late success/error suppression, and bounded cancellation-registration counts across many productive checkpoints.

## 5. Guarded autonomous loop, quotas, and liveness

- [x] 5.1 Implement the deterministic model-turn state machine for user input, provider event projection, complete assistant commits, sequential tool-continuation turns, provider/context/output bounds, one active run, and exactly one completed/stopped/failed/cancelled terminal.
- [x] 5.2 Implement tri-state run overrides and precedence `run > AgentDefinition > runtime profile` for nullable model-turn/tool-call/total-duration and cumulative token quotas; keep global productive quotas unlimited, accept zero tools, and test explicit finite, inherited, and explicit-unlimited outcomes.
- [x] 5.3 Implement reported-usage aggregation and configured pre/post checks for per-turn output and cumulative input/output/total tokens, including one-turn overshoot, `budgetUnverifiable`, partial-output retention, and no work after an observed quota.
- [x] 5.4 Implement the default ten-minute monotonic idle watchdog, override/disable semantics, resets for provider/usage/inbound/approval/tool/checkpoint progress, cancellation propagation, and distinction from optional total duration; test with a fake clock and no real waits.
- [x] 5.5 Implement canonical identical no-progress cycle fingerprints, one warning at five consecutive cycles, stop at ten before an eleventh continuation, and reset on changed arguments/results, new answer/inbound content, or explicit progress; add false-positive regression tests for legitimate changing polling.
- [x] 5.6 Add deterministic fake-provider tests for final answer, unlimited varied continuation, finite stops, idle expiry/progress, no-progress warning/stop/reset, cancellation races, provider violations, checkpoint interaction, and resource cleanup.

## 6. Tools, validation, policies, hooks, and progress

- [x] 6.1 Implement and document the supported JSON-Schema subset (`object`, primitive types, nested `properties`/`required`, arrays/items, enum, and `additionalProperties`), reject unsupported/non-object schemas at registration, and recursively validate deep-frozen argument objects.
- [x] 6.2 Implement runtime-only tool registry/executors, optional attempted-call accounting, ordered argument assembly, schema validation, `allow | deny | ask` policy resolution, deny-safe missing approval, sequential execution, correlated success/error results, and cancellation propagation.
- [x] 6.3 Add runtime-only tool liveness/progress reporting that resets idle state and emits sanitized progress events without transcript persistence; implement ordered model/tool hooks with immutable identifier/snapshot contexts and typed sanitized failure if hook infrastructure throws.
- [x] 6.4 Add unit tests for supported/unsupported schemas, unknown/disabled/malformed calls, all permission outcomes, missing/explicit approval, executor success/failure/throw/cancellation/heartbeat, secret and stack sanitization, sequential ordering, hook ordering/failure, attempted-call accounting, and duplicate-execution prevention.

## 7. In-memory session messaging seam

- [x] 7.1 Implement serializable envelopes/receipts addressed by `AgentSessionId` and a runtime-only bounded router with duplicate-live-registration protection, immutable enqueue, `queued | rejected` MVP outcomes, reserved non-emitted `steered`, preference downgrade, and unknown/closed/full rejection.
- [x] 7.2 Integrate atomic FIFO mailbox drains and repository transcript checkpoints before the first and each continuation turn, constrain payloads to user-role messages, emit source/correlation/reply-to consumption events, and leave post-final-drain messages queued for the next run.
- [x] 7.3 Add integration-style tests with two sessions and fake providers for addressed/correlated send, FIFO/at-most-once consumption, busy safe-boundary delivery, final-turn carryover, full/closed/unknown rejection, steering downgrade, restored session identity with an empty mailbox, independent histories, and non-durable queue semantics.

## 8. Prompt workspace migration

- [x] 8.1 Update manual composition to build both production wire adapters, the exact three built-in profiles/eight-model catalog, provider-scoped credentials, empty production tool registry, deny-safe policy, in-memory session repository/router/runtime, and reusable prompt agent definition, with deterministic disposal.
- [x] 8.2 Replace the prompt feature's legacy dependency with `agent.run(...)`, snapshot reasoning into generation config, apply its feature-only one-turn/zero-tool policy, map reasoning/text/completion/stop/failure/cancellation events into existing state, and cancel on disposal while retaining the late-generation guard.
- [x] 8.3 Remove superseded provider-as-agent types only after callers migrate; update fakes, controller/widget/credential/settings tests to prove one active submission, no history, progressive output, retry after terminal, partial-output retention, legacy DeepSeek key continuity, and safe disposal.
- [x] 8.4 Add application-boundary tests proving prompt presentation imports only agent-runtime events, one-call sessions close automatically, production definitions/records serialize no secrets or runtime objects, and registered Moonshot/OpenAI profiles do not change the default DeepSeek prompt selection.

## 9. Verification and handoff

- [x] 9.1 Run `dart format .` and confirm no unintended generated/cache files, copied Pi catalogs, vendor SDKs, or unrelated platform/tooling files enter the diff.
- [x] 9.2 Run `flutter analyze` and `flutter test`; report exact commands, pass/fail counts where available, and skipped platform/live checks without claiming them verified.
- [x] 9.3 Run `openspec validate add-agent-runtime-foundation --strict` and `openspec validate --all --strict`, inspect the complete implementation diff, confirm the exact adapters/profiles/catalog and unlimited defaults/watchdog thresholds, and verify Android/iOS/macOS identifiers remain under `ru.kotdath.domovoy` with all six Flutter platform trees supported.
- [x] 9.4 Return a completion report listing checked task numbers, changed files, facade/session/record/repository, two-provider-family, credential, runtime/tool/messaging behavior, tests/results, deviations, blockers, and open questions; identify Anthropic Messages plus Kimi For Coding as unimplemented follow-up and do not archive the change.

## 10. Final-review architecture corrections

- [x] 10.1 Replace binary reasoning capability flags with `unsupported | optional | required`; add serialized provider-neutral `ReasoningEffort.modelDefault | low | medium | high | max`, per-model selectable effort metadata, and an optional run-level mode/effort pair that atomically overrides the definition for one frozen run; preserve existing `ReasoningMode`, decode missing effort as model-default, and leave productive-limit defaults unchanged.
- [x] 10.2 Add the origin-bound/versioned `LlmProviderTurnState` plus message-indexed continuation entries to provider completion/context/session records, strictly validate/deep-freeze/round-trip them with normalized assistant turns, exclude them from definitions, agent events/snapshots/hooks/mailboxes/errors/diagnostics, and test confidential payload non-disclosure and restore correlation.
- [x] 10.3 Rework OpenAI Responses fixtures/parser/encoder for stateless continuation: always `store: false`, request encrypted reasoning, collect supported complete `output_item.done` items in order, preserve ids/status/summary/content/phase/call fields/encrypted content, replay a matching bundle exactly once before function outputs, never synthesize reasoning, fail before tool execution when tool continuation lacks encrypted state, and allow only the specified text-only fallback. Use deterministic fixtures only, not live API tests.
- [x] 10.4 Add idempotent `Future<void> AgentRuntime.close()` with opening/live-session ownership, closing rejection, concurrent child cleanup and one shared persistence deadline; replace direct client disposal with idempotent async stack/dependency close ordered runtime/sessions -> owned repository/router resources -> shared HTTP client, keep Flutter/controller dispose non-mutating and error-handled, and add fake-resource ordering/race/error tests proving the client remains usable until runtime cleanup finishes.
- [x] 10.5 Implement data-driven reasoning effort validation/wire mappings and deterministic request/serialization tests for every curated model: DeepSeek low→low, medium→high, high→high, max→max, default→high; K2.6/K2.7 no explicit levels; K3 low/high/max/default→high; GPT-4o Mini disabled only; GPT-5 Mini low/medium/high/default→high; and GPT-5.4 low/medium/high, max→xhigh, default→high, disabled→none. Reject all undeclared levels before credentials/network, preserve the existing DeepSeek boolean UI/storage as mode plus model-default effort, and do not add a level selector in this change.

## Completion and verification (2026-09-10)

- OpenSpec reports `49/49` implementation tasks complete and state `all_done`.
- The final clean implementation review reported verdict `APPROVED`, with no
  mandatory findings remaining.
- Fresh verification: `flutter analyze` completed with `No issues found!` and
  `flutter test` completed with `245` tests passed.
- Fresh OpenSpec verification: `openspec validate add-agent-runtime-foundation --strict`
  passed, and `openspec validate --all --strict` passed all `4` items with `0`
  failures.
- Completeness, correctness, and coherence have no critical or warning issues
  against the approved proposal, delta specs, design, and checked tasks. The
  model-specific reasoning enhancement recorded in the proposal is future work,
  not a missing requirement of this change.
- No live-provider checks or platform builds were run in this completion pass;
  none are claimed. The change is verified and ready for archive, but remains
  unarchived until the user explicitly requests archiving.
