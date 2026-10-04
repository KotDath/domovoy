# Day 22 — first RAG and ten questions

Implemented/recorded code: `e5dcab3` (plus implementation commit `7127540`).
Baseline: `0ee9f197ee96e8693c2316925e62f684a5792f78`.
Authority: [assignment](assignment.md), [agreed plan](implementation-plan.md),
AGENTS.md. Days 23–25 are separate cumulative deliveries.

## Reproduce

Start the actual local gateway/Ollama as described in
`tool/rag_model_service/README.md`. Android uses `adb reverse tcp:8765 tcp:8765`.
Import the frozen twelve Domovoy documents and build both indexes in Knowledge
Base. Configure a real DeepSeek credential via secure storage (Android) or
DEEPSEEK_API_KEY (Linux), then select the available `deepseek-flash` model.

Chat exposes Ordinary / By documents, corpus and chunking strategy. Sources
opens the inspector with every candidate, exact immutable text/revision/coordinates,
cosine, budget, actual system prompt/history, request hash, timing, provider usage
and accepted message identity. These source cards are explicitly **unvalidated
retrieval provenance**. The stricter citation gate belongs to day 24.

For a comparison, enable Neutral comparison and use fresh independent chats
with identical model/settings. M0 does not read an index or embed the query;
M1 embeds the raw query and selects local dense top5. Profile and unrelated
memory are omitted in neutral evaluation, including the memory extraction
callback. Ordinary RAG preserves that callback. Both comparison modes forbid
tools; retrieval is prepared once before admitting the user turn. Full request
UTF8 bytes, transcript, dynamic context and reserved output are budgeted.
This bound is conservative and is not an exact provider tokenizer count.

Immutable source/request JSONL is awaited before each physical transport
attempt. Completion receipts correlate the invocation ledger's accepted identity.
A request-write failure blocks the model; a receipt-write failure keeps an accepted
answer and exposes a warning. Restart shows historical saved slices without
retrieving again against a changed index. Private reasoning is omitted from traces.

## Real native Linux evaluation

`integration_test/day22_live_io_test.dart` runs the production provider/runtime,
controllers and visible Flutter chat with actual local embeddings and cloud answers.
Example (output must be new, preserving earlier runs):

```sh
flutter test integration_test/day22_live_io_test.dart -d linux \
  --dart-define=RAG_EVAL_CODE_REVISION=e5dcab3 \
  --dart-define=RAG_EVAL_OUTPUT=/absolute/new-evaluation.jsonl
```

The retained measured run is at intermediate `7127540`, with harness startup/theme
fixes; later changes concern receipt warnings, normal memory callbacks, typed span
metrics and Android support-parent alias handling. Its actual configuration and all
30 raw answers/traces are preserved externally. Golden questions/facts/spans in
`eval/rag/golden_questions.jsonl` never enter application assets or model input.

Frozen generator: `deepseek-flash`, temperature0, reasoning disabled, maxOutput2048.
Each of ten questions has a fresh session for M0, M1 fixed and M1 structure;
no prior messages, profile, unrelated memory or tools. One answer per combination.
Provider cache and server model revision were not controlled/exposed.

| Metric | M0 | M1 fixed | M1 structure |
|---|---:|---:|---:|
| Canonical Hit@5, nine answerable questions | N/A | 8/9 | 6/9 |
| Canonical evidence units fully covered | N/A | 15/17 | 11/17 |
| Agent-assessed answer score /20 | 2 | 19 | 19 |
| Answers with material unsupported assertions | 4/10 | 0/10 | 0/10 |
| Median total milliseconds | 3350.5 | 3751 | 5487.5 |
| Mean total milliseconds | 3787 | 3969 | 5767 |
| Total input/output tokens | 1184/3455 | 29283/3847 | 21016/3718 |

Exact canonical source spans are a lower bound: alternative sections sometimes
contain equivalent facts. Structural Q01/Q04 answers are correct despite missing
the canonical span. Both RAG Q02 answers omit validation/host ownership details.
Q10 has no benchmark evidence: both RAG runs abstained; M0 declined numbers but
invented references to benchmark material. Raw M1 still retrieves unrelated chunks
for Q10, so the observed refusal is not a guaranteed abstention mechanism.

| Question | Subject | M0 | Fixed | Structure |
|---|---|---:|---:|---:|
| Q01 | Existing memory layers/scopes | 0 | 2 | 2 |
| Q02 | Candidate confirmation/validation | 1 | 1 | 1 |
| Q03 | Long-term fact/context limits | 0 | 2 | 2 |
| Q04 | Disabling memory context | 0 | 2 | 2 |
| Q05 | SOUL.md/USER.md limits/sections | 0 | 2 | 2 |
| Q06 | Android schedule/catch-up | 0 | 2 | 2 |
| Q07 | DST handling | 0 | 2 | 2 |
| Q08 | Scheduled task tool restrictions | 0 | 2 | 2 |
| Q09 | Android MCP transport | 0 | 2 | 2 |
| Q10 | Unknown Galaxy A54 p95 benchmark | 1 | 2 | 2 |

Rubric:0 inadequate/wrong,1 partial,2 all required facts without material forbidden
errors. Root agent and independent Codex reviewer agree on all30 grades; this is
**agent assessment, not human review**. The run does not establish statistical
superiority or intrinsic speed of one chunker. Actual source generations,
fingerprints, corpus revisions, usage and timings are in the retained config/traces.

## Checks and review

Format complete; analyze clean; full suite1434passed/4skipped. Focused cancellation,
receipt-failure, memory callback, serialized span coverage and trusted-parent alias/
malicious leaf-link regressions pass. Android debug x64 build and actual native
Linux evaluation/build pass. Latest wording-only receipt warning change has focused
regression coverage and the recorded APK was rebuilt after it.

Pi exact `opencode-go/deepseek-v4.1-flash`: cycle1 timed out (no approval), cycle2
findings fixed, cycle3 APPROVE. Its suspected serializer mismatch was disproved
by inspecting the actual serializer and independently recomputing all metrics;
typed span deserialization and positive coverage regressions now enforce the
contract. Final separate Codex `gpt-6.1-sol` high APPROVE; it independently graded
all30 answers and recomputed all canonical coverage metrics. Both reviewers read
the assignment and final plan. No unresolved correctness blocker remains.

Android's existing trusted app-support path alias (/data/user/0 → /data/data)
previously caused root validation to deny a real project directory, preventing new
chats. The parent is now canonicalized, with leaf/root symlink rejection retained.
The real UI creates fresh chats after this fix; existing chats/data were preserved.

Non-blocking follow-ups: generic future settlement observers should isolate their
own failures; a crash between durable request and trace-list publication can leave
an invisible orphan (transport still blocked); exhausting the context budget needs
clearer UI guidance. No stage22 anti-hallucination guarantee is asserted.

## Video and evidence

`/home/kotdath/Videos/domovoy/day-22-demo.mp4`: H264, 1080×2400, 229.110 seconds,
video only, 34219052 bytes, SHA256
`81cd05a45c98dd014cf4c66ba7dc610c87a8bf2255bf865052385104e1da0bee`.

Orca controls the attached emulator, including scoped detached screenrecord.
The final file concatenates complete successful native recordings A (131.797s),
B (77.772s), C2 (19.540s), without cuts hiding failures. Start, actual answer,
source/context and final proof frames were inspected. ffprobe confirms one video
stream and no audio. C2 shows the relevant personalization passage and its actual
4000/2500 character limits/mandatory sections after restart.

The live pair uses an English translation of Q05 because Orca Android typing
supports ASCII. Separate fresh chats use identical DeepSeek Flash generation:
reasoning disabled, maxOutput2048, unspecified temperature (provider default),
zero tools, one user message, neutral evaluation. M0 declines unverified numeric
limits; M1 fixed answers correctly from five actual retrieved chunks. M0 full
request1126 bytes, total13181ms; M1 request12898 bytes, preparation1343ms,
total5121ms. This illustrative timing pair is separate from the thirty-answer
Linux temperature0 protocol. Paired request/receipt data was independently read
from the native JSONL, checksum-validated, and saved as recorded-paired-traces.json.
The video shows real source IDs/revision/text, actual sent context and the same
accepted-message receipt after force-stop/relaunch.

An earlier C source-view driver asserted unformatted `4000` against the actual
`4,000` document spelling. It is retained as day22-partial-c.mp4 with its failed
log, excluded from final delivery. C2 corrects the assertion and completes the
same real source-view workflow. Unrecorded setup rehearsals are not represented
as recorded demonstrations.
All raw evaluation, builds, review outputs, independent grades and native recordings:
`/home/kotdath/Videos/domovoy/evidence/day-22/`.
