# Day 21 — live local indexes

Implemented code: `4286da66e68e6a6b240f0a291392f85ba952def1`.
Baseline: `f1590845e161098413bbe5074679df3d8e5add68`.
Authority: [assignment](assignment.md), [agreed plan](implementation-plan.md),
repository AGENTS.md. Days 22–25 are separate cumulative deliveries.

## Reproduce

1. Follow `tool/rag_model_service/README.md`: install the locked dependencies
   outside the repository, prepare the pinned tokenizers, start Ollama with
   `qwen3-embedding:0.6b`, then start the gateway on loopback port 8765.
2. Android: `adb reverse tcp:8765 tcp:8765`, build/install the debug APK and
   launch `ru.kotdath.domovoy`. Linux: `flutter run -d linux`.
3. Open **База знаний**, import **Документы Domovoy**, build Fixed and Structure
   independently, search, inspect chunks and **Сравнить стратегии**. Restart:
   both generation pointers persist. Start a rebuild and cancel: old index stays.
4. In the separate arXiv corpus import `2310.08560`, open its original PDF,
   add a new text document in the UI, and build its index live.

No precomputed vectors or canned model results are application assets. The frozen
12-document corpus matches baseline hashes: 125494 UTF-16 characters, 69.7
conditional pages (1800 characters/page). Plans, evaluation and conversations
are excluded. Indexing, retrieval and persistence run in Dart on the device;
the gateway only tokenizes/embeds. No answer-quality claim is made in this stage.

## Measured Android run

Both strategies: 384 embedding tokens, 64 overlap, 1024 dimensions. Embedding
fingerprint: `df2af910c83efd01d39f7ba4012e24bdc1ba98281ad65efff841fd025148279d`.
Matching pinned BGE tokenizer also bounds passages for the later reranker.

| Metric | Fixed | Structure |
|---|---:|---:|
| Chunks | 128 | 178 |
| Mean tokens | 367.93 | 243.37 |
| Min–max tokens | 68–384 | 4–384 |
| Repeated UTF-16 characters | 23262 | 10982 |
| Forced cuts inside structural blocks | N/A | 42 |
| Persisted JSONL bytes | 3251516 | 4359480 |
| Indexing milliseconds | 26364 | 31620 |
| Generation prefix | 71560bd214b6 | abded2093ac5 |

The same live query “Какие слои памяти есть в Domovoy?” and one query vector
produce separate top-5 lists shown in the recording. Fixed's first result is
README.md, cosine 0.5994; Structure includes README's Memory section and
architecture's Boundaries section. These are retrieval probes, not an evaluation
of generated answers. Small floating-point variation between live queries and
JSONL re-encoding after vector normalization is expected; stored byte counts
above are read from the captured native files.

MemGPT imported from `https://arxiv.org/pdf/2310.08560v2`: exact metadata title
**MemGPT: Towards LLMs as Operating Systems**, 13 physical PDF pages, 56938
extracted characters, original file 663708 bytes, binary SHA-256
`9f674bcff69c86f11c813dcfad613d8841f5f8ed17979e3c4df06a91df7762e0`.
Together with the 110-character **Live recording document**, this separate
corpus produced 62 structural chunks in 13422 ms, generation `1d2fac9ec651…`.
The retained original PDF is rendered in the native viewer during the demo.

## Validation and review

- `dart format .`: complete; `flutter analyze`: no issues.
- `flutter test`: 1421 passed, 4 skipped; targeted RAG suite: 20 passed.
- Android debug x64 build and Linux build passed.
- Native Linux integration test uses the actual gateway and visible Flutter UI:
  12 documents → both indexes → real search → persisted generations reopened.
- Pi, exact `opencode-go/deepseek-v4.1-flash`: three attempts. First findings
  fixed; second timed out and does not count as approval; third approved with
  follow-ups. Fixed full-path/manual-content identity collisions, added live
  comparison probes and declared-tokenizer-limit drift rejection. Text import
  deliberately rejects a malformed UTF-8 batch atomically with a clear error.
- Final Codex `gpt-6.1-sol`, high: approved after fixing and re-reviewing two P2
  issues (failed corpus load leaking previous scope; footer-only empty JSONL).
  Both have regression coverage. Every reviewer received the assignment and
  agreed plan as sources of truth. No unresolved correctness blocker remains.

Evidence/logs/reviewer outputs and the captured indexes are retained outside Git:
`/home/kotdath/Videos/domovoy/evidence/day-21/`.

## Verified video

`/home/kotdath/Videos/domovoy/day-21-demo.mp4` — MP4/H.264, 287.611 seconds,
1080×2400, video only, SHA-256
`2c725214a842a4ea06e479ed70e516b909dd2d8411e9a1448d310ccc0abf310e`.

Orca controls the attached Android emulator. Detached `screenrecord` is started
through scoped `orca-ide emulator exec`, its output growth is checked, then it is
stopped in cleanup and pulled to disk. The final file concatenates complete native
recordings `day21-final-a.mp4` (133.389 s) and `day21-final-b2.mp4` (154.222 s),
without cutting failed actions out of either successful run. Start, comparison,
PDF and final frames were visually inspected; ffprobe confirms one video stream.

Part A proves empty corpus, live import and both builds, chunk metadata and search
comparison. Part B proves structural statistics, restart persistence, cancelled
rebuild safety, fresh HTTP PDF import/viewing and live indexing of text entered
during recording. The PDF already existed from the first B rehearsal; final B
downloads/extracts it again and exercises idempotent import.

Earlier minute-limited foreground recording probes and `day21-partial-b.mp4`
(UI driver failed to locate an unlabeled empty EditText) are preserved as partial
runs and are **not included in the delivery video**. The driver was corrected to
derive editable-field coordinates from fresh accessibility state.

PDF extraction requires a text layer; OCR is out of scope. PDF structure is a
section/paragraph heuristic, including subdivision of oversized blocks. This is
explicit in chunk metadata; semantic boundaries are not guaranteed for arbitrary
PDF layouts.
