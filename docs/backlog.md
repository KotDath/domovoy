# Domovoy memory backlog

The Day 11 implementation deliberately stops at project-scoped working memory
and confirmed global memories. The following work is deferred and must not be
silently folded into the first version.

## Tasks

- Introduce a first-class `TaskId`, task lifecycle, active-task selection, and
  task-scoped working memory.
- Define migration from project-scoped working entries to task-scoped entries
  without losing provenance or revision history.
- Let one project contain several tasks and let chats switch their active task
  without changing project filesystem access.
- Add task completion hooks that propose reusable lessons for long-term memory.

## Extraction and consolidation

- Replace the in-process foreground debounce with a durable scheduler where the
  platform can guarantee execution.
- Evaluate Android background work and iOS BackgroundTasks independently;
  foreground recovery remains the required fallback.
- Add typed user profiles, conflict detection, temporal validity, TTL, and
  periodic consolidation of duplicate or superseded memories.
- Add risk-based automatic acceptance only after measuring candidate precision;
  profile, policy, and sensitive memories must continue to require confirmation.

## Retrieval and evaluation

- Evaluate full-text and hybrid retrieval before introducing embeddings.
- Add retrieval quality telemetry: candidate precision, stale-memory rate,
  scope leakage, prompt budget, latency, and LLM cost.
- Add multi-session, temporal-update, contradiction, and abstention benchmarks.
- Add a macOS CI runner or connected Mac for physical iOS build and simulator
  smoke tests.

