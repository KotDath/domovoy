"""Benign schema/mode/source predicates only; no credentials or service setup."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

DART = shutil.which('dart')


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class R1Regressions(unittest.TestCase):
    def test_real_lock_schema_prepares_exactly_two_pinned_tokenizers(self):
        lock = json.loads(Path('tool/rag_model_service/models.lock.json').read_text())
        self.assertIn('reranker_runtime', lock)
        calls = []
        hub = types.ModuleType('huggingface_hub')
        hub.snapshot_download = lambda **kw: calls.append(kw)
        with patch.dict(sys.modules, {'huggingface_hub': hub}), contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path('tool/rag_model_service/prepare_tokenizers.py', run_name='__main__')
        self.assertEqual([(c['repo_id'], c['revision']) for c in calls],
                         [(lock[k]['repository'], lock[k]['revision']) for k in ('embedding', 'reranker')])
        self.assertEqual(len(calls), 2)
        self.assertIn('tokenizer*', calls[0]['allow_patterns'])

    def test_neuraldeep_prepares_4b_tokenizer_without_changing_local_default(self):
        lock = json.loads(Path('tool/rag_model_service/models.lock.json').read_text())
        calls = []
        hub = types.ModuleType('huggingface_hub')
        hub.snapshot_download = lambda **kw: calls.append(kw)
        with patch.dict(sys.modules, {'huggingface_hub': hub}), \
             patch.dict(os.environ, {'RAG_EMBEDDING_BACKEND': 'neuraldeep'}), \
             contextlib.redirect_stdout(io.StringIO()):
            runpy.run_path('tool/rag_model_service/prepare_tokenizers.py', run_name='__main__')
        self.assertEqual([(c['repo_id'], c['revision']) for c in calls],
            [(lock[k]['repository'], lock[k]['revision']) for k in ('embedding_neuraldeep', 'reranker')])
        self.assertEqual(len(calls), 2)
        self.assertNotIn('model.safetensors', calls[0]['allow_patterns'])

    def test_concrete_store_predicates_align_with_day31_at_any_depth(self):
        review = module('review_policy', 'tool/headless/github_review.py')
        baseline = module('export_policy', 'tool/export_project.py')
        denied = set()
        for prefix in ('', 'workspace/', 'workspace/NESTED/'):
            for name in baseline.SECRET_NAMES:
                denied.add(prefix+name)
                denied.add(prefix+name+'/source.py')
            for store in baseline.SECRET_PATHS | {('.config', 'gcloud', 'application_default_credentials.json')}:
                denied.add(prefix+'/'.join(store))
                denied.add(prefix+'/'.join(store)+'/source.py')
            for name in ('.env', '.env.local', '.environment', 'private.pem', 'private.key', 'store.jks', 'store.keystore'):
                denied.add(prefix+name)
                denied.add(prefix+name+'/source.py')
        denied |= {p.upper() for p in list(denied)}
        allowed = ['lib/credentials/credential_resolver.dart', 'lib/secret_service.dart',
                   'docs/credentials.md', 'lib/secrets/source.py', '.github/workflows/review.yml',
                   '.config/lint.json', 'nested/.config/lint.json', '.editorconfig']
        paths = sorted(denied)+allowed
        result = subprocess.run([DART, 'test/support/headless_source_policy_probe.dart'],
                                input=json.dumps(paths), text=True, capture_output=True, check=True)
        dart = json.loads(result.stdout)
        for path in denied:
            self.assertTrue(baseline.sensitive_path(path) or '.CONFIG/GCLOUD/' in path.upper(), path)
            self.assertFalse(review.permits(path), path)
            self.assertFalse(dart[path], path)
        for path in allowed:
            self.assertFalse(baseline.sensitive_path(path), path)
            self.assertTrue(review.permits(path), path)
            self.assertTrue(dart[path], path)

    def test_debug_profile_product_transport_constructor_defaults(self):
        for flags, expected in [([], True), (['-Ddart.vm.profile=true'], False),
                                (['-Ddart.vm.product=true'], False)]:
            result = subprocess.run([DART, *flags, 'test/support/rag_transport_mode_probe.dart'],
                                    capture_output=True, text=True, check=True)
            mode = json.loads(result.stdout)
            self.assertEqual(mode['default'], expected, mode)
            self.assertTrue(mode['explicit_allow'])
            self.assertFalse(mode['explicit_deny'])


if __name__ == '__main__':
    unittest.main()
