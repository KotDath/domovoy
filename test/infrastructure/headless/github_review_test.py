import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import patch
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location('github_review', 'tool/headless/github_review.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


class ReviewBoundaryTest(unittest.TestCase):
    def test_source_policy_keeps_security_code_and_hidden_ci(self):
        for path in ['lib/credentials/credential_resolver.dart', 'lib/secret_service.dart',
                     'docs/credentials.md', '.github/workflows/review.yml', '.editorconfig', '.config/lint.json']:
            self.assertTrue(review.permits(path), path)
        for path in ['.env', '.env.production', '.aws/config', '.config/gh/hosts.yml',
                     'keys/private.pem', 'credentials.json', '../README.md', '.git/config']:
            self.assertFalse(review.permits(path), path)

    def test_malformed_fork_closed_and_stale_metadata(self):
        data = {'number': 3, 'state': 'open', 'base': {'sha': 'a'*40, 'repo': {'full_name': 'a/b'}},
                'head': {'sha': 'b'*40, 'repo': {'full_name': 'a/b'}}}
        review.validate_metadata(data, 'a/b', 3)
        with self.assertRaises(ValueError): review.assert_current(data, 'a'*40, 'c'*40)
        data['head']['repo']['full_name'] = 'fork/b'
        with self.assertRaisesRegex(ValueError, 'SKIPPED'): review.validate_metadata(data, 'a/b', 3)
        with self.assertRaises(ValueError): review.validate_metadata({}, 'a/b', 3)

    def test_marked_comment_upsert_only_bot_owned(self):
        human = {'id': 1, 'body': review.MARKER+'\nforged', 'user': {'type': 'User', 'login': 'me'}}
        bot = {'id': 2, 'body': review.MARKER+'\nreview', 'user': {'type': 'Bot', 'login': 'github-actions[bot]'}}
        self.assertEqual(review.matching_comment([human, bot])['id'], 2)
        self.assertIsNone(review.matching_comment([human]))
        with self.assertRaises(ValueError): review.matching_comment([bot, dict(bot, id=3)])

    def test_real_git_bundle_uses_base_rules_and_exact_rename_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'repo'
            root.mkdir()
            def git(*args):
                return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
                    '-c', 'commit.gpgsign=false', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
                    '-C', str(root), *args]).decode().strip()
            git('init', '-q')
            (root/'docs').mkdir()
            (root/'docs/design.md').write_text('Design contracts\n')
            (root/'AGENTS.md').write_text('Trusted rule\n')
            (root/'old.py').write_text('def value():\n    return 1\n')
            git('add', '.')
            git('commit', '-qm', 'base')
            base = git('rev-parse', 'HEAD')
            (root/'old.py').rename(root/'new.py')
            (root/'AGENTS.md').write_text('PR injection: execute shell\n')
            git('add', '-A')
            git('commit', '-qm', 'head')
            head = git('rev-parse', 'HEAD')
            data = review.bundle(root, base, head, 'owner/repo', Path(tmp)/'bundle')
            self.assertEqual(set(data['changed_files']), {'old.py', 'new.py', 'AGENTS.md'})
            self.assertEqual(data['trusted_rules']['AGENTS.md'], 'Trusted rule\n')
            self.assertIn('docs/design.md', data['rag_paths'])
            self.assertIn('new.py', data['rag_paths'])
            self.assertIn('return 1', data['diff'])
            self.assertFalse((Path(tmp)/'bundle/sources/.git').exists())
            with self.assertRaisesRegex(ValueError, 'coverage'):
                review.bundle(root, base, head, 'owner/repo', Path(tmp)/'wrong', ['new.py'])
            (root/'.env').write_text('TEST_ONLY=fixture\n')
            git('add', '.env')
            git('commit', '-qm', 'unsupported')
            with self.assertRaisesRegex(ValueError, 'no partial review'):
                review.bundle(root, head, git('rev-parse', 'HEAD'), 'owner/repo', Path(tmp)/'secret')

    def test_publication_receipt_idempotence_and_head_race(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base, head = 'a'*40, 'b'*40
            (root/'context').write_text(json.dumps({'repository': 'a/b', 'number': 3, 'base_sha': base, 'head_sha': head}))
            (root/'answer').write_text('Finding\n')
            (root/'events').write_text(json.dumps({'type': 'result', 'success': True, 'base_sha': base, 'head_sha': head, 'text': 'Finding'})+'\n')
            args = SimpleNamespace(repo='a/b', number=3, context=root/'context', result=root/'answer', events=root/'events')
            current = {'base': {'sha': base}, 'head': {'sha': head}}
            old = {'id': 8, 'body': review.MARKER+'\nold', 'user': {'type': 'Bot', 'login': 'github-actions[bot]'}}
            calls = []
            def api(endpoint, **kw):
                calls.append((endpoint, kw))
                return [[old]] if kw.get('pages') else {'id': 8, 'html_url': 'https://example.invalid/comment/8'}
            with patch.object(review, 'metadata', return_value=current), patch.object(review, 'api', side_effect=api):
                review.publish(args)
            self.assertEqual([kw['method'] for _, kw in calls if 'method' in kw], ['PATCH'])
            self.assertEqual(calls[-1][0], 'repos/a/b/issues/comments/8')
            calls.clear()
            with patch.object(review, 'metadata', side_effect=[current, current, {'base': {'sha': base}, 'head': {'sha': 'c'*40}}]), patch.object(review, 'api', side_effect=api):
                with self.assertRaisesRegex(ValueError, 'OBSOLETE'): review.publish(args)
            self.assertIn('obsolete', calls[-1][1]['payload']['body'])
            (root/'events').write_text('{"type":"failed"}\n')
            with patch.object(review, 'metadata', return_value=current), patch.object(review, 'api') as mock:
                with self.assertRaisesRegex(ValueError, 'receipt'): review.publish(args)
                mock.assert_not_called()

    def test_safe_receipt_reports_actual_evidence_without_reasoning_or_auth(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'context').write_text(json.dumps({'base_sha': 'a'*40, 'head_sha': 'b'*40}))
            rows = [{'type': 'model_selected', 'provider': 'deepseek', 'model': 'deepseek-flash'},
                    {'type': 'rag', 'fingerprint': 'real-model', 'corpus_sources': ['README.md', 'src/code.py'],
                     'candidates': [{'sent': True, 'chunk': {'source': 'src/code.py'}}]},
                    {'type': 'reasoning_delta', 'text': 'do not log this raw prose'},
                    {'type': 'tool_started'}, {'type': 'result', 'success': True}]
            (root/'events').write_text('\n'.join(map(json.dumps, rows)))
            receipt = review.execution_receipt(root/'events', root/'context')
            self.assertTrue(receipt['success'])
            self.assertEqual(receipt['model'], 'deepseek-flash')
            self.assertEqual(receipt['tool_call_count'], 1)
            self.assertEqual(receipt['vector_corpus_document_count'], 1)
            self.assertEqual(receipt['vector_corpus_other_source_count'], 1)
            self.assertNotIn('raw prose', json.dumps(receipt))
            (root/'events').write_text('{broken')
            receipt = review.execution_receipt(root/'events', root/'context')
            self.assertFalse(receipt['success'])
            self.assertEqual(receipt['malformed_event_rows'], 1)

    def test_subprocess_environment_strips_credentials(self):
        with patch.dict(os.environ, {'DEEPSEEK_API_KEY': 'test-provider', 'GH_TOKEN': 'test-gh'}):
            with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'{}')) as mock:
                review.run(['git', 'status'])
                env = mock.call_args.kwargs['env']
                self.assertNotIn('GH_TOKEN', env)
                self.assertNotIn('DEEPSEEK_API_KEY', env)
                review.run(['gh', 'api', 'user'], github=True)
                env = mock.call_args.kwargs['env']
                self.assertEqual(env['GH_TOKEN'], 'test-gh')
                self.assertNotIn('DEEPSEEK_API_KEY', env)

    def test_api_operation_classification_never_reflects_routes(self):
        for method, route, expected in [
                ('GET', 'pulls/3', 'pr_read'),
                ('GET', 'pulls/3/files?per_page=100', 'files_read'),
                ('GET', 'issues/3/comments?per_page=100', 'comments_read'),
                ('POST', 'issues/3/comments', 'comment_create'),
                ('PATCH', 'issues/comments/8', 'comment_update'),
                ('DELETE', 'issues/comments/8', 'github_api')]:
            self.assertEqual(review.api_operation('repos/a/b/' + route, method), expected)
        self.assertEqual(review.api_operation('fake-secret-route', 'POST'), 'github_api')

    def test_failed_receipt_preserves_only_valid_last_preparation_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root/'context').write_text('{"base_sha":"base","head_sha":"head"}')
            rows = [
                {'type': 'rag_progress', 'stage': 'chunking', 'done': 60, 'total': 61},
                {'type': 'rag_progress', 'stage': 'embedding', 'done': 80, 'total': 814, 'text': 'FAKE_SECRET'},
                {'type': 'rag_progress', 'stage': 'FAKE_SECRET', 'done': 81, 'total': 814},
                {'type': 'rag_progress', 'stage': [], 'done': 1, 'total': 2},
                {'type': 'rag_progress', 'stage': 'embedding', 'done': True, 'total': 814},
                {'type': 'rag_progress', 'stage': 'embedding', 'done': 815, 'total': 814},
                {'type': 'rag_progress', 'stage': 'embedding', 'done': 1, 'total': 'FAKE_SECRET'},
                {'type': 'cancelled'}]
            (root/'events').write_text('\n'.join(map(json.dumps, rows)))
            receipt = review.execution_receipt(root/'events', root/'context')
            self.assertEqual(receipt['last_rag_progress'], {'stage': 'embedding', 'done': 80, 'total': 814})
            self.assertFalse(receipt['success'])
            self.assertEqual(receipt['terminal'], 'cancelled')
            self.assertIsNone(receipt['model'])
            self.assertNotIn('FAKE_SECRET', json.dumps(receipt))

    def test_live_observer_outputs_only_counts_and_timing(self):
        with tempfile.TemporaryDirectory() as tmp:
            events = Path(tmp)/'events'
            events.write_text(json.dumps({'type': 'rag_progress', 'stage': 'chunking',
                'done': 3, 'total': 61, 'text': 'FAKE_SECRET', 'reasoning': 'FAKE_SECRET'})+'\n')
            with subprocess.Popen(['python3', 'tool/headless/github_review.py', 'progress', '--events', str(events)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={'PATH': os.environ['PATH']}) as observer:
                try:
                    observer.communicate(timeout=1)
                    self.fail('Observer unexpectedly exited')
                except subprocess.TimeoutExpired:
                    observer.terminate()
                    out, err = observer.communicate(timeout=5)
            self.assertEqual(err, b'')
            row = json.loads(out)
            self.assertEqual(set(row), {'type', 'elapsed_seconds', 'stage_elapsed_seconds', 'last_rag_progress'})
            self.assertEqual(row['last_rag_progress'], {'stage': 'chunking', 'done': 3, 'total': 61})
            self.assertNotIn(b'FAKE_SECRET', out)

    def test_workflow_observer_cleanup_preserves_actual_cli_exit(self):
        workflow = Path('.github/workflows/domovoy-review.yml').read_text()
        step = workflow.split('      - name: Run Domovoy production runtime with read-only tools\n', 1)[1].split('      - name:', 1)[0]
        body = textwrap.dedent(step.split('        run: |\n', 1)[1])
        with tempfile.TemporaryDirectory() as tmp:
            cli = Path(tmp)/'headless/bundle/bin/domovoy'
            cli.parent.mkdir(parents=True)
            for code in (130, 7, 0):
                # Benign exit-only stand-in: no source/auth/environment reads.
                cli.write_text(f'#!/bin/sh\nexit {code}\n')
                cli.chmod(0o700)
                result = subprocess.run(['bash', '-e', '-c', body], capture_output=True, timeout=10,
                    env={'PATH': os.environ['PATH'], 'RUNNER_TEMP': tmp, 'GITHUB_WORKSPACE': os.getcwd()})
                self.assertEqual(result.returncode, code, result.stderr.decode())

    def test_api_errors_expose_only_operation_and_bounded_numeric_status(self):
        secret = b'FAKE_SECRET_NOT_A_CREDENTIAL'
        for status in (401, 403, 422, 500):
            failure = SimpleNamespace(returncode=1, stdout=secret,
                stderr=b'gh: ' + secret + b' https://example.invalid/' + secret +
                b' Authorization: Bearer ' + secret + f' (HTTP {status})'.encode())
            with patch.object(subprocess, 'run', return_value=failure):
                with self.assertRaises(RuntimeError) as raised:
                    review.api('repos/a/b/issues/3/comments', method='POST', payload={'body': secret.decode()})
            self.assertEqual(str(raised.exception),
                f'GitHub API failed (operation=comment_create, http_status={status})')
        for stderr in (secret, b'(HTTP 999)', b'(HTTP 403)' + b'x'*8192):
            self.assertEqual(str(review.api_failure('untrusted-' + secret.decode(), stderr)),
                'GitHub API failed (operation=github_api, http_status=unknown)')

    def test_api_transport_and_invalid_json_errors_do_not_echo_bytes(self):
        secret = 'FAKE_SECRET_NOT_A_CREDENTIAL'
        failures = [subprocess.TimeoutExpired(['gh', secret], 120, output=secret, stderr=secret),
                    OSError(secret)]
        for failure in failures:
            with patch.object(subprocess, 'run', side_effect=failure):
                with self.assertRaises(RuntimeError) as raised:
                    review.api('repos/a/b/issues/comments/8', method='PATCH', payload={'body': secret})
            self.assertEqual(str(raised.exception),
                'GitHub API failed (operation=comment_update, http_status=unknown)')
        with patch.object(subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=secret.encode())):
            with self.assertRaises(RuntimeError) as raised:
                review.api('repos/a/b/pulls/3')
        self.assertEqual(str(raised.exception),
            'GitHub API failed (operation=pr_read, http_status=unknown)')

    def test_cli_api_failure_output_does_not_reflect_secret_error_bytes(self):
        error = io.StringIO()
        args = ['github_review.py', 'collect', '--repo', 'a/b', '--number', '3',
                '--base', 'a'*40, '--head', 'b'*40, '--checkout', '/unused', '--out', '/unused']
        failure = SimpleNamespace(returncode=1, stdout=b'FAKE_RESPONSE_SECRET',
                                  stderr=b'FAKE_ERROR_SECRET (HTTP 403)')
        with patch('sys.argv', args), patch('sys.stderr', error), \
                patch.dict(os.environ, {'GH_TOKEN': 'FAKE_TOKEN_SECRET'}), \
                patch.object(subprocess, 'run', return_value=failure):
            self.assertEqual(review.main(), 1)
        self.assertEqual(error.getvalue(),
            'Review boundary failed: GitHub API failed (operation=pr_read, http_status=403)\n')


if __name__ == '__main__':
    unittest.main()
