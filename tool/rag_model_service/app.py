"""Loopback-only inference gateway. Corpus/index/retrieval remain in Dart."""
import hashlib
import json
import math
import os
from functools import lru_cache
from pathlib import Path
from threading import Lock

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from transformers import AutoTokenizer

app = FastAPI(title="Domovoy local inference", version="1")
ollama_url = "http://127.0.0.1:11434"
embedding_model = "qwen3-embedding:0.6b"
query_instruction = "Instruct: Given a question, retrieve relevant passages that answer the question\nQuery: "
config_path = Path(__file__).with_name("models.lock.json")
config = json.loads(config_path.read_text())
inference_lock = Lock()


@lru_cache(maxsize=2)
def tokenizer(kind="embedding"):
    entry = config[kind]
    return AutoTokenizer.from_pretrained(
        entry["repository"], revision=entry["revision"], trust_remote_code=False, local_files_only=True
    )


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def embedding_config():
    with httpx.Client(timeout=10, trust_env=False) as client:
        tags = client.get(f"{ollama_url}/api/tags").raise_for_status().json()
    model = next((m for m in tags["models"] if m["name"] == embedding_model), None)
    if model is None:
        raise HTTPException(503, "embedding_model_missing")
    return {
        "model": embedding_model, "digest": model["digest"],
        "tokenizer": config["embedding"], "dimension": 1024,
        "normalized": True, "query_template": query_instruction,
        "passage_template": "", "pooling": "last_token",
    }


@app.get("/health")
def health():
    try:
        tokenizer()
        model = embedding_config()
    except (httpx.HTTPError, OSError) as error:
        raise HTTPException(503, "embedding_service_unavailable") from error
    return {"ready": True, "embedding": model,
            "fingerprint": digest(model), "dimension": 1024,
            "max_input_tokens": 8192, "offset_unit": "codepoint",
            "capabilities": ["tokenize", "embeddings"],
            "tokenizer_fingerprints": {kind: digest(config[kind]) for kind in ("embedding", "reranker")},
            "reranker_pair_limit": 8192, "reranker_query_limit": 1024}


class TokenizeInput(BaseModel):
    text: str = Field(max_length=2_000_000)
    kind: str = "embedding"


@app.post("/v1/tokenize")
def tokenize(body: TokenizeInput):
    if body.kind not in ("embedding", "reranker"):
        raise HTTPException(422, "unknown_tokenizer")
    encoded = tokenizer(body.kind)(body.text, add_special_tokens=False,
                                   return_offsets_mapping=True, truncation=False)
    return {"offset_unit": "codepoint", "offsets": encoded["offset_mapping"],
            "count": len(encoded["input_ids"]),
            "tokenizer_fingerprint": digest(config[body.kind])}


class EmbedItem(BaseModel):
    id: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1, max_length=100_000)
    kind: str


class EmbedInput(BaseModel):
    expected_model_fingerprint: str
    inputs: list[EmbedItem] = Field(min_length=1, max_length=8)


@app.post("/v1/embeddings")
def embeddings(body: EmbedInput):
    model = embedding_config()
    fingerprint = digest(model)
    if body.expected_model_fingerprint != fingerprint:
        raise HTTPException(409, "embedding_fingerprint_changed")
    if len({i.id for i in body.inputs}) != len(body.inputs):
        raise HTTPException(422, "duplicate_id")
    texts = []
    counts = []
    for item in body.inputs:
        if item.kind not in ("query", "passage"):
            raise HTTPException(422, "unknown_input_kind")
        text = query_instruction + item.text if item.kind == "query" else item.text
        count = len(tokenizer()(text, add_special_tokens=True)["input_ids"])
        if count > 8192:
            raise HTTPException(422, "input_too_long")
        texts.append(text)
        counts.append(count)
    try:
        with inference_lock, httpx.Client(timeout=180, trust_env=False) as client:
            response = client.post(f"{ollama_url}/api/embed", json={
                "model": embedding_model, "input": texts, "truncate": False,
                "options": {"num_ctx": 8192}, "keep_alive": "30m",
            }).raise_for_status().json()
    except httpx.HTTPError as error:
        raise HTTPException(503, "embedding_inference_failed") from error
    vectors = response.get("embeddings", [])
    if len(vectors) != len(body.inputs):
        raise HTTPException(502, "invalid_embedding_count")
    outputs = []
    for item, vector, count in zip(body.inputs, vectors, counts):
        if len(vector) != 1024 or not all(math.isfinite(v) for v in vector):
            raise HTTPException(502, "invalid_embedding_vector")
        norm = math.sqrt(sum(v*v for v in vector))
        if norm <= 0:
            raise HTTPException(502, "zero_embedding")
        outputs.append({"id": item.id, "vector": [v/norm for v in vector],
                        "input_tokens": count})
    # A tag can be replaced while inference is running; never attach stale metadata.
    if digest(embedding_config()) != fingerprint:
        raise HTTPException(409, "embedding_fingerprint_changed")
    return {"fingerprint": fingerprint, "dimension": 1024,
            "normalized": True, "truncated": False, "outputs": outputs}


@lru_cache(maxsize=2)
def verified_reranker_weights(path, size, modified):
    """Weights are external; only a checksum-verified identity is advertised."""
    runtime = config.get("reranker_runtime")
    if runtime is None:
        raise HTTPException(503, "reranker_not_configured")
    checksum = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != runtime["gguf_sha256"]:
        raise HTTPException(503, "reranker_weights_mismatch")
    return {
        "model": config["reranker"], "runtime": runtime,
        "pooling": "rank", "score_scale": "bge_raw_logit",
        "pair_format": "xlm-roberta: <s>query</s></s>passage</s>",
        "pair_limit": 8192, "query_limit": 1024,
    }


def reranker_config():
    model_path = os.environ.get("RAG_RERANK_MODEL_PATH")
    if not model_path:
        raise HTTPException(503, "reranker_not_configured")
    try:
        path = Path(model_path)
        stat = path.stat()
        model = verified_reranker_weights(str(path), stat.st_size, stat.st_mtime_ns)
        alias = "bge-reranker-v2-m3-" + model["runtime"]["gguf_sha256"][:12]
        with httpx.Client(timeout=10, trust_env=False) as client:
            status = client.get("http://127.0.0.1:8766/health").raise_for_status().json()
            ids = client.get("http://127.0.0.1:8766/v1/models").raise_for_status().json()
            props = client.get("http://127.0.0.1:8766/props").raise_for_status().json()
        if (status.get("status") != "ok" or alias not in {m["id"] for m in ids["data"]} or
                Path(props.get("model_path", "")).resolve() != path.resolve() or
                props.get("build_info") != model["runtime"]["build_info"] or
                props.get("default_generation_settings", {}).get("n_ctx", 0) < 8192):
            raise HTTPException(503, "reranker_backend_mismatch")
        return model, alias
    except (OSError, httpx.HTTPError) as error:
        raise HTTPException(503, "reranker_unavailable") from error


@app.get("/v1/reranker/health")
def reranker_health():
    model, _ = reranker_config()
    return {"ready": True, "fingerprint": digest(model), "score_scale": "bge_raw_logit",
            "pair_limit": 8192, "query_limit": 1024, "model": model}


class RerankCandidate(BaseModel):
    id: str = Field(min_length=1, max_length=128)
    text: str = Field(min_length=1, max_length=100_000)


class RerankInput(BaseModel):
    query: str = Field(min_length=1, max_length=16_384)
    expected_model_fingerprint: str
    candidates: list[RerankCandidate] = Field(min_length=1, max_length=20)


@app.post("/v1/rerank")
def rerank(body: RerankInput):
    model, alias = reranker_config()
    fingerprint = digest(model)
    if body.expected_model_fingerprint != fingerprint:
        raise HTTPException(409, "reranker_fingerprint_changed")
    if len({c.id for c in body.candidates}) != len(body.candidates):
        raise HTTPException(422, "duplicate_id")
    tok = tokenizer("reranker")
    if len(tok(body.query, add_special_tokens=False)["input_ids"]) > 1024:
        raise HTTPException(422, "reranker_query_too_long")
    pair_ids = []
    for candidate in body.candidates:
        pair = tok(body.query, candidate.text, add_special_tokens=True, truncation=False)
        if len(pair["input_ids"]) > 8192:
            raise HTTPException(422, "reranker_pair_too_long")
        pair_ids.append(pair["input_ids"])
    try:
        with inference_lock, httpx.Client(timeout=180, trust_env=False) as client:
            def backend_tokens(text):
                ids = client.post("http://127.0.0.1:8766/tokenize", json={
                    "content": text, "add_special": False, "parse_special": False,
                }).raise_for_status().json().get("tokens")
                if not isinstance(ids, list) or any(type(i) is not int for i in ids):
                    raise HTTPException(502, "invalid_backend_tokens")
                if ids != tok(text, add_special_tokens=False, truncation=False)["input_ids"]:
                    raise HTTPException(409, "reranker_tokenizer_mismatch")
                return ids

            query_ids = backend_tokens(body.query)
            for candidate, expected in zip(body.candidates, pair_ids):
                # The pinned llama.cpp build constructs exactly this XLM-R pair.
                actual = [tok.bos_token_id, *query_ids, tok.eos_token_id,
                          tok.sep_token_id, *backend_tokens(candidate.text), tok.eos_token_id]
                if actual != expected:
                    raise HTTPException(409, "reranker_pair_tokenizer_mismatch")
            response = client.post("http://127.0.0.1:8766/reranking", json={
                "model": alias, "query": body.query, "top_n": len(body.candidates),
                "documents": [c.text for c in body.candidates],
            }).raise_for_status().json()
    except httpx.HTTPError as error:
        raise HTTPException(503, "reranker_inference_failed") from error
    results = response.get("results", [])
    usage = response.get("usage", {})
    expected_tokens = sum(len(ids) for ids in pair_ids)
    if (type(usage.get("prompt_tokens")) is not int or
            usage["prompt_tokens"] != expected_tokens or
            usage.get("total_tokens") != expected_tokens):
        raise HTTPException(502, "reranker_token_usage_mismatch")
    indexes = [r.get("index") for r in results]
    if (len(results) != len(body.candidates) or
            set(indexes) != set(range(len(body.candidates))) or
            any(not isinstance(i, int) or isinstance(i, bool) for i in indexes) or
            any(not isinstance(r.get("relevance_score"), (int, float)) or
                isinstance(r.get("relevance_score"), bool) or
                r.get("relevance_score") == -1e6 or  # llama.cpp missing-embedding sentinel
                not math.isfinite(r["relevance_score"]) for r in results)):
        raise HTTPException(502, "invalid_reranker_response")
    if digest(reranker_config()[0]) != fingerprint:
        raise HTTPException(409, "reranker_fingerprint_changed")
    # llama.cpp returns the classifier logit directly. Do not call it cosine,
    # apply a hidden sigmoid or transplant a threshold from another scale.
    return {"fingerprint": fingerprint, "score_scale": "bge_raw_logit", "truncated": False,
            "usage": response.get("usage"), "outputs": [
                {"id": body.candidates[r["index"]].id, "score": r["relevance_score"]}
                for r in results]}
