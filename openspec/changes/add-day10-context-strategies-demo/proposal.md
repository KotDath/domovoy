## Why

The existing demos show API usage and summarization but do not let a viewer compare alternative ways to preserve context or safely fork a conversation. A dedicated Day 10 demo makes each strategy's retained information, answer quality, and real API cost inspectable.

## What Changes

- Add a branch-local, persistent demo facade over real transient `AgentRuntime` calls for a two-pair sliding window, deterministic explicit facts with replacement, and full-history branching.
- Run the same fourteen-step scenario across all three strategies. Fork two independent continuations from step eight and expose lineage, active branch, and new spending.
- Display actual final answers, the eight expected facts, API-derived usage, retained context, and caveats about quality and usability. Provide native and safe loopback-relay browser entries.
- Add focused state/strategy tests and documented live demonstration instructions.

## Capabilities

### New Capabilities

- `day10-context-strategies-demo`: Comparative scenario, persistence, branching, and provider-only measurements in the Day 10 demo.

### Modified Capabilities

None. Production chat and core agent behavior remain unchanged.

## Impact

Only branch-local demo code, its asset, tests, documentation, and OpenSpec/state artifacts change. The browser relay keeps the DeepSeek key server-side. The demo does not change normal chat, implement semantic fact extraction, or use estimates for visible cost.
