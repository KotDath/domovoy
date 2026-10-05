# Local inference gateway

Run from the repository root. Python 3.12 and Ollama are required. The Flutter
app stores documents/indexes on-device; this service only tokenizes and computes
vectors. All package/tokenizer revisions are pinned. No API key is used here.

```sh
uv venv --python python3.12 ~/.local/share/domovoy-rag/venv
uv pip install --python ~/.local/share/domovoy-rag/venv/bin/python -r tool/rag_model_service/requirements.lock
~/.local/share/domovoy-rag/venv/bin/python tool/rag_model_service/prepare_tokenizers.py
ollama pull qwen3-embedding:0.6b
~/.local/share/domovoy-rag/venv/bin/python -m uvicorn app:app --app-dir tool/rag_model_service --host 127.0.0.1 --port 8765 --no-access-log
```

On Android, connect the booted device with Orca and run `adb reverse tcp:8765
tcp:8765`. Debug builds use `http://127.0.0.1:8765`; a release requires a reachable
HTTPS endpoint and `--dart-define=RAG_MODEL_BASE_URL=https://your-endpoint/` at
build time. The default release HTTPS localhost endpoint fails visibly when no
service is configured, while ordinary chat remains available.

`GET /health` declares digest, fingerprints, dimension and limits. Tokenization
uses pinned HF fast tokenizers with codepoint offsets, converted to Dart UTF-16.
Qwen query instructions are applied only to queries. Passage vectors are
normalized, 1024-dimensional. Requests explicitly disable Ollama truncation.
The app verifies IDs/dimensions/fingerprints and rejects stale indexes after
model replacement. BGE v2-m3 pair budget is 8192 tokens: indexing reserves 1024
query tokens and four specials and checks passage lengths with its tokenizer.
Day 21 only needs the reranker tokenizer. Day 23 also requires the actual
reranker backend described below.

`requirements.lock` includes transitive dependencies; environments, HF caches,
Ollama weights and downloaded third-party PDFs stay outside Git. Service binds
to loopback and disables proxy environment inheritance and request access logs.

## Day-23 BGE backend

Download the `BAAI/bge-reranker-v2-m3` snapshot at the revision in
`models.lock.json` into an external model directory, including configuration,
tokenizer and `model.safetensors`. Verify its SHA-256 against
`reranker_runtime.source_safetensors_sha256`. The measured setup uses Python
3.12, CPU torch 2.11.0, transformers 4.57.6 and the existing llama.cpp checkout
at `reranker_runtime.llama_cpp_commit` (build `b10679-50f068fff`). Convert with
that checkout's dependencies and `convert_hf_to_gguf.py`:

```sh
python convert_hf_to_gguf.py /external/bge-reranker-v2-m3-hf \
  --outtype f16 --outfile /external/bge-reranker-v2-m3-f16.gguf
sha256sum /external/bge-reranker-v2-m3-f16.gguf
llama-server --model /external/bge-reranker-v2-m3-f16.gguf \
  --embedding --pooling rank --reranking \
  --alias bge-reranker-v2-m3-0c5784a1f340 \
  --host 127.0.0.1 --port 8766 --ctx-size 8192 --parallel 1 \
  --batch-size 8192 --ubatch-size 8192 --threads 8 --gpu-layers 99
RAG_RERANK_MODEL_PATH=/external/bge-reranker-v2-m3-f16.gguf \
  ~/.local/share/domovoy-rag/venv/bin/python -m uvicorn app:app \
  --app-dir tool/rag_model_service --host 127.0.0.1 --port 8765 --no-access-log
```

The F16 GGUF is 1,159,774,656 bytes with SHA-256
`0c5784a1f3402d93c42deb0593aaeb38edb08a511d30cde18af84ab64a164a8a`.
The gateway checks the weights, backend model path/alias/build/context and pinned
tokenizer pair lengths. `GET /v1/reranker/health` declares its fingerprint and
`bge_raw_logit` scale. `POST /v1/rerank` accepts stable candidate IDs and returns
raw classifier scores plus backend usage, with `truncated: false`. Scores are
not cosine or probabilities; a missing backend fails explicitly. llama.cpp's
missing-embedding sentinel, malformed scores and model drift are rejected.
Before each inference, every query/passage token ID is compared with llama.cpp's
`/tokenize` output, the special-token pair is checked, and the returned usage must
equal all validated pair lengths. A disagreement fails explicitly rather than
advertising unverified `truncated: false`. Backend identity is checked before and
after each call; measured timings include this validation overhead.

Run `integration_test/day23_calibration_io_test.dart` on Linux with the actual
DeepSeek environment credential to collect the separate eight-question dev set.
The main ablation harness is `integration_test/day23_live_io_test.dart` and reads
the frozen `eval/rag/calibration.json`; never select thresholds on its ten golden
questions. Native runs save to fresh external paths and refuse to overwrite
earlier evidence.
