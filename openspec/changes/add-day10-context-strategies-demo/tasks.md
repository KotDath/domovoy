## 1. Strategy state and runtime

- [x] 1.1 Add the fourteen-step shared scenario asset and validate its order and expected facts in a focused test.
- [x] 1.2 Implement sliding-tail and agent-memory facts projection with a natural budget replacement and reload test.
- [x] 1.3 Implement checkpoint, independent A/B continuations, lineage, and branch-local physical spend; verify sibling isolation and unique IDs in tests.
- [x] 1.4 Route each projected request through real transient `AgentRuntime`, recording every physical attempt and only API-reported usage; verify a failed unknown-usage attempt remains visible.

## 2. Demo experience

- [x] 2.1 Add native and safe-relay browser entries with a persistent strategy selector, selected/common next, run-all, reset, branch switch, and continuation controls; verify web and Linux builds.
- [x] 2.2 Show retained context, active facts and sourced edits, answer comparison, expected facts, lineage, and provider-only main/memory/combined usage with unknown states; verify through controller tests and manual browser review.
- [x] 2.3 Document runnable demo commands and honest quality, token, stability, and usability observations; verify instructions against built artifacts.

## 3. Checks

- [x] 3.1 Run format, analyze, full Flutter tests, Linux build, external web build, strict OpenSpec validation, and diff check on the final tree; record exact results in feature state.

## 4. Approved memory-agent redesign

- [x] 4.1 Replace fixed-field parsing with a second AgentRuntime role that proposes dynamic sourced add/update/delete operations; validate proposals, preserve no-op/untouched records, and atomically persist accepted edits with a processed-message marker.
- [x] 4.2 Use one immutable model/reasoning configuration for both roles; record every physical memory/repair/main call, API-only usage, and elapsed time, with at most one repair and idempotent main-answer retry.
- [x] 4.3 Provide natural shared prompts, active fact/edit/source inspection, free input, separate and combined totals, and explicit reset for old version 1 state.
- [x] 4.4 Add focused tests for validation, repair, failure rollback, retry, source refs, and non-default shared model/reasoning.
- [x] 4.5 Run the real DeepSeek comparison, inspect factual quality and memory traces, document actual results and caveats, and verify free input/reload in the browser.
- [x] 4.6 Run final format, analyze, full Flutter tests, Linux and external web builds, strict OpenSpec validation, and diff check on the frozen tree.
