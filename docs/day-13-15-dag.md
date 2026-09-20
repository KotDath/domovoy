# Days 13–15 implementation DAG

This file is the execution ledger. `docs/day-13-15.md` defines behavior.

| ID | Group | Depends on | Status | Commit range | Evidence |
| --- | --- | --- | --- | --- | --- |
| G0 | Specification and Android tooling | — | done | `c986067..b615ee5` | docs; `claude-in-mobile` 4.4.1 Android doctor passes |
| G1 | FSM, DAG, and invariant domain | G0 | review | `b615ee5..2f0d67e` | 12 domain tests; full suite 745 passed, 1 skipped |
| G2 | JSONL persistence and recovery | G1 | pending | — | repository/replay tests |
| G3 | Scheduler and isolated agents | G2 | pending | — | orchestration tests |
| G4 | Chat routing and task UI | G3 | pending | — | controller/widget tests |
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
