# Day 25 — automatic dialogue task state

Authority: [agreed plan](implementation-plan.md), [assignment](assignment.md).
Baseline: challenge `52c8ab5fd51856b8c90c9f348ef5f0ed1391ab20`.
Implementation/evaluation source: full SHA recorded in final evaluation config.
Delivery verification is in progress; this document will be finalized from actual
receipts and video checks before publishing the branch.

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

Full deterministic suite: 1494 passed, four pre-existing skips. Android/Linux debug
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
before either acceptance assertion. Full final real evaluation, expert grading,
review receipts and recording sign-off are pending at this draft stage.

## Review policy and limitations

Pi uses `opencode-go/deepseek-v4.1-flash` with authority/source packs and a maximum
of three cycles. Cycles one and two requested fixes; their transcripts and applied
changes are preserved. Final independent Codex review uses `gpt-6.1-sol` high and
receives the assignment, agreed plan, baseline diff and all actual answers/sources.
Neither model reviewer is labelled as a human expert.

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
