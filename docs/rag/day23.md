# Day 23 — calibrated filters, query rewrite and neural reranking

Status: implementation, real evaluation, final independent code review and
verified Android demo complete.

Authority: [assignment](assignment.md), [agreed plan](implementation-plan.md),
repository AGENTS.md. Base: `72632525861c157564a62bd75f0107e9970b58af`.
Feature: `feature/day-23`, retained after the challenge merge.
Implementation/evaluation: `f0c44a2` + output-path fix `d27008b`;
backend/negation guards: `9a4be18`; bounds/display: `13841e8`;
final reviewed and built code: `bf592361c5d3d0ed28222cc947bdfbe0e4384189`.

## Implementation

- M1: unchanged raw-query dense top-5 baseline.
- M2: raw-query top-20, calibrated cosine threshold, overlap dedup, max five,
  and the full escaped context budget.
- M3: an isolated DeepSeek rewrite followed by M2. Schema, protected entities,
  numbers and negation occurrence counts are checked. Known platform/product names
  are protected case-insensitively with exact token boundaries; this lexical
  check does not prove general semantic equivalence. Ambiguity, invalid output,
  failure or timeout retains the original with an inspectable fallback reason.
- M4: rewritten-query dense top-20; actual BGE scores every candidate against
  the original user question, then its own raw-logit threshold/dedup/max-five.
  The same query pairing is used in dev calibration, preserving original intent.
- Actual rewrite request/usage/receipt is persisted separately before transport;
  the main answer trace freezes both queries, config, generation, all candidate
  scores/ranks/exclusions, sent IDs, backend usage and timings.
- No tools/actions in document mode. Neutral comparisons omit profile/unrelated
  memory and completed-turn extraction; ordinary chat behavior remains intact.
- UI selects M1–M4, shows the 20→5 pipeline, dense→BGE ranks, original/rewrite,
  exclusions and timing. Manual sliders explicitly mark unverified experiments;
  restore reinstates the frozen corpus/model/strategy-bound calibration.

## Real models and calibration

Qwen `qwen3-embedding:0.6b` on Ollama, normalized 1024 dimensions:
`df2af910c83efd01d39f7ba4012e24bdc1ba98281ad65efff841fd025148279d`.

Official BAAI/bge-reranker-v2-m3 revision
`953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e`:

- Original safetensors: 2,271,071,852 bytes,
  SHA-256 `d9e3e081faff1eefb84019509b2f5558fd74c1a05a2c7db22f74174fcedb5286`.
- Converted F16 GGUF: 1,159,774,656 bytes,
  SHA-256 `0c5784a1f3402d93c42deb0593aaeb38edb08a511d30cde18af84ab64a164a8a`.
- Existing llama.cpp `50f068ffffc3e0e4c9c2e4139281c6075224f429`,
  build `b10679-50f068fff`, Vulkan AMD Radeon 8060S, rank pooling.
- Reranker fingerprint
  `f957e0296c0c54f93096d80bb84aa0326ba4910f400a0b58453467c02a218874`.
- Scale is **raw classifier logit**, not cosine/probability. Gateway verifies
  checksum, backend path/alias/build/context, every HF/backend query/passage token
  ID and special-token pair, processed token sum, stable IDs and finite scores.
  Both model drift and missing-embedding sentinel fail explicitly.

See [gateway reproduction](../../tool/rag_model_service/README.md) and pinned
[models](../../tool/rag_model_service/models.lock.json).

Host-only [dev questions](../../eval/rag/dev_questions.jsonl): four answerable,
four absent from frozen corpus; agent-selected canonical-span labels, not human
assessment. Hash `c04cd94f280049551160febceff861dc0c46366259a1959bdadd6d77569fef33`.
An initial exploratory dev run exposed excessive question copying; the prompt
was developed on dev only, then the final profile was frozen **before** golden.
Both runs are retained externally. No thresholds were retuned on golden.

[Calibration](../../eval/rag/calibration.json), profile
`1f9f5dca5d15ff87125be06cc04bc699f7c9b5f8da2c6d1cd43a9da53997cd28`:

| Cutoff | Threshold | Question F1 | Positive hits | Negative empty | Sent precision |
|---|---:|---:|---:|---:|---:|
| Shared M2/M3 cosine, 16 raw/rewrite samples | 0.5360335140418512 | 0.7692 | 5/8 | 8/8 | 7/22 |
| M4 BGE raw logit, eight samples | -1.090676486492157 | 0.8889 | 4/4 | 3/4 | 5/11 |

Objective: question F1, then sent-passage precision, then higher threshold.
Dev relevance: at least 50% overlap with a selected canonical unit. This is
looser than the golden full-span union metric. BGE's one dev false positive and
three dense positive misses are retained findings, not hidden improvements.
Production metadata equals the committed JSON; bounds clipping was separately
recomputed on real saved dev scores and leaves all frozen statistics unchanged.

## Ten questions, four actual ablations

The original [golden set](../../eval/rag/golden_questions.jsonl) is unchanged,
host-only and never part of assets/model input. Real native Linux runs used fresh
sessions, the same fixed 128-chunk frozen 12-document index and DeepSeek Flash,
temperature 0, reasoning disabled, output max 2048; tools/profile/unrelated memory
were disabled. Forty answer requests plus twenty isolated rewrite requests.

| Mode | Candidate canonical hit | Sent canonical Hit@5 | Sent full units | Q10 sources | Median total ms | Answer input/output tokens | Rewrite input/output |
|---|---:|---:|---:|---:|---:|---:|---:|
| M1 | 8/9 | 8/9 | 15/17 | 5 | 4924 | 29283/3702 | 0/0 |
| M2 | 9/9 | 5/9 | 9/17 | 0 | 4976 | 15159/3322 | 0/0 |
| M3 | 9/9 | 4/9 | 6/17 | 0 | 6366.5 | 13399/3590 | 1781/279 |
| M4 | 9/9 | 6/9 | 11/17 | 0 | 8894 | 15743/3344 | 1781/277 |

Provider-reported inclusive input/output totals are counted without double-counting
cache hits. BGE processed 74,184 tokens for the ten main M4 pools. M3 rewrites
changed 8/10 queries, with protected-term fallback on Q06/Q09; M4 changed 9/10,
with Q06 fallback. These are real separate calls, not a reused invented rewrite.

Top-20 increases candidate recall; thresholds discard useful passages as well as
noise. M4 improves sent coverage over M3 but does not beat M1 on the canonical
metric. This metric is a lower bound: equivalent sections can support correct
answers without containing the chosen full canonical spans. Independent semantic
scores below use the actual sent passages independently of this metric. Empty retrieval in day 23 still calls the answer model; the
host-authored zero-model abstention belongs to day 24.

Single answers per question/variant; provider caching, server model revision and
ambient load are uncontrolled. Timings are measured totals, not a speedup claim.
The forty-answer harness compiled `d27008b`; a CLI code-revision metadata typo
(`a6b4e82`) is explicitly corrected by the retained source-provenance sidecar.
Later guards did not alter measured behavior: the final gateway recomputed all
10 golden and all eight dev pools with identical scores/usage, and the stricter
rewrite guard leaves all 17 successful rewrites unchanged. Original results and
all validation audits are preserved.

## Independent semantic grades

| Mode | Score /20 | Correct / partial / wrong or known refusal | Unsupported assertions |
|---|---:|---:|---:|
| M1 | 19 | 9 / 1 / 0 | 0 |
| M2 | 18 | 8 / 2 / 0 | 7 |
| M3 | 14 | 6 / 2 / 2 | 6 |
| M4 | 17 | 8 / 1 / 1 | 4 |

Q02 omits host scope/ID ownership in every mode. M2/M4 additionally distort the
explicit user-confirmation promotion rule. M2 Q04 invents visibility behavior;
M3/M4 refuse the known Q04 after filtering. M3 refuses Q05's known limits,
whereas M4 recovers them. Q01/Q03 equivalent selected passages and all Q06–Q09
are supported and correct. Unknown Q10: M1/M2/M4 truthfully admit missing
measurements; M3 invents an attribution to benchmark documents, so is partial.
A true project fact absent from that request's passages counts as unsupported;
explicitly general measurement advice does not. Full per-answer reasons and
examples are preserved in external `codex-answer-grades.json`.

No mode beats M1 in this run. M4 recovers some M3 losses and filtering removes
Q10's irrelevant sources, at increased latency and with remaining regressions.
These findings were not used to retune the frozen dev thresholds or alter golden.

## Checks and reviews

`dart format .`: 571 files, zero changes. `flutter analyze`: clean.
`flutter test`: 1441 passed, four platform skips. Android debug and Linux debug
builds pass at `bf59236`. Real native Linux dev and forty-answer tests pass.
Python gateway tests cover token mismatch, processed-token mismatch, limits,
invalid/unknown/duplicate IDs, booleans, nonfinite scores and backend sentinel.

Pi `opencode-go/deepseek-v4.1-flash`, three cycles: first required trace/UI fixes;
second APPROVE CODE; third APPROVE code. Corpus/tokenizer configuration distinction,
original-query BGE pairing and real precision/recall regressions were documented.
The final minor cosine-boundary and null-rank display findings were fixed.
Final Codex `gpt-6.1-sol high`: APPROVE code at `bf59236`. Its one P2
lowercase/platform-prefix rewrite finding was fixed and tested; the final guard
audit retains all 17 successful measured rewrites and three original fallbacks.
All forty actual answers were graded independently against sent evidence.

## External evidence and demo

Evidence directory: `/home/kotdath/Videos/domovoy/evidence/day-23/`.
Includes both dev runs/requests/profiles, forty-answer JSONL/config, provenance,
real model probe, final gateway golden/dev audits, rewrite/calibration audits,
check/build logs and all pi review packs/results. Weights/environments/PDFs,
credentials and videos stay outside Git.

Verified demo: `/home/kotdath/Videos/domovoy/day-23-demo.mp4`.
H.264, 1080×2400, video only, 467.359122 seconds, 51,994,042 bytes.
SHA-256 `563d45ff0e4d34add33b969a1400aaa53495b1713de5b18f055852d1d75c10dd`.
Recorded the reviewed APK at `bf59236` on the existing Orca-attached
`emulator-5554`, with all interaction and recorder control through Orca CLI.
Six complete original clips are retained; only complete successful workflows
were concatenated, with Android metadata tracks removed and no audio.
Start, original/rewrite, exclusions/rank-change, threshold and final frames were
inspected; final frame shows the restored live answer and three sources.

| Fresh live chat | Candidates | Sent sources | Observable result |
|---|---:|---:|---|
| M1 | 5 | 5 | Correct 4000/2500 and four mandatory USER.md sections |
| M2 | 20 | 1 | Useful personalization passage excluded; truthful missing limits |
| M3 | 20 | 1 | Compact rewritten query visible; useful passage excluded |
| M4 | 20 | 3 | Personalization dense #2/#4 → rerank #1/#2; correct limits/sections |
| M4 manual raw-logit cutoff 15 | 20 | 0 | All excluded; missing-evidence answer |
| M4 restore cutoff -1.090676486492157 | 20 | 3 | Bound profile restored; correct limits/sections again |

All six used separate new sessions and the same English limits question,
DeepSeek Flash, reasoning disabled, max output 2048, temperature unspecified
identically, zero tools/continuations, one user message and neutral comparison.
Persisted real requests/receipts, model usage, actual candidates and empty/restore
conditions were verified from a narrow Android RAG-store archive, including its
active generations and payload hashes. No unrelated application data was archived.
External `android-demo-proof.json`, `android-recorded-traces.json`,
`final-code-validation.json`, `recordings.json` and `verified-video.json` bind
these claims to code, APK hash, traces and native/final recordings.
The unknown answer here is still an actual cloud call; zero-model host abstention
is the next stage. The demo reports real quality regressions rather than claiming
that every added retrieval step improves every question.
