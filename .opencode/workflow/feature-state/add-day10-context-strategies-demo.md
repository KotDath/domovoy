# Feature State — add-day10-context-strategies-demo

- change: `add-day10-context-strategies-demo`
- scope_id: `day10-second-memory-agent`
- stage: `accepted`
- base_revision: `12389ee` (previous day-10 README commit; initial worktree clean)
- initial_tier / current_tier: T2 / T2 (persistence, retries, real paid API usage)
- recommended_mode / execution_mode: heavy / heavy, continuing the existing coupled-state workflow
- selection_source: user approved the proposed two-agent design and explicitly requested identical model/reasoning for both roles; root continued existing heavy workflow
- writer: `/root/memory_writer` (Sol), then root for final docs/process and whitespace formatting after writer quota interruption; never concurrent writers
- verifier: `/root/memory_verifier`, independent replacement for unavailable DeepSeek verifier; no DeepSeek verifier model claim
- included: day10 engine, memory proposals, invoker, UI, natural scenario, focused/live tests, README/evidence, existing OpenSpec change
- excluded: main, days 6–9, summary, general runtime fork API, arbitrary background scheduling
- user gates: design approved; implementation, live testing, commit/push authorized
- decisions: memory/main share one immutable model+generation config (Flash, reasoning disabled, model-default effort, output1536 by default); memory proposes dynamic sourced operations; validated proposal+processed marker saved before main; one repair; untouched facts retained; failed-main retry reuses accepted memory; actual physical role ledgers and local elapsed time; v1 state explicitly resets; source history expandable
- evidence: target v3 13 tests `/tmp/domovoy-day10-memory-target-v3.log`; final full suite 477 `/tmp/domovoy-day10-memory-tests-final.log`; final analyze exit0 `/tmp/domovoy-day10-memory-analyze-final.log`; final day10-target Linux debug exit0 `/tmp/domovoy-day10-memory-linux-final.log`; final external web build `/tmp/domovoy-day10-memory-web-build-final.log` with fonts and assets; strict validation `/tmp/domovoy-day10-memory-openspec.log`
- live evidence: `docs/evidence/day10-memory-live.json` equals saved real second run; 14 steps each, Sliding12430 tokens/0 of8, Facts92531 including15memory calls/8of8, Branching28252/8of8. A4255 waiting-list only, B4201 family-only. Facts40 records, updated budget and explicit delete old reportname, no active voice hypothesis. First exploratory prompt 102957 Facts tokens retained as historical observation only.
- manual UI: PASS final browser build at localhost8772: seven natural free messages, dynamic add name/budget/date, update90000→110000, delete date, no active hypothetical voice feature; two neutral turns then reload restored6pairs/7603tokens and selected Facts; final answer Ladoga110000/dateunknown/voicestatusunknown;14calls8833tokens. Source expansion visually checked. docs/evidence/day10-memory-manual.json records exact prompts and observed usage.
- rework_count: 0 (prompt selectivity improvement preceded formal acceptance review)
- open_findings: none; independent final verification PASS, 0 formal fix cycles
- previous accepted scope: day10-branch-demo (deterministic parser), superseded by this approved redesign; its old PASS does not cover this scope

- independent_verification: PASS from `/root/memory_verifier`, final AC matrix covers model/reasoning parity, dynamic sourced operations, atomic save/retry, context isolation, physical accounting, UI/reload, actual results and final checks. Independently confirmed 15-file fingerprint `c163155834be0b4cd08bc471a9d3c14bf087c0fffb0f516a9e057f3e6dd851e0` excluding only this state.
- final_format: `dart format .` 174 files / 0 changes; clean diff; documentation links and credential scan passed. Native full-app restart was not manually tested; browser reload and Linux target build were verified.
