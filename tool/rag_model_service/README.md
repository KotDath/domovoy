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
Reranker weights/server are added in day 23; day 21 only needs its tokenizer.

`requirements.lock` includes transitive dependencies; environments, HF caches,
Ollama weights and downloaded third-party PDFs stay outside Git. Service binds
to loopback and disables proxy environment inheritance and request access logs.
