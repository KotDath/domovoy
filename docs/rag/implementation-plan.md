# Domovoy RAG: agreed implementation plan, days 21–25

## Authority and delivery

The assignment snapshot in `assignment.md`, repository `AGENTS.md`, and the
user decisions below are authoritative. `prototype.md` is the original detailed
design, updated by this plan where they differ. Reviewers MUST read the assignment,
this file, and the day's diff against its baseline before reviewing.

Implement five cumulative stages on retained `feature/day-21` through
`feature/day-25` branches, each starting from the latest `challenge`. Per stage:
implementation → formatting/analyze/tests/builds/live Android and Linux checks →
up to three pi reviews/fixes → final Codex review/fixes → verified Android demo →
commit/push feature → merge commit/push challenge. Do not wait for user input or
reviewer agreement after three pi cycles. Record residual findings and continue;
actual failed functionality, checks or demos must be fixed autonomously.

pi reviewer: `opencode-go/deepseek-v4.1-flash`, read-only tools. Final reviewer:
Codex `gpt-6.1-sol`, reasoning effort `high`, read-only. Supply both reviewers
assignment, this plan, stage number, base commit, diff, validation and evidence.

Save final demos as `~/Videos/domovoy/day-21-demo.mp4` through
`day-25-demo.mp4`, retaining source recordings/evidence. Videos/weights/secrets
are not repository artifacts. Each stage report records commit, reproduction,
checks, measured evaluation, review findings and video path/checksum. Complete
the active goal only after all five remote branches, merges and demos are verified.

## Shared architecture and models

Keep one Flutter package, ChangeNotifier, composition in `lib/app.dart`, layered
dependencies, conditional IO adapters and existing session/memory contracts.
RAG domain contracts live in core/rag; HTTP/PDF/JSONL adapters in infrastructure;
controllers/UI in features. Documents are not existing research-library records
or working/long-term memory. Web may explicitly report unsupported persistence
while continuing to compile. Android and Linux are required.

Flutter/Dart implements import orchestration, normalization, chunk boundaries,
indexing, cosine search, filters/dedup/budget, context assembly and evidence
validation. Local inference service only computes tokens/vectors/pair scores;
it neither stores corpora nor performs retrieval. Preserve prototype health,
tokenize, embeddings and rerank contracts with stable item IDs/fingerprints.

Answers, isolated query rewrite and task-state extraction use cloud DeepSeek via
the existing provider registry. Resolve and freeze an available model ID and
sampling configuration for each comparison. Use DEEPSEEK_API_KEY on Linux;
provision Android's existing secure storage before capture, never compile the key
into the app, record it, or print it.

Embeddings: installed `qwen3-embedding:0.6b` on Ollama. Use Qwen's documented query
instruction, normalize/check vectors and set truncate=false. Preserve exact
model digest, tokenizer revision, dimension, templates/pooling in fingerprint.
llama.cpp embeddings are the fallback only if Ollama actually cannot work;
different fingerprints require rebuilding, never silently mixing vectors.

Neural reranker: BAAI/bge-reranker-v2-m3 served by existing llama.cpp, with pinned
source revision, GGUF/checksum. Keep cosine and reranker score scales distinct;
calibrate the actual returned score scale. Use the BGE v2-m3 8192-token pair
budget (1024 query + four special tokens reserved), checked with its tokenizer.
Tokenization uses pinned matching
tokenizers, declared codepoint offsets converted to Dart UTF-16. Validate lengths
without silent truncation. Model gateway listens on host loopback; use adb reverse
for Android. Weights and virtual environments stay outside Git.

## Corpus, storage and UI

Main corpus: the prototype's explicit 12-file Domovoy documentation allowlist,
frozen at the baseline revision with content hashes. Show actual text volume;
label conditional pages as characters/1800, not physical pages. Exclude this
plan, assignment, evaluation, conversations, secrets and build data from corpus.

Separate arXiv corpus: MemGPT (2310.08560), MemoryBank (2305.10250), Generative
Agents (2304.03442). Support Markdown/TXT, local text-layer PDFs and arXiv ID/URL.
Extract PDFs page by page with pdfrx, preserving source PDF, text, pages, title,
source URL/revision. OCR is out of scope. Downloaded PDFs are local data, not
committed third-party assets; use a URL/revision/hash manifest for reproduction.

Normalize BOM and line endings while preserving exact quoteable slices. Stable
SHA-256 chunk IDs include document revision, strategy/config and coordinates.
Persist independent versioned JSONL corpus/index/trace/task-state namespaces.
Publish only validated complete index generations atomically; cancellation or
failure leaves the old generation active. Historical evidence resolves to the
document revision used for that answer, including after document replacement.

Add Knowledge Base navigation, document/chunk viewer and chunking comparison.
Chat mode Ordinary / By documents, corpus/strategy selector, source cards and RAG
inspector; compact pages/bottom sheets on Android, side panel on desktop.
Comparison UI exposes real configs, original/rewrite query, every candidate,
scores/reasons, sent evidence, timing, validation and model usage.

Prepare retrieval once per user turn before session.run; freeze project/session,
index/config/state revisions and request ID before awaits. Agent run options gain
generic prepared context without importing RAG into agent runtime. Reserve total
provider budget including transcript, profile and memory. Cancellation/chat
switch discards stale work. Document mode forbids tools/MCP/actions. Retrieved
documents are untrusted evidence, not instructions. Persist immutable trace/
evidence before linking the accepted message; don't persist private reasoning.

## Day 21 — two local indexes

Implement live import/tokenize/chunk/embed/validate/atomic publish and local
cosine search. Fixed chunking: target 384 model tokens, overlap 64, per document.
Structural: headings/paragraphs/lists/tables/code blocks, same token target;
subdivide oversized blocks with mapped coordinates. PDF structure uses sections/
paragraphs/pages. Respect both embedding and reranker input length constraints.
Keep both indexes selectable without rebuilding. Compare chunk count/length,
overlap, structural splits, index bytes, actual indexing time and search probes.

Demo: empty knowledge base → import frozen docs → fixed live index/chunk metadata
→ structure live index/boundaries/stats → restart and both indexes persist →
arXiv PDF and newly added non-asset document indexed live. Interrupted rebuild
doesn't damage previous index. No answer-quality claims yet.

## Day 22 — first RAG and ten questions

RagTurnCoordinator prepares query embedding → local top-5 → bounded context →
DeepSeek. Extend run options with generic prepared ephemeral context. Modes M0
(no RAG) and M1 (raw query dense top-5) have separate clean sessions, identical
generator/settings, neutral profile and disabled unrelated memory in evaluation.
Persist actual request evidence and audit; source cards at this stage aren't
labelled validated quotations.

Reproduce prototype Q01–Q10, nine answerable plus unknown benchmark, with expected
facts, forbidden errors and revision-aware evidence spans (not strategy-specific
chunk IDs). Golden answers are never generator input or corpus. Evaluate both
chunkers, Hit@5/evidence recall, answer score, unsupported assertions and timings.
Demo paired live no-RAG/RAG answers and inspect real context; report all ten.

## Day 23 — filter, rewrite, reranking

M2: raw query → dense top-20 → threshold → max 5. M3: isolated validated query
rewrite → M2. M4: rewrite → dense candidates → neural rerank → calibrated final
threshold → max 5. Rewrite preserves entities/numbers/negation; invalid/failed
rewrite falls back to original with visible reason. Dedup overlapping evidence
and respect full context budget. No silent reranker failure/fake scores.

Separate dev set: four answerable and four confirmed unanswerable questions.
Calibrate thresholds there, pin profile/config and then evaluate ten golden
questions without retuning. Show ablations M1–M4 and improvements AND regressions.
Demo candidate pool/filter exclusions, original/rewrite, reranker reordering,
empty results at raised threshold and restoring calibration.

Stage-23 comparison uses the fixed index (day-22 score tied at 19/20, with better
canonical-span recall than the structural index). M2/M3 share one dense cutoff
calibrated jointly on raw and rewritten dev queries; M4 calibrates its own raw
BGE logit cutoff. The reranker scores the original user question against all
twenty rewritten-query candidates, preserving the original intent if the rewrite
loses nuance. Calibration uses this same pairing. Record this choice when
interpreting M3→M4 deltas; it is not an additional query-pairing ablation.
Choose dev cutoffs by question F1, then sent-passage precision, then the higher
cutoff; labels use agent-selected canonical spans with at least 50% overlap.
The ten-question evaluation retains the stricter full-span coverage metric.
Manual threshold controls explicitly label an uncalibrated experiment and permit
other corpora; restoring calibration restores its bound strategy and model checks.

## Day 24 — citations and abstention before persistence

Model returns strict status answered/partial/abstained plus claims with chunk IDs
and exact quotations. Host supplies metadata and validates schema, current sent
evidence IDs, exact quote substring/coordinates/revision and evidence per factual
claim. Add generic optional AgentFinalAnswerGate BEFORE assistant finalization,
checkpoint or memory extraction. Buffer strict-mode draft; ordinary streaming
continues unchanged. At most one isolated repair attempt, recorded usage/time.

No relevant evidence: generic RespondWithoutModel persists user and host-authored
abstention with clarification, empty sources/quotes, reason insufficient_evidence.
Infrastructure/validation failures are distinct from absence of knowledge.
Persist rejected drafts only in labelled diagnostics, never accepted transcript.
Automatic quote validity is not semantic proof: evaluate all ten against ground
truth, with agent expert review, never label it "checked by a human".

Demo supported answer/source/highlight, unknown question/refusal/trace and clearly
marked fault-injection false ID/quote rejected, absent from accepted history on
restart. Substantive accepted answers require real evidence; abstention must not
invent sources merely to satisfy the output format.

## Day 25 — automatic dialogue task state

Separate per-(project,session) JSONL state: goal, constraints, glossary,
clarifications/open questions, revisions, provenance and superseded values.
User chose AUTOMATIC application of validated extractor patches from user
messages; no manual approval gate. Show updates/diff and permit manual editing.
Do not label auto-extracted state as manually confirmed existing memory.
Documents/assistant/tool output cannot write user task conditions. CAS prevents
late extractor overwriting newer edits; unknown/ambiguous facts stay unknown.

Each turn uses frozen task-state snapshot for rewrite/answer and fresh retrieval.
User-message/state evidence and derived claims are distinct from document quotes;
validate source scope and revision. Keep state independent of compaction.

Expand prototype scenarios A (morning digest on Android, discussion only) and B
(project memory/settings) to TWELVE user questions plus answers EACH. Include
topic diversion, changing 09:00→08:30, restart, goal/constraints recovery, new
sources and other-project/chat isolation. Diagnostic state-on/off replay uses
identical last two messages, no earlier summary/leaking profiles, same settings.
Do not fabricate a bad memory-off answer if it actually succeeds.

## Verification and recording

Mirrored unit/widget/integration tests: Unicode offsets, chunking large blocks,
stable IDs/import idempotency, malformed/mismatched vectors, atomic failure and
cancellation, cosine order/topK/threshold, rewrite fallback, actual request/tool
disable/budget, stale results, forged citations, persistence and state isolation.
Fake tests are deterministic; real-model quality and device checks are separate.
Run required Flutter checks and Android/Linux builds before each day's delivery.

Drive real visible UI, record Android capture (adb screenrecord segments where
necessary), verify start/growing file and stop in cleanup. No audio unless asked.
Use actual HTTP, no canned answers/cache pretending to be live. Clearly label
fault-injection/replay. Validate ffprobe/video duration/resolution and meaningful
start/end/proof frames; preserve originals, no edit hiding failed assertions.
Document before/after configuration and reviewed/recorded code commit.

## References

- Prototype retained as prototype.md; requirements retained as assignment.md.
- https://docs.ollama.com/api/embed
- https://huggingface.co/Qwen/Qwen3-Embedding-0.6B
- https://huggingface.co/BAAI/bge-reranker-v2-m3
- https://pub.dev/documentation/pdfrx/latest/pdfrx/PdfPage/loadText.html
- Existing llama.cpp tools/server/README.md: /reranking and aliases.
