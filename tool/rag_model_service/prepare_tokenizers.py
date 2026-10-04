"""Fetch the two pinned tokenizer snapshots once, outside inference requests."""
import json
from pathlib import Path
from huggingface_hub import snapshot_download

config = json.loads(Path(__file__).with_name('models.lock.json').read_text())
for kind, model in config.items():
    snapshot_download(repo_id=model['repository'], revision=model['revision'],
                      allow_patterns=['config.json', 'tokenizer*', 'special_tokens_map.json',
                                      'sentencepiece.bpe.model', 'vocab.json', 'merges.txt'])
    print(f'{kind}: pinned tokenizer cached')
