## Context

The production stack already exposes real transient `AgentRuntime` calls, provider-only accounting, and a safe browser relay. Day 10 is isolated from production chat and from the Day 9 summary branch.

## Goals / Non-Goals

**Goals:** Same scenario and model, explicit differences in retained request context, durable demo state, independent branch lineage, physical API-only ledgers, and a compact browser/native presentation.

**Non-Goals:** General semantic memory extraction, core session migration, automatic merging, provider cost pricing, or claims that one strategy always saves tokens.

## Decisions

1. Use a branch-local facade that creates one transient agent with `initialMessages` per request on a reusable production runtime. This isolates comparison state from production JSONL sessions while preserving real provider dispatch and accounting.
2. Persist a versioned demo document through `SharedPreferencesAsync`. Each strategy stores the complete displayed user/assistant history. Requests reconstruct only the selected seed. The explicit facts map is updated deterministically from supported scenario fields and `key: value` input before dispatch; it never claims general language understanding.
3. At step eight copy the branching history into immutable-lineage A/B records. Each child has its own random branch identity and a fresh physical ledger. The parent call count is provenance only, so branch totals contain only new calls.
4. Give every facade physical attempt an ID built from branch UUID and monotonically increasing local ordinal. Core run IDs are not used for persisted identity, because a runtime may restart.
5. Use the production DeepSeek Flash model with reasoning disabled and output cap 768. The browser entry routes only DeepSeek through the existing loopback relay, with the API key server-side.

## Risks / Trade-offs

- [Deterministic fact recognition is narrow] → Display the stored fact map and document supported fields; never imply a general extractor.
- [The full-history branch can use more input tokens] → Show exact observed API totals and allow the final answers to speak for themselves.
- [A provider failure can occur after a physical attempt] → Persist a failed ledger row even when usage is unavailable, and do not add a completed pair.
- [A large one-click run can take time] → Persist after every step and allow continuation after reload.

## Migration Plan

This branch adds separate demo state under a versioned key. Removing the demo leaves production sessions untouched.
