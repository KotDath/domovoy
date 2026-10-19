#!/usr/bin/env bash
# Ephemeral CI runner only. Local users should use the existing gateway instead.
set -euo pipefail
: "${RUNNER_TEMP:?This bootstrap is for disposable CI runners}"
: "${HF_HOME:?Set an external tokenizer cache}"
export RAG_EMBEDDING_BACKEND="${RAG_EMBEDDING_BACKEND:-neuraldeep}"
service_dir="$RUNNER_TEMP/domovoy-rag-service"
mkdir -p "$service_dir" "$HF_HOME"
case "$RAG_EMBEDDING_BACKEND" in
neuraldeep)
  : "${NDT_KEY:?Set NDT_KEY for NeuralDeep embeddings}"
  ;;
ollama)
  : "${OLLAMA_MODELS:?Set an external model cache}"
  mkdir -p "$OLLAMA_MODELS"
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
  ;;
*) echo 'Unsupported embedding backend' >&2; exit 1 ;;
esac
python3 -m venv "$service_dir/venv"
"$service_dir/venv/bin/pip" install --disable-pip-version-check -r tool/rag_model_service/requirements.lock
env -u HF_TOKEN -u NDT_KEY HF_HUB_DISABLE_IMPLICIT_TOKEN=1 "$service_dir/venv/bin/python" tool/rag_model_service/prepare_tokenizers.py
"$service_dir/venv/bin/python" -m uvicorn app:app --app-dir tool/rag_model_service \
  --host 127.0.0.1 --port 8765 --no-access-log > "$service_dir/gateway.log" 2>&1 &
"$service_dir/venv/bin/python" - <<'PY'
import json,os,time,urllib.request,urllib.error
from pathlib import Path
lock=json.loads(Path('tool/rag_model_service/models.lock.json').read_text())
for attempt in range(90):
    try:
        with urllib.request.urlopen('http://127.0.0.1:8765/health', timeout=10) as response:
            data=json.load(response)
        model = data['embedding']
        backend = os.environ['RAG_EMBEDDING_BACKEND']
        compatible = (model.get('backend')=='neuraldeep' and
                      model['model']=='qwen3-embedding-4b' and
                      model['weights_revision']=='provider-managed-unpinned' and
                      model['tokenizer']==lock['embedding_neuraldeep']) if backend=='neuraldeep' else (
                      model['model']=='qwen3-embedding:0.6b' and
                      model['digest']=='ac6da0dfba84a81fdbfbaf330198c33cd77c4cdfc53e8bc50eb581914a15621d')
        expected_dimension=2560 if backend=='neuraldeep' else 1024
        if data['ready'] is True and data['dimension']==expected_dimension and compatible:
            print('Embedding gateway ready:',backend,model['model'],data['fingerprint'])
            break
        raise SystemExit('Embedding identity differs from configured CI backend')
    except (OSError,ValueError):
        time.sleep(2)
else:
    raise SystemExit('Embedding gateway not ready')
if backend=='neuraldeep':
    # Fail before corpus indexing on missing permission/credit/provider errors.
    # Only fixed public text leaves the runner in this startup probe.
    body={'expected_model_fingerprint':data['fingerprint'],
          'inputs':[{'id':'startup','kind':'passage','text':'Code review uses implementation contracts and documentation.'}]}
    req=urllib.request.Request('http://127.0.0.1:8765/v1/embeddings',
                              data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=75) as response: probe=json.load(response)
    except urllib.error.HTTPError as error:
        upstream=None
        try:
            detail=json.loads(error.read(4096)).get('detail')
            if isinstance(detail,dict) and detail.get('code')=='neuraldeep_embedding_http_error':
                status=detail.get('status')
                if type(status) is int and 100<=status<=599: upstream=status
        except (ValueError,AttributeError): pass
        raise SystemExit(f'NeuralDeep embedding startup probe failed: gateway HTTP {error.code}, upstream HTTP {upstream or "unknown"}; check NDT_KEY/access/quota/provider availability') from None
    except (OSError,ValueError):
        raise SystemExit('NeuralDeep embedding startup probe failed: connection or invalid response') from None
    if (probe.get('fingerprint')!=data['fingerprint'] or probe.get('dimension')!=2560
            or len(probe.get('outputs',[]))!=1 or len(probe['outputs'][0]['vector'])!=2560):
        raise SystemExit('NeuralDeep embedding startup probe returned incompatible data')
    print('NeuralDeep remote embedding startup probe passed (one public passage, 2560 dimensions)')
PY
