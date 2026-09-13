## Why

Day 9 needs a repeatable demonstration that long chat history can be summarized while recent turns remain verbatim. The existing agent runtime provides safe compaction contracts, but there is no scenario, cadence rule, or comparison UI showing the effect on answer quality and actual API usage.

## What Changes

- Add a branch-local custom trigger and structured-summary compactor that summarize after each 10 newly completed raw user/assistant messages and retain the last two complete pairs.
- Persist one generated summary separately from retained transcript messages through the existing agent-session JSONL/provenance mechanism.
- Add a Day 9 native/browser demo that runs the same 14-step brief in uncompacted and summarized sessions, shows their answers side by side, and separates assistant usage from summary overhead using provider-reported values.
- Provide step-by-step and automatic execution plus recording guidance and focused regression tests.

## Capabilities

### New Capabilities

- `day09-history-summary-demo`: Cadenced summary strategy and comparable, truthful Day 9 demonstration.

### Modified Capabilities

None. The production runtime and its default compaction policy remain unchanged.

## Impact

Day 9 demo code, an optional production-stack compaction injection seam, branch-local assets/tests/docs, and a browser relay entry. Existing main app entry and provider protocols retain their behavior.
