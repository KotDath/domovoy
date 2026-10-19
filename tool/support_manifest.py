#!/usr/bin/env python3
"""Generate/check the manifest of the single authoritative product manual."""
import argparse
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
bundle = root / 'assets/support'
provenance = {
    'keys-and-models.md': ['lib/features/settings/presentation/provider_api_keys_dialog.dart', 'lib/features/settings/', 'lib/infrastructure/llm/discovery/'],
    'projects.md': ['lib/features/projects/', 'lib/features/knowledge/application/project_help_preparer.dart', 'lib/features/projects/application/project_files_preparer.dart'],
    'mcp.md': ['lib/features/mcp/', 'lib/infrastructure/mcp/sdk/mcp_platform_policy.dart', 'lib/infrastructure/support/support_mcp_server.dart'],
    'knowledge.md': ['lib/features/knowledge/', 'lib/core/rag/', 'lib/features/support/application/support_run_preparer.dart'],
    'memory.md': ['lib/features/memory/', 'lib/features/profile/', 'lib/infrastructure/support/support_mcp_server.dart'],
    'tasks-and-tickets.md': ['lib/features/tasks/', 'lib/features/support/'],
}
manifest = {'version': 1, 'packageVersion': re.search(r'^version: (.+)$', (root / 'pubspec.yaml').read_text(), re.M)[1], 'revision': 'domovoy-support-2026-10-18-v1', 'documents': [
    {'asset': f'assets/support/{p.name}', 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(), 'source': f'domovoy://manual/{p.stem}', 'provenance': provenance[p.name]}
    for p in sorted(bundle.glob('*.md'))
]}
encoded = json.dumps(manifest, ensure_ascii=False, indent=2) + '\n'
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
target = bundle / 'manifest.json'
if args.check:
    if target.read_text() != encoded:
        raise SystemExit('Support manual manifest is stale; run python3 tool/support_manifest.py')
    print('Support manual manifest verified')
else:
    target.write_text(encoded)
