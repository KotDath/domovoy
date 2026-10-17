#!/usr/bin/env bash
# Ephemeral CI runner only. Local users should use the existing gateway instead.
set -euo pipefail
: "${RUNNER_TEMP:?This bootstrap is for disposable CI runners}"
: "${HF_HOME:?Set an external tokenizer cache}"
: "${OLLAMA_MODELS:?Set an external model cache}"
service_dir="$RUNNER_TEMP/domovoy-rag-service"
mkdir -p "$service_dir" "$HF_HOME" "$OLLAMA_MODELS"
archive="$service_dir/ollama.tar.zst"
curl --fail --location --retry 3 --silent --show-error \
  https://github.com/ollama/ollama/releases/download/v0.18.2/ollama-linux-amd64.tar.zst -o "$archive"
printf '%s  %s\n' 3a72ab2113b52f58ec76d02a4e30e07d80b4897a639e7cece9399b45fe72bfc0 "$archive" | sha256sum --check --status
tar --zstd -xf "$archive" -C "$service_dir"
export OLLAMA_HOST=127.0.0.1:11434
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_MAX_LOADED_MODELS=1
export OLLAMA_KEEP_ALIVE=30m
"$service_dir/bin/ollama" serve > "$service_dir/ollama.log" 2>&1 &
for attempt in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null; then break; fi
  sleep 2
done
"$service_dir/bin/ollama" pull qwen3-embedding:0.6b
python3 -m venv "$service_dir/venv"
"$service_dir/venv/bin/pip" install --disable-pip-version-check -r tool/rag_model_service/requirements.lock
"$service_dir/venv/bin/python" tool/rag_model_service/prepare_tokenizers.py
"$service_dir/venv/bin/python" -m uvicorn app:app --app-dir tool/rag_model_service \
  --host 127.0.0.1 --port 8765 --no-access-log > "$service_dir/gateway.log" 2>&1 &
"$service_dir/venv/bin/python" - <<'PY'
import json,time,urllib.request
for attempt in range(90):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/health', timeout=10) as response:
            data=json.load(response)
        if (data['ready'] is True and data['dimension']==1024 and
            data['embedding']['model']=='qwen3-embedding:0.6b' and
            data['embedding']['digest']=='ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d'):
            print('Real embedding gateway ready:',data['fingerprint'])
            break
        raise SystemExit('Embedding identity differs from pinned CI model')
    except (OSError,ValueError):
        time.sleep(2)
else:
    raise SystemExit('Embedding gateway not ready')
PY
