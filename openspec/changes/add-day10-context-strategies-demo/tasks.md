## 1. Strategy state and runtime

- [x] 1.1 Add the fourteen-step shared scenario asset and validate its order and expected facts in a focused test.
- [x] 1.2 Implement sliding-tail and deterministic facts projections with a budget replacement and reload test.
- [x] 1.3 Implement checkpoint, independent A/B continuations, lineage, and branch-local physical spend; verify sibling isolation and unique IDs in tests.
- [x] 1.4 Route each projected request through real transient `AgentRuntime`, recording every physical attempt and only API-reported usage; verify a failed unknown-usage attempt remains visible.

## 2. Demo experience

- [x] 2.1 Add native and safe-relay browser entries with a persistent strategy selector, selected/common next, run-all, reset, branch switch, and continuation controls; verify web and Linux builds.
- [x] 2.2 Show retained context, facts, answer comparison, expected facts, lineage, and provider-only usage with unknown states; verify through controller tests and manual browser review.
- [x] 2.3 Document runnable demo commands and honest quality, token, stability, and usability observations; verify instructions against built artifacts.

## 3. Checks

- [x] 3.1 Run format, analyze, full Flutter tests, Linux build, external web build, strict OpenSpec validation, and diff check on the final tree; record exact results in feature state.
