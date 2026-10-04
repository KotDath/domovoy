"""Loopback-only inference gateway. Corpus/index/retrieval remain in Dart."""
import hashlib
import json
import math
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
            "tokenizer_fingerprints": {kind: digest(config[kind]) for kind in config},
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
