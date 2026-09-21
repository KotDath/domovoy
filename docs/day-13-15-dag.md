# Days 13–15 implementation DAG

This file is the execution ledger. `docs/day-13-15.md` defines behavior.

| ID | Group | Depends on | Status | Commit range | Evidence |
| --- | --- | --- | --- | --- | --- |
| G0 | Specification and Android tooling | — | done | `c986067..b615ee5` | docs; `claude-in-mobile` 4.4.1 Android doctor passes |
| G1 | FSM, DAG, and invariant domain | G0 | done | `b615ee5..94b6657` | 16 domain tests; paired review completed |
| G2 | JSONL persistence and recovery | G1 | done | `94b6657..72b2765` | 11 repository/replay tests; paired review settled; full suite: 760 passed, 1 skipped |
| G3 | Scheduler and isolated agents | G2 | done | `af65e8d..3097149` | paired review settled; 13 scheduler/gateway tests; full suite: 773 passed, 1 skipped |
| G4 | Chat routing and task UI | G3 | done | `cefe9c5..bd646bc` | paired review settled; command-router, session-switch, and task-card widget tests; full suite: 781 passed, 1 skipped |
| G5 | Integration, Android, video scripts | G4 | done | `b52fcf4..d126e90` | paired review settled; analyze clean; 790 passed, 1 skipped; Days 13–15 pass on API 35 with reproducible evidence |
| G6 | Final certification | G5 | done | `d126e90..db73237` | both closing reviewers found no P0–P2; all confirmed P3 findings settled; analyze clean; 798 passed, 1 skipped; final APK smoke passes on API 35 |

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

## G5 review settlement

Both reviewers identified the missing chat-creation failure test and runbook
reproducibility gaps. The settlement covers failure reporting, sandbox escape
and sibling-symlink rejection, exact UI labels, local artifact hygiene, the
pinned provider/model, and a bounded-repair fallback. Verified unique findings
also clear a stale cross-chat snapshot after recovery failure, expose the
verified final result, distinguish invariant load/save failures, and contain
automatic-loop persistence errors. Independent Android QA found a restart-only
task-ID collision that static review missed; task controllers now use a
process-unique namespace, with a regression test that creates a second task
against the same persisted store after controller restart. Targeted tests,
`flutter analyze`, and the full 790-pass/1-skip suite are green.

## G6 certification progress

The first fresh pair agreed that the Android evidence/runbook needed a single
traceable scenario. A verified unique finding also showed that fragment-only
task corruption could bypass active-task lookup; session discovery and the
one-active-task guard now fail closed when no trustworthy owner hint exists.
The same settlement hides replan while paused and stops legal diagnostic probes
from reporting `INVALID_TRANSITION`.

Independent final-head Android QA then exposed a video-specific race: the
`VALIDATION_REQUIRED` reaction was correct but was cleared by the next automatic
revision before a stable frame could be recorded. Diagnostic failures now remain
observable across automatic revisions in their phase, stale plan notices are
hidden after planning, and a regression test covers the behavior. On API 35 the
exact Day 15 prompt retained `VALIDATION_REQUIRED` through `r14` and `r15` at
3/5 nodes, then automatically reached `done` at `r24`, 5/5, with the verified
result expanded.

The closing Muse and DeepSeek pair found no P0–P2 issue. Their shared finding
was stale notice/certification data; verified unique P3 findings covered
content-only invariant scope and persisted failure priority. The settlement
clears plan/replan/pause/resume notices at their lifecycle boundaries, keeps
invalid-command diagnostics visible at terminal state, applies required-term
and maximum-character rules only to produced content, and lets a persisted
`REPAIR_EXHAUSTED` failure supersede a retained diagnostic. Four regression
tests cover these cases.

The final debug APK was built from `db73237`, has SHA-256
`e6fe00e15243c3765664a56dd0ca79c43deac19265c338e933d2a18943757452`,
and passed a fresh DeepSeek Flash run through `claude-in-mobile` on Android 15 /
API 35: automatic completion reached 4/4, status and unknown-command notices
remained observable at `done`, and stale plan/replan notices were absent.
`flutter analyze` is clean and the full suite is 798 passed, 1 skipped.
