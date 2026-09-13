## Context

The production stack already exposes real transient `AgentRuntime` calls, provider-only accounting, and a safe browser relay. Day 10 is isolated from production chat and from the Day 9 summary branch.

## Goals / Non-Goals

**Goals:** Same scenario and model, differences in retained request context, durable demo state, independent branch lineage, physical API-only ledgers, and a compact browser/native presentation.

**Non-Goals:** Core session migration, automatic merging, provider cost pricing, or claims that one strategy always saves tokens.

## Decisions

1. Use a branch-local facade that creates one transient agent with `initialMessages` per request on a reusable production runtime. This isolates comparison state from production JSONL sessions while preserving real provider dispatch and accounting.
2. Persist a versioned demo document through `SharedPreferencesAsync`. Each strategy stores the complete displayed user/assistant history. Requests reconstruct only the selected seed. For facts, a second transient `AgentRuntime` role receives the active memory, the last two completed pairs with IDs, and the new user message. It selects durable agreed goals, constraints, preferences, and decisions, consolidates related details, and proposes add/update/delete operations on dynamic facts. Transient reply-format instructions, repeated acceptance examples, hypotheticals, and unapproved ideas are excluded. Program code validates IDs, current-user provenance, shape, duplicate keys, and the complete proposed transaction; it then persists facts, edits, and the processed message marker together before the main answer. A bad result gets one additional physical repair call with the validation error and previous output. Invalid output or storage failure stops the step without applying a partial memory update. The main role receives active facts as JSON data plus the same two-pair tail. A retry of the same user message after main failure skips the already committed memory update; a different message is held until that pending answer is resolved.
3. At step eight copy the branching history into immutable-lineage A/B records. Each child has its own random branch identity and a fresh physical ledger. The parent call count is provenance only, so branch totals contain only new calls.
4. Give every facade physical attempt an ID built from branch UUID and monotonically increasing local ordinal. Core run IDs are not used for persisted identity, because a runtime may restart.
5. Use one immutable `Day10AgentConfig` for both main and memory definitions: the production DeepSeek Flash model, reasoning disabled, and a shared output cap 1536 by default. A non-default config test proves model, mode, and effort propagate identically to both roles. The browser entry routes only DeepSeek through the existing loopback relay, with the API key server-side.

## Risks / Trade-offs

- [Memory extraction can be wrong or incomplete] → Show source IDs and add/update/delete history, and compare final answers with explicit acceptance criteria without manufacturing a score.
- [The full-history branch can use more input tokens] → Show exact observed API totals and allow the final answers to speak for themselves.
- [A provider failure can occur after a physical attempt] → Persist a failed ledger row even when usage is unavailable, and do not add a completed pair. All memory and main physical calls, including correction attempts, contribute to separate and combined API-only ledgers; wall time is recorded per call.
- [A large one-click run can take time] → Persist after every step and allow continuation after reload.

## Migration Plan

This branch adds separate demo state under a versioned key. Version 1 deterministic-demo state is incompatible with version 2 memory records and explicitly starts a fresh scenario. Removing the demo leaves production sessions untouched.
