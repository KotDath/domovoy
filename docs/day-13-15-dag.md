# Days 13–15 implementation DAG

This file is the execution ledger. `docs/day-13-15.md` defines behavior.

| ID | Group | Depends on | Status | Commit range | Evidence |
| --- | --- | --- | --- | --- | --- |
| G0 | Specification and Android tooling | — | done | `c986067..b615ee5` | docs; `claude-in-mobile` 4.4.1 Android doctor passes |
| G1 | FSM, DAG, and invariant domain | G0 | done | `b615ee5..94b6657` | 16 domain tests; paired review completed |
| G2 | JSONL persistence and recovery | G1 | done | `94b6657..72b2765` | 11 repository/replay tests; paired review settled; full suite: 760 passed, 1 skipped |
| G3 | Scheduler and isolated agents | G2 | done | `af65e8d..3097149` | paired review settled; 13 scheduler/gateway tests; full suite: 773 passed, 1 skipped |
| G4 | Chat routing and task UI | G3 | done | `cefe9c5..bd646bc` | paired review settled; command-router, session-switch, and task-card widget tests; full suite: 781 passed, 1 skipped |
| G5 | Integration, Android, video scripts | G4 | pending | — | full suite and QA evidence |
| G6 | Final certification | G5 | pending | — | two-agent review and Android regression |

## Gate for every code group

1. Format, analyze, and run relevant plus full tests.
2. Commit the group and record the range above.
3. Launch two fresh OpenCode reviewers through Orca with identical read-only
   instructions. They must treat the docs as authoritative and inspect the full
   tree plus the group diff.
4. Use `opencode-go/muse-spark-1.3-contributor` at `xhigh` and
   `opencode-go/deepseek-v4.1-flash` at `max`; verify effective launches.
5. Fix shared findings and verified critical unique findings, rerun checks, and
   commit the corrections.
6. Release both settled workers. Never carry reviewers into the next group.

Final certification repeats with fresh pairs until no shared actionable finding
remains. Android manual QA is performed by a separate retained Codex session
using `gpt-5.6-luna` at `xhigh` and the `claude-in-mobile` MCP.

## G1 review settlement

Both reviewers identified restart/resume dead-ending in `interrupted`, unsafe
snapshot decoding, and missing authority-layer integration for invariant errors.
The G1 fix rearms interrupted nodes only after explicit resume, enforces a single
active node for sequential DAG execution, separates repair count from interrupted
attempts, validates versioned snapshots, and adds final repair guards. Invariant
rejection is intentionally completed by the G3 `TaskService`, where resolved
project/task policies are available; it must return `INVARIANT_VIOLATION` before
any LLM call and `REPLAN_REQUIRED` after an applied policy revision changes.

## G2 review settlement

Both successful reviewers identified missing restart interruption, mutable task
identity, and incomplete persistence boundary checks. The settlement adds an
explicit persisted startup-recovery operation, rechecks the one-active-task
invariant on every active save, pins session/project identity across revisions,
and binds invariant-policy payloads to their owner key. It also isolates corrupt
streams to their hinted chat, trims torn UTF-8 tails at the byte boundary, fails
closed on fragment-only streams, and treats post-publication cleanup as
best-effort. App composition in G4 must create exactly one shared store instance;
the documented JSONL storage contract intentionally does not coordinate
independent writers.

## G3 review settlement

Both reviewers identified that provider cancellation errors escaped the command
API and that pausing an in-flight invocation left the UI running flag stale. The
settlement makes cancellation best-effort while persisted reducer transitions
remain authoritative, resets invocation state on human commands, and persists a
recoverable paused checkpoint after an agent failure. A confirmed plan-envelope
false positive was fixed by applying answer-size and required-term checks only
to worker/final content, while forbidden-term and semantic checks still protect
plans. Task-agent runs now explicitly disable runtime personalization and memory
context, preserving the bounded-payload isolation contract. Targeted tests,
`flutter analyze`, and the full 773-pass/1-skip suite are green.

## G4 review settlement

Both successful reviewers found that goal-capture mode intercepted task commands
and that `/plan` could arm another goal while a task was already active. The
settlement gives task commands precedence, refuses the second `/plan` with
`INVALID_TRANSITION`, waits for chat attachment before routing input, localizes
status text, and hides stale task UI when no chat is selected. It also makes
replanning accept an edited goal for the Day 14 conflict scenario, surfaces
invariant-loading failure, and bounds provider cancellation so pause/replan/
cancel cannot wait forever. Targeted tests, `flutter analyze`, and the full
781-pass/1-skip suite are green.
