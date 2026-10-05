# Day 25 — automatic dialogue task state

Authority: [agreed plan](implementation-plan.md), [assignment](assignment.md).
Baseline: challenge `52c8ab5fd51856b8c90c9f348ef5f0ed1391ab20`.
Implementation/evaluation source: `048057f4c0d9be91c8a609906ac7d778f28b63da`.
Delivery artifacts and actual measurements are listed below; reviewed product
source is unchanged by the delivery documentation commit.

## Behavior

Task conditions are separate per project/chat in `rag-task-state-jsonl-v1`.
Validated patches apply automatically from exact substrings of the newest USER
message. Goal, constraints, terms, clarifications and explicitly undecided choices
retain original text, host submission ID, SHA-256 and revision. They are not
manually confirmed working/long-term memory. Documents, assistant answers and
tools cannot write these conditions. UI shows changes, manual edits, superseded
values and explicit retirements; disabling use preserves stored records.

Recognizable read-only recovery/factual requests cannot update ANY task slot.
A valid extractor patch attempting that becomes an audited no-op (actual ignored
row count retained); existing conditions remain available to the answer. Exact
schema and newest-user quote checks still apply. This conservative grammar covers
English/Russian read/recover forms; it is not universal semantic classification.
An explicit first USER objective initializes an empty goal even when a factual
question follows. New declarative preferences/clarifications preceding a recovery
request are extracted; the recovery itself cannot replace existing slots.
Replacing an existing goal automatically requires explicit goal-change wording
(e.g. `Our new goal is …`, `Change our goal to …`, `Новая цель: …`). Factual
returns or recovery questions cannot overwrite it; other wording can be handled
by manual editing. Invalid auxiliary patches retain the previous goal.
Automatic replacement/retirement of a lexically compound constraint preserves
the original fact unless the USER explicitly declares a whole scope/constraint
replacement or removal. A goal change alone is insufficient. Other valid updates
still apply; ignored IDs are audited and a visible notice explains manual/full
replacement. Conjunction/list detection is a bounded English/Russian policy with
false positives and incomplete semantic coverage, not an entailment guarantee.
Clock slots reject composite time/timezone values. A change 09:00→08:30 preserves
the separate Europe/Moscow slot. CAS and guarded atomic JSONL publication prevent
late extraction/cancellation from replacing a newer state. Valid user-input
admission survives a failed answer; provenance uses its admission ID rather than
inventing an accepted assistant-history link. Extraction timeout/network/malformed
output gives a visible notice and omits stored conditions for that answer, preventing
an old condition from silently defeating the latest user correction. Storage/audit,
CAS and actual user cancellation remain hard failures.

Each answer freezes conditions and retrieves fresh documents. M1/M2 retrieve the
original question; task-aware M3/M4 rewriting requires explicit experimental
thresholds and cannot reuse the frozen state-free day-23 calibration. No retuning
of that calibration occurred. User sources have scoped revision-bound IDs and exact
UTF-16 coordinates in original input. Document citations retain document revision
and exact coordinates. Derived claims require both source kinds and render as
proposals rather than executed actions.

Normal strict task answers preserve the entire admitted prior dialogue as labelled
untrusted JSON role/text/message-ID data, including follow-up context, and send the
actual newest user message separately. This prevents old host-rendered Markdown
from acting as an assistant-role output example. Private reasoning is excluded;
full serialized history still consumes the request budget. Transcript and compaction
input remain unchanged. The actual history policy is in request traces.

For supported Chat Completions/Responses transports, these requests and the
extractor explicitly use JSON output syntax. Host schema/source validation remains
mandatory. If JSON mode returns only whitespace, the ONE isolated repair uses text
transport while still requiring strict JSON and valid sources; there is no second
repair or Markdown acceptance. Other invalid drafts retain JSON transport. The one real model repair receives a
diagnostic draft suggestion: only original model claim text, exact original spans
from CURRENT sent sources, with unavailable citations/empty claims removed. It is
not an accepted answer or semantic approval. The original rejected draft remains
in diagnostics; the final model response still passes the unchanged strict gate.
Suggestions preserve PDF control/soft-hyphen markers as original source characters.

The real UI diagnostic repeats the last accepted question twice with identical
actual preceding two messages, M1, corpus/index, model and generation settings,
without earlier history, summaries, profile or shared memory. Only frozen task
state differs. It uses production providers in isolated shadow sessions, does not
invoke a fake extractor or modify original history/state, and records replay IDs
separately from original accepted-message IDs. Initial requests are compared;
isolated repair requests are audited separately. The product compares actual initial
generation/fingerprint/candidates/evidence/context, model/settings/history and
nonstate prompt; a mismatched pair is explicitly invalid rather than attributed to
state memory.

## Checks and evidence

Full deterministic suite: 1498 passed, four pre-existing skips. Android/Linux debug
builds and analyzer logs are retained under
`/home/kotdath/Videos/domovoy/evidence/day-25/`.
Real evaluation source: `integration_test/day25_live_io_test.dart`; questions are
frozen in `eval/rag/dialogue_scenarios.json`. Two twelve-question dialogues use
DeepSeek V4 Pro, temperature 0, reasoning disabled, output cap 2048, M1 fixed top-5,
neutral profile and no tools/continuations. Both restart before question nine.
MemGPT, MemoryBank and Generative Agents PDFs have verified bytes/hash/version/page
count from `eval/rag/arxiv_sources.json`; actual extraction/indexing precedes paper
questions. B reuses the same validated immutable paper index, explicitly recorded
as publication rather than a second index build.

Earlier incomplete evaluations are retained, not renamed as successes: transport
failure, verbose/language drift, composite clock extraction, Markdown drift,
invalid root `kind`, a whitespace-only JSON draft, and semantic slot drift during B recovery. These exposed the fixes
above. Further preserved runs exposed an initial goal omitted before a factual question,
and a new format clarification ignored before a recovery request. Post-request
scenario checks now require the retained user conditions, not just accepted JSON.
The frozen questions remain unchanged. Optional bounded explicit USER
resubmissions retain all failed/insufficient initial turns and measure every extra
send; first submissions and successful retries are graded separately. The one
model repair per user turn is unchanged. Both actual replay rows are persisted
before either acceptance assertion. The final Linux-native evaluation passed in
19m55s. Its raw JSONL SHA-256 is
`31d3892888d68b1fa5015a49ba02e547fdc519e9376327bf9c9a4ccd80aeb41f`.
There are 30 actual rows: 24 distinct questions, two explicit USER resubmissions
(A07 and A10 after citation rejection), and four initial-trial matched replays.
11/24 initial physical drafts passed; 22/24 initial USER submissions passed after
at most one isolated repair, and 24/24 terminal answers passed after the two
explicit USER resubmissions. All 24
initial turns retained the required conditions, including when the answer failed.
114 exact citations (50 user-state citations) passed independent provenance,
owner, revision, source identity and UTF-16 checks. There were 48 physical answer
requests, including 18 single repairs, and 26 auxiliary extractor requests.
Every physical request has reported usage: answer input/output 320547/23677;
extractor input/output 38620/1022. The median initial end-to-end turn was 27046.5ms;
per-completion elapsed fields use a shared turn stopwatch and must not be summed
as independent transport latency. Both restart/isolation and unchanged original
state/transcript checks passed.

Independent Codex AI semantic grading of all actual drafts and accepted claims
scores terminal ordinary answers 39/48 (A 19/24, B 20/24), versus 36/48 for initial
answers. Matched replay scores are A off/on 1/2 and B off/on 0/1. This is a developed
scenario evaluation, not held-out or human grading. Exact quotes do not guarantee
that a claim follows from its source: A05 incorrectly draws a documentation-wide
negative from an undecided USER choice; B07 abstains despite relevant limits;
A04 overstates DST independence; A08 labels a combined cron/user inference as
document-only; B10 omits forgetting/reinforcement details. B replay-off invents a
scheduling goal, and B replay-on recovers conditions but omits requested document
facts. These defects remain disclosed rather than counted as perfect answers.

A separate real-provider seven-input garden probe uses different time/zone,
objective and glossary values. All seven final postconditions passed, including
preserving a compound no-purchases/no-physical-changes restriction when only the
goal changes; the ignored ambiguous update is audited. The probe is narrow
additional evidence, not a universal generalization guarantee. Earlier probe
failures remain preserved.

The completed Android run uses separate sessions in the same default project.
All 24 initial USER sends were admitted, with no explicit USER resends. It uses
24 auxiliary calls and 45 physical answer calls (13 isolated repairs), with
137 independently checked citations: 66 document and 71 USER. Both first whole
replay trials rejected the off answer and accepted the on answer. Each was
explicitly repeated once as a WHOLE pair; both selected sides then passed the
mechanical citation gate. All eight actual replay sides, including failures, are
preserved; original state and the full session record were unchanged immediately
after each trial. Later chat selection updates session metadata only.
Android proves chat isolation; Linux independently checks project and chat
isolation. Independent AI semantic scores are Android A 17/24 and B 19/24,
combined 36/48, distinct from the Linux-native terminal 39/48. Selected replay
scores are A off/on 0/2 and B off/on 0/1. These are developed scenarios, not
held-out accuracy. Actual UI generation has no configured temperature (unlike
native temperature 0); off/on settings are identical and explicitly checked.
Both twelve-question dialogues retain all required conditions across restart.
No replay sides are mixed between trials.

Separate Android semantic review found serious factual contradictions: A01 and
A12 say Android uses WorkManager although their exact Russian source says it is
not used. The first replay-on answer also overstates the unattended limitation.
The second replay-on answer states the scheduler facts correctly, and its off
answer honestly abstains. These original clips are retained; twelve admitted
answers are not labelled twelve factually correct answers. A12 correctly recovers
the USER goal, latest clock/zone, restrictions and undecided choices. Independent
review identifies model-quality errors rather than a newly discovered source,
state or citation-gate bypass; it does not justify perfect factual claims.

## Verified Android recording

Durable video: `/home/kotdath/Videos/domovoy/day-25-demo.mp4`.
H.264, 1080×2400, no audio; duration 3075.204044s;
SHA-256 `9237714bbe1554255dfec98fdb9a3b91ac22b73785255d590ca95f04b20a52cb`.
The 38 whole chronological clips have seekable chapters. Both actual rejected
first replay pairs remain visible, followed by their explicitly repeated whole
pairs. Supplemental real UI history tours show both restart answers, paper
answers and final conditions; they make no model calls. Earlier top-of-chat
viewport positions did not show every new answer immediately. Original clips,
fresh accessibility snapshots, request/source packets and the final playlist
manifest remain in `/home/kotdath/Videos/domovoy/evidence/day-25/`.
Five technical setup/unsent-input/failed supplemental visibility attempts are
excluded with explicit reasons in `day25-final-video-manifest.json`; all are
preserved separately. No actual model failure is excluded. The final MP4 passed
metadata, chapter-count, whole-duration and full decode checks. Android UI and
capture use Orca on the existing emulator. Native automated evaluation and
Android UI generation are separate measurements with their limits above.

## Review policy and limitations

Pi uses `opencode-go/deepseek-v4.1-flash` with authority/source packs and a maximum
of three cycles. Cycles one and two requested fixes; their transcripts and applied
changes are preserved. Cycle three APPROVED the exact implementation and measured
evaluation, with delivery explicitly pending video verification. The final
independent Codex review uses `gpt-6.1-sol` high and
received the assignment, agreed plan, baseline diff and all actual answers/sources.
Final source review APPROVED source `048057f`, with no blocking code finding;
independent Android source/provenance/semantic and video review receipts are
preserved alongside the raw evidence.
Neither model reviewer is labelled as a human expert.

No frozen question/answer lookup or question-ID routing is present in production.
Evaluation expectations are checked only after requests and never enter model
context. Scenario-specific extractor examples (time value, acronym and named
unresolved choices) and the paper-ID UI default were removed after a separate
hardcode audit. Generic schema/lifecycle rules remain. Retrieval thresholds are
measured, frozen calibration artifacts bound to corpus/model hashes, not expected
answers. The day-23 rewriter contains a small name-preservation dictionary: it
only protects matching words already present in the input; it supplies no facts.

Exact quotes and schema do not prove semantic entailment. Derived labeling still
needs semantic review; provider behavior is probabilistic and its server revision
and cache policy are not controlled. Complete provenance is intentionally retained;
full-state JSONL snapshots can grow quadratically in a very long-lived conversation.
Repository CAS assumes one composed writer, matching the existing storage contract.

The day-25 final candidate uses DeepSeek V4 Pro rather than Flash: real Flash
runs exposed format/slot extraction/semantic errors. Earlier days remain evaluated
on their recorded model. Both off/on comparisons use the same chosen Pro model;
this is a declared model choice, not an improvement attributed solely to memory.
Rejected extractor output and a bounded diagnostic failure reason are retained
separately from accepted conditions; private reasoning is never included.
