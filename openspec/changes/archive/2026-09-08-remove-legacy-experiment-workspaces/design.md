## Context

See `proposal.md` for motivation. The application currently constructs five independent destinations in one `IndexedStack`; four are assignment-style laboratories and account for most production feature code. The retained prompt workspace already provides a self-contained one-shot path through the DeepSeek credential resolver and OpenAI-compatible streaming transport.

The repository has uncommitted agent-tooling configuration changes outside this change. Implementation and commits must not modify or stage those files. All six configured Flutter platforms remain supported.

## Goals / Non-Goals

**Goals:**

- Leave one coherent, runnable prompt application rather than an empty shell.
- Remove laboratory code, tests, documentation, dependencies, and product requirements as one traceable vertical deletion.
- Preserve the current prompt workspace behavior exactly enough for independent regression verification.
- Establish a small baseline for the subsequent agent-layer change.

**Non-Goals:**

- Salvaging Day 5 comparison profiles as future agent profiles.
- Introducing conversations, tools, provider registries, cost ledgers, or new persistence.
- Migrating or actively wiping existing `day5_*` platform-storage records.
- Narrowing platform support or changing native application identifiers.
- Refactoring the retained one-shot prompt transport beyond removal of newly dead references.

## Decisions

### Delete experiment features as complete vertical slices

Remove `lab`, `reasoning`, `temperature`, and `comparison` code together with their tests and demonstration artifacts. Keeping isolated helpers would preserve accidental APIs and encourage the next agent layer to inherit experiment-specific concepts such as lanes, comparison tiers, and assignment prompts.

Alternative considered: retain profile, pricing, and validation helpers from Day 5. Rejected because their persisted schema, credential keys, and domain vocabulary are explicitly comparison-specific.

### Retain the one-shot prompt workspace as the temporary root

Replace the five-child `IndexedStack` and bottom navigation with the existing prompt page as the sole home surface. Keep the existing DeepSeek resolver, reasoning setting, SSE decoder, usage parsing, and error behavior until the next change replaces them behind the agent runtime.

Alternative considered: leave an empty application shell. Rejected because it would make cleanup harder to verify and unnecessarily interrupt the existing working provider path.

### Do not migrate legacy experiment data

Remove code paths that read or write Day 5 profiles and profile-scoped credentials. Existing values may remain unreachable in platform secure storage; this change neither migrates nor guarantees erasure of those local records.

Alternative considered: add a one-time storage cleaner. Rejected because it would retain legacy schema knowledge and introduce migration code solely for prototype data the user explicitly approved discarding.

### Keep cleanup and agent architecture as separate changes

This change may simplify only references that become dead due to deletion. It must not pre-create `AgentProfile`, `AgentSession`, or `AgentRunner`; those require their own behavioral contract and acceptance tests.

### Preserve repository history and platform scaffolding

Keep archived OpenSpec changes and all configured Flutter platform directories. Main capability specs are updated through removal deltas when this change is archived; archived planning artifacts remain historical evidence.

## Risks / Trade-offs

- [Retained prompt code will be replaced soon] → Avoid broad refactors; verify only behavioral parity and allow the next change to replace it deliberately.
- [Tests may import shared experiment types indirectly] → Delete by vertical slice, search for all remaining imports and Day 2–5 labels, then run the complete Flutter checks.
- [Legacy secure-storage values can remain on devices] → Document the absence of migration/wipe; use a distinct storage namespace for the future agent layer.
- [Removing broad capabilities can leave stale docs or specs] → Include repository-wide searches for laboratory labels, paths, preset ids, and `day5_*` keys in acceptance checks.
- [Existing unrelated worktree changes could enter commits] → Stage only the OpenSpec change for the planning commit and only implementation-owned files for later commits.

## Migration Plan

1. Commit this planning change independently.
2. Remove experiment navigation and dependencies from the application composition root.
3. Delete the four experiment feature trees and their tests, smoke tests, and demo documentation.
4. Remove dependencies and configuration made unused by those deletions, and refresh generated dependency metadata normally.
5. Update README and project OpenSpec context to describe the retained prompt workspace baseline.
6. Verify formatting, static analysis, tests, and repository-wide absence of legacy references.
7. Commit the implementation separately; after review and OpenSpec verification, archive only when the workflow is explicitly completed.

Rollback is a revert of the implementation commit; no data conversion must be reversed.
