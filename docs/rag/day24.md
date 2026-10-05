# Day 24 — exact citations before answer persistence

Status: implementation, checks and independent reviews complete;
verified Android demo complete. Ready for push and merge.

Authority: [assignment](assignment.md), [agreed plan](implementation-plan.md),
AGENTS.md. Base `8248c23e83cf276a4ea20cccd6e79c79843c0684`.
Feature `feature/day-24`; implementation and actual native dev/golden source
`f047306659c987800852cc2056a6b306ec692156`; final reviewed code
`3b4e25ae47c02272b4abb87c64fd49e755bd7c5c`. The final delta fixes actual Android
citation contrast and successful repair completion metadata; neither changes the
frozen ordinary ten answers, which required no repair.

## Behavior

Production document mode uses strict status `answered` / `partial` / `abstained`
and individually cited factual claims. The host accepts only the exact JSON
schema and actual sent chunk IDs with verbatim quotations. It supplies source,
section, revision and UTF-16 coordinates from immutable evidence; model-authored
coordinates/metadata, altered or missing quotes and unknown IDs fail closed.
This validates quotation provenance, **not semantic entailment**.

Generic `AgentFinalAnswerGate` buffers draft text/reasoning before finalization,
accepted history/checkpoint and completed-turn extraction. At most one isolated
repair uses the admitted model/generation, tools/history disabled and the same
request/budget/cancellation checks. Both actual invocations retain usage entries;
only the accepted host-rendered answer gets a response-message identity.
Rejected drafts live only in labelled immutable diagnostic JSONL records.
Ordinary chat preserves streaming and completed-turn behavior. Strict RAG disables
completed-turn memory extraction so retrieved documents do not become user memory.

Empty final evidence uses generic `AgentRespondWithoutModel`: user plus host
abstention persist with no answer provider call, no invented sources/quotes and
an explicit clarification request. Infrastructure failures remain failures.
M3/M4 may already have called the isolated rewrite before the empty result is
known; that auxiliary generation is separately recorded and is not claimed to
have disappeared. A raw-query M2 empty result uses no cloud generation at all.

Inspector exposes validation/status/diagnostics and source citations. The source
viewer checks the frozen stored revision/span again, displays the exact quotation
and highlights it in the complete sent chunk. Historical traces remain readable.
Explicit default-OFF fault injection corrupts a real model draft's ID or quote
before each validation; visible labels and diagnostic fields distinguish these
negative demonstrations from normal model results.

## Real checks and ten questions

`dart format .`:580 files,zero changes. Analyze clean;1454 tests pass,four platform
skips. Android/Linux debug builds pass. Deterministic checks exercise one repair,
usage accounting, two rejected drafts and restored history, cancellation during
validation, zero-answer-model host response, Unicode offsets, forged ID/quote/
coordinates, trace replay and real citation-view highlight/tampering behavior.

Native Linux uses the production registry/coordinator/controller/UI/storage,
real Qwen Ollama embeddings, actual official BGE llama.cpp reranker and DeepSeek
Flash, temperature0,reasoningdisabled,max output2048. Same fixed128-chunk frozen
12-document corpus and unchanged day23 calibration; fresh neutral sessions.
Eight dev questions passed first, then all ten golden questions. Expected facts
are host-only review/evaluation data and never generator inputs. No thresholds,
rewrite or grounded-answer prompt were retuned after the golden run.

Ten admitted outcomes: seven answered, three abstained (known Q02/Q04 and unknown
Q10). Seven answer requests, ten separate rewrite calls, no real repair needed in
this ordinary run;32 factual claims, all accepted citations automatically checked
against sent text/revision/UTF-16 spans. Median total8849ms. Provider inclusive
answer input/output16136/4109 tokens;rewrite1781/276, counted without adding cache
reads twice. Independent Codex agent semantic score is **15/20**, unsupported assertions **0**;
matched day23 M4 was17/20 with4 unsupported assertions.
All36 accepted citations on32 claims have exact provenance.31 claims are directly
supported by their own quotations. Q01 claim1 names are established by subsequent
quotes in the same sent chunk, a per-claim attachment weakness. Q03 omits preferences
exception/working priority despite available evidence. Q07/Q08 include clipped
quotes. Sources/quotes appear in all seven substantive answers; three abstentions
have none because there is no evidence. This is agent expert review, not human review.
Source precision is separate from whether the answer fully satisfies expected facts.
Known refusals and any quality regression will be retained in the final report.

Android dev smoke on the existing Orca-attached emulator5554 used real requests,
accepted individually quoted profile-interview facts and showed inspector validation.
Final verified video is recorded on reviewed3b4e25a. All actual runs and review data remain in
`/home/kotdath/Videos/domovoy/evidence/day-24/`; binaries, secrets and videos are not
committed. Source/code revision and raw logs are preserved for reproduction.

## Review and delivery status

Pi cycle1 incomplete: transport ended without finish_reason, then a response
requested unavailable tools as unexecuted markup. Its partial approval is not a
completed code sign-off. Cycle2 uses a supplied-source review system prompt with
no tools and the required exact `opencode-go/deepseek-v4.1-flash` model.
Pi cycles2 and3 completed substantive **APPROVE CODE**. Cycle3 review supplied the
final delta. Residual R1 hypothesized structural/PDF coordinate mismatch: invalid for
this implementation, because RagIndex validates exact source substring and `_chunk`
constructs that slice for both strategies (core/rag/models.dart, chunking.dart and
chunking tests). R2 provider continuation discard is intentionally documented;
it refers to the rejected raw draft, not the rendered host-approved text. R3 null
physical-request count on ordinary traces is an implicit harness convention; actual
receipts/usage count the seven calls. R4 one-user-message repair is an explicit limit.

Final Codex `gpt-6.1-sol high` **APPROVE CODE** at6b0812b after its P2 finding:
accepted repair previously reported rejected first draft's finish reason. Runtime
now reports repair stop, and regression length→stop passes. Discovery was Codex's,
although Pi cycle3 incorrectly attributed it to cycle2. No other actionable findings.
Actual video QA then exposed the complete-chunk TextSpan inheriting above-Scaffold
debug DefaultTextStyle. Fixed to explicit app bodyMedium in3b4e25a; widget root-style
regression and supplemental final Codex review approved. Final format/analyze/
all1454 tests+4skips and Android/Linux builds passed3b4e25a. Pi max3cycles retained;
no fourth cycle was run for this cosmetic fix. Faulty/failed capture files remain
labelled separately outside the final video.

| Question | Day24 /2 | Prior M4 /2 | Meaning/quality |
|---|---:|---:|---|
| Q01 | 2 | 2 | Correct scopes; first claim attachment weaker than following quotes. |
| Q02 | 0 | 1 | Known refusal, prior four unsupported claims removed. |
| Q03 | 1 | 2 | Correct ordinary facts and12,000; preference exception/priority omitted. |
| Q04 | 0 | 0 | Known refusal; disable/delete unanswered. |
| Q05 | 2 | 2 | Correct4,000/2,500 and four mandatory sections. |
| Q06 | 2 | 2 | Foreground and one catch-up supported. |
| Q07 | 2 | 2 | Correct DST policy; duplicated/clipped quote. |
| Q08 | 2 | 2 | Correct intrinsic prohibition; technical quote clipped. |
| Q09 | 2 | 2 | Documented Android transports/report; historical framing could be clearer. |
| Q10 | 2 | 2 | Safe unknown; no invented benchmark. |

Planned capture: supported answer → exact source/highlight; M2 unknown → host
refusal/no cloud generation; explicitly labelled bad ID and bad quote rejected
once plus one repair → restart verifies no rejected assistant message in accepted
history. Keep all complete source recordings. Demo sign-off and push/merge pending.

## Verified delivery artifact

Video: `/home/kotdath/Videos/domovoy/day-24-demo.mp4`.
H.264,1080×2400,video only,321.573656s,38,936,908bytes.
SHA-256 `984169131894e063442bf23ac1eaa836663350746973f87616f3b6c64d7a8e47`. Four complete native clips retained. All Android input and
platform screenrecord start/stop used Orca on the existing emulator5554;
readonly ADB pulls copied recordings/scoped evidence. No extra emulator or audio.
Record start/new nonempty growing file and finally-stop were checked. Final
start/source/host-refusal/fault-diagnostic/restart/end frames were inspected.
Failed recording/helper/font runs remain separately labelled outside finalvideo.

| Fresh chat | Protocol | Answer calls | Accepted history | Recorded proof |
|---|---|---:|---|---|
| Supported limits | M4 | 1 | user+assistant | Correct4,000/2,500; exactsource/revision/UTF-16highlight |
| Unknown Pixel9 benchmark | M2 | 0 | user+host |20→0,sourcesempty,clarification; no rewrite or cloudgeneration |
| Explicit falsechunkID | M4 | 2 | useronly | initial+onerepair rejected citation_not_sent; same afterrestart |
| Explicit falsequote | M4 | 2 | useronly | initial+onerepair rejected citation_not_exact; same afterrestart |

All use neutral comparison, strictgroundingON, DeepSeekFlash, reasoningdisabled,
max2048, no tools/continuations; supported/fault M4 auxiliary rewrite is separately
recorded. Android answer temperature is equally unspecified. Narrow RAG archive
activegenerations/footerhashes and only the four known demo-session records prove
realcalls and acceptedroles; no unrelated application/session data was copied.
`android-demo-proof.json`, `android-recorded-traces.json`, `recordings.json`,
`final-code-validation.json`, `verified-video.json` remain in external evidence.
The live numeric claims are correct but DeepSeekFlash returned Chinese claim
text despite an English question/languageinstruction; English verbatimquotes and
Russian UI are visible. Quote validation does not establish language compliance.
No translated/canned answer was substituted.
