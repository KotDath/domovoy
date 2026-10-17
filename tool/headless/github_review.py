#!/usr/bin/env python3
"""Deterministic GitHub boundary. Never executes or checks out PR code.

Only collect/publish use gh credentials. bundle is a local, credential-free
operation over Git objects. Keep its output outside the trusted CLI checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import time

MARKER = '<!-- domovoy-review:v1 -->'
SHA = re.compile(r'^[0-9a-f]{40}$')
REPO = re.compile(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')
EXCLUDED = {'.git', '.ssh', '.aws', '.azure', '.kube', '.docker', '.local', '.dart_tool', 'build', 'node_modules', '.venv', 'venv',
            '__pycache__', '.idea', '.gradle', 'vendor', 'dist', 'coverage',
            '.next', '.cache'}
EXTENSIONS = {'.dart', '.py', '.js', '.ts', '.tsx', '.jsx', '.json', '.yaml', '.yml',
              '.toml', '.ini', '.cfg', '.md', '.markdown', '.rst', '.txt', '.mdx',
              '.c', '.h', '.cpp', '.hpp', '.cc', '.rs', '.go', '.java', '.kt',
              '.swift', '.m', '.mm', '.sh', '.bash', '.sql', '.html', '.css', '.scss',
              '.xml', '.cmake', '.gradle', '.properties', '.rb', '.ex', '.exs', '.vue'}


SENSITIVE_NAMES = {'credentials.yaml', 'secrets.json', 'credentials.json', 'secrets.yaml', 'id_ecdsa', '.git-credentials', '.s3cfg', '.my.cnf', '.dockercfg', '_netrc', '.netrc', '.gitcookies', 'id_dsa', 'secrets.yml', 'id_ed25519', 'id_rsa', '.npmrc', '.pypirc', 'id_ed25519_sk', 'credentials.yml', 'service-account.json', 'application_default_credentials.json', '.vault-token', '.pgpass', '.boto', 'id_ecdsa_sk'}
SENSITIVE_STORES = {('.docker', 'config.json'), ('.config', 'hub'), ('.azure', 'msal_token_cache.json'), ('.config', 'gcloud'), ('.config', 'gh'), ('.azure', 'accesstokens.json'), ('.gem', 'credentials'), ('.kube', 'config'), ('.bundle', 'config'), ('.aws', 'credentials')}

def valid_repository_path(path):
    # Reject alternate native syntax on every host, before native Path joins.
    if (not isinstance(path, str) or not path or path.startswith('/') or
            re.search(r'[:\\<>"|?*\x00-\x1f\x7f]', path)):
        return False
    return all(part not in {'', '.', '..'} and not part.endswith((' ', '.')) and
               not re.fullmatch(r'(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])', part.split('.', 1)[0].rstrip(' '), re.I)
               for part in path.split('/'))


def snapshot_target(root, path):
    if not valid_repository_path(path):
        raise ValueError('Unsafe repository-relative source path')
    root = Path(root).resolve()
    target = root.joinpath(*path.split('/'))
    if target.is_symlink() or not target.resolve().is_relative_to(root):
        raise ValueError('Source target escapes snapshot root')
    return target


def permits(path):
    if not valid_repository_path(path):
        return False
    parts = path.split('/')
    if not parts or any(not p or p in {'.', '..'} or
                        p.lower() in EXCLUDED for p in parts) or '\\' in path:
        return False
    lower = tuple(part.lower() for part in parts)
    if (any(part.startswith('.env') or part in SENSITIVE_NAMES or
            part.endswith(('.pem', '.key', '.keystore', '.jks')) for part in lower) or
            any(lower[i:i+len(store)] == store for store in SENSITIVE_STORES for i in range(len(lower)))):
        return False
    name = lower[-1]
    if name in {'pubspec.lock', 'package-lock.json', 'yarn.lock'}:
        return False
    return PurePosixPath(name).suffix in EXTENSIONS or name in {
        'readme', 'license', 'copying', 'makefile', 'dockerfile', 'cmakelists.txt',
        '.gitignore', '.gitattributes', '.editorconfig', '.dockerignore', '.prettierrc', '.eslintrc', '.tool-versions'}


API_OPERATIONS = {'pr_read', 'files_read', 'comments_read', 'comment_create',
                  'comment_update', 'github_api'}


def api_operation(endpoint, method):
    # Classify trusted routes without reflecting any endpoint or request bytes.
    route = endpoint.split('?', 1)[0]
    for verb, pattern, operation in (
            ('GET', r'repos/[^/]+/[^/]+/pulls/\d+', 'pr_read'),
            ('GET', r'repos/[^/]+/[^/]+/pulls/\d+/files', 'files_read'),
            ('GET', r'repos/[^/]+/[^/]+/issues/\d+/comments', 'comments_read'),
            ('POST', r'repos/[^/]+/[^/]+/issues/\d+/comments', 'comment_create'),
            ('PATCH', r'repos/[^/]+/[^/]+/issues/comments/\d+', 'comment_update')):
        if method == verb and re.fullmatch(pattern, route):
            return operation
    return 'github_api'


def api_failure(operation, stderr=b''):
    operation = operation if operation in API_OPERATIONS else 'github_api'
    # gh's diagnostic suffix is (HTTP NNN). Only bounded numeric metadata may
    # cross this boundary; never reflect its message, headers, body or command.
    status = re.search(rb'\(HTTP ([1-5][0-9]{2})\)', stderr[-8192:])
    status = int(status[1]) if status else 'unknown'
    return RuntimeError(f'GitHub API failed (operation={operation}, http_status={status})')


def run(args, *, cwd=None, body=None, github=False, operation='github_api'):
    # Provider/CI credentials do not reach Git or other subprocesses.
    env = {k: os.environ[k] for k in ('PATH', 'SYSTEMROOT', 'SSL_CERT_FILE') if k in os.environ}
    env['GIT_CONFIG_NOSYSTEM'] = '1'
    env['GIT_CONFIG_GLOBAL'] = os.devnull
    env['GIT_TERMINAL_PROMPT'] = '0'
    env['GH_PROMPT_DISABLED'] = '1'
    if github:
        token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
        if token:
            env['GH_TOKEN'] = token
    with tempfile.TemporaryDirectory(prefix='domovoy-gh-config-') as config:
        env['GH_CONFIG_DIR'] = config
        try:
            result = subprocess.run(args, cwd=cwd, env=env, input=body, capture_output=True, timeout=120)
        except (subprocess.TimeoutExpired, OSError):
            if github:
                raise api_failure(operation) from None
            raise RuntimeError('Git subprocess could not complete') from None
    if result.returncode:
        # Never echo raw stderr/commands: gh diagnostics can contain auth data.
        if github:
            raise api_failure(operation, result.stderr)
        raise RuntimeError('Git operation failed')
    return result.stdout


def git(checkout, *args):
    return run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                '-C', str(checkout), *args])


def api(endpoint, *, method='GET', payload=None, pages=False):
    args = ['gh', 'api', '--method', method, endpoint]
    if pages:
        args += ['--paginate', '--slurp']
    if payload is not None:
        args += ['--input', '-']
    operation = api_operation(endpoint, method)
    output = run(args, body=None if payload is None else json.dumps(payload).encode(),
                 github=True, operation=operation)
    try:
        return json.loads(output)
    except (ValueError, UnicodeDecodeError):
        raise api_failure(operation) from None


def metadata(repo, number):
    if not REPO.fullmatch(repo) or number <= 0:
        raise ValueError('Invalid repository/PR identity')
    data = api(f'repos/{repo}/pulls/{number}')
    validate_metadata(data, repo, number)
    return data


def validate_metadata(data, repo, number):
    if not isinstance(data, dict):
        raise ValueError('Malformed PR metadata')
    base, head = data.get('base'), data.get('head')
    if (not isinstance(base, dict) or not isinstance(head, dict) or
            not isinstance(base.get('repo'), dict) or not isinstance(head.get('repo'), dict)):
        raise ValueError('Malformed PR repository metadata')
    if (data.get('number') != number or data.get('state') != 'open' or
            base['repo'].get('full_name') != repo or
            not isinstance(base.get('sha'), str) or not SHA.fullmatch(base['sha']) or
            not isinstance(head.get('sha'), str) or not SHA.fullmatch(head['sha'])):
        raise ValueError('Malformed/closed PR metadata')
    if head['repo'].get('full_name') != repo:
        raise ValueError('SKIPPED: fork PR is outside the supported trusted-writer policy')


def assert_current(data, base, head):
    if data['head']['sha'] != head or data['base']['sha'] != base:
        raise ValueError('OBSOLETE: current PR base/head changed; no publication')


def tree(checkout, revision):
    entries = {}
    for raw in git(checkout, 'ls-tree', '-rz', '--full-tree', revision).split(b'\0'):
        if not raw:
            continue
        attrs, name = raw.split(b'\t', 1)
        mode, kind, oid = attrs.decode().split()
        path = name.decode('utf-8')
        entries[path] = (mode, kind, oid)
    return entries


def blob(checkout, oid):
    return git(checkout, 'cat-file', 'blob', oid)


def normalize(text):
    return text.removeprefix('\ufeff').replace('\r\n', '\n').replace('\r', '\n')


def bundle(checkout, base, head, repo, out, expected_paths=None, number=None):
    if not SHA.fullmatch(base) or not SHA.fullmatch(head) or not REPO.fullmatch(repo):
        raise ValueError('Invalid revision/repository')
    out = Path(out).resolve()
    checkout = Path(checkout).resolve()
    if out == checkout or checkout in out.parents:
        raise ValueError('Bundle must be outside trusted checkout')
    if out.exists():
        raise ValueError('Bundle output already exists; use a fresh path')
    # Three-dot diff is exactly the PR comparison, even after base advanced.
    merge_base = git(checkout, 'merge-base', base, head).decode().strip()
    paths = [p.decode('utf-8') for p in git(checkout, 'diff', '--no-renames', '--name-only', '-z', merge_base, head, '--').split(b'\0') if p]
    if not paths or any(not permits(p) for p in paths):
        raise ValueError('Changed path is outside supported text-source policy; explicit failure, no partial review')
    if expected_paths is not None and set(paths) != set(expected_paths):
        raise ValueError('GitHub file coverage differs from exact local diff (including renames); no partial review')
    diff = git(checkout, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames', '--full-index', '--unified=5', merge_base, head, '--').decode('utf-8')
    # Structured counts describe binary entries; source hunk prose is data.
    stats = git(checkout, 'diff', '--no-ext-diff', '--no-textconv', '--no-renames',
                '--numstat', '-z', merge_base, head, '--')
    for entry in stats.split(b'\0'):
        if not entry:
            continue
        counts = entry.split(b'\t', 2)
        if len(counts) != 3:
            raise ValueError('Malformed Git diff statistics')
        if counts[0] == b'-' or counts[1] == b'-':
            raise ValueError('Binary diff unsupported; no partial review')
    head_tree = tree(checkout, head)
    base_tree = tree(checkout, base)
    sources, excluded = {}, []
    for path, (mode, kind, oid) in sorted(head_tree.items()):
        if not permits(path):
            continue
        if kind != 'blob' or mode not in {'100644', '100755'}:
            excluded.append(f'{path}: non-regular source')
            continue
        size = int(git(checkout, 'cat-file', '-s', oid))
        if size > 512 * 1024:
            excluded.append(f'{path}: exceeds 512 KiB')
            continue
        try:
            text = blob(checkout, oid).decode('utf-8')
        except UnicodeDecodeError:
            excluded.append(f'{path}: not UTF-8')
            continue
        if '\0' in text:
            excluded.append(f'{path}: binary')
            continue
        sources[path] = normalize(text)
    for path in paths:
        if path in head_tree and path not in sources:
            raise ValueError('Changed head file is not fully readable; no partial review')
        if path in base_tree and base_tree[path][0] not in {'100644', '100755'}:
            raise ValueError('Changed symlink/submodule is unsupported')
    if sum(len(s.encode()) for s in sources.values()) > 20 * 1024 * 1024:
        raise ValueError('Text snapshot exceeds 20 MiB; narrow the PR')
    # PR-focused vector corpus: changed files, their sibling source files, all
    # current docs/READMEs and rule files. Other head sources remain readable.
    parents = {str(PurePosixPath(p).parent) for p in paths}
    rag_paths = [p for p in sources if p in paths or str(PurePosixPath(p).parent) in parents or
                 any(part.lower() in {'doc', 'docs', 'documentation'} for part in p.split('/')[:-1]) or
                 PurePosixPath(p).name.lower().startswith('readme') or PurePosixPath(p).name == 'AGENTS.md']
    rules = {}
    for path, (mode, kind, oid) in sorted(base_tree.items()):
        if PurePosixPath(path).name == 'AGENTS.md' and permits(path) and mode in {'100644', '100755'}:
            raw = blob(checkout, oid)
            if len(raw) > 512 * 1024:
                raise ValueError('Trusted rule file exceeds input limit')
            rules[path] = raw.decode('utf-8')
    data = {'version': 1, 'repository': repo, 'number': number, 'base_sha': base,
            'head_sha': head, 'merge_base_sha': merge_base, 'changed_files': paths,
            'diff': diff, 'trusted_rules': rules, 'rag_paths': rag_paths,
            'source_hashes': {p: hashlib.sha256(s.encode()).hexdigest() for p, s in sources.items()},
            'coverage': {'diff': 'complete three-dot diff, no rename folding',
                         'source_policy': 'source-v3', 'excluded_sources': excluded,
                         'rag_policy': 'changed + sibling code + current docs/README/AGENTS; other text sources readable'}}
    encoded = json.dumps(data, ensure_ascii=False, indent=2)
    if len(encoded.encode()) > 400000:
        raise ValueError('Complete review context exceeds 400000 bytes; split PR (no silent truncation)')
    out.mkdir(parents=True)
    (out / 'sources').mkdir()
    for path, text in sources.items():
        target = snapshot_target(out / 'sources', path)
        target.parent.mkdir(parents=True, exist_ok=True)
        # Recheck resolved containment after parent creation and before writing.
        snapshot_target(out / 'sources', path).write_text(text, encoding='utf-8')
    (out / 'review.json').write_text(encoded, encoding='utf-8')
    print(json.dumps({'bundle': str(out), 'base': base, 'head': head,
                      'changed_paths': len(paths), 'sources': len(sources), 'rag_sources': len(rag_paths)}))
    return data


def collect(args):
    data = metadata(args.repo, args.number)
    assert_current(data, args.base, args.head)
    pages = api(f'repos/{args.repo}/pulls/{args.number}/files?per_page=100', pages=True)
    files = [f for page in pages for f in page]
    if len(files) != data.get('changed_files'):
        raise ValueError('GitHub changed-file pagination is incomplete; no review')
    # --no-renames diff represents rename as a delete+add: expand API old path.
    paths = []
    for file in files:
        paths.append(file['filename'])
        if file.get('status') == 'renamed':
            paths.append(file['previous_filename'])
    bundle(args.checkout, args.base, args.head, args.repo, args.out, paths, args.number)
    assert_current(metadata(args.repo, args.number), args.base, args.head)


def matching_comment(comments):
    matches = [c for c in comments if c.get('user', {}).get('login') == 'github-actions[bot]' and
               c.get('user', {}).get('type') == 'Bot' and c.get('body', '').startswith(MARKER + '\n')]
    if len(matches) > 1:
        raise ValueError('Multiple marked bot comments; refuse ambiguous upsert')
    return matches[0] if matches else None


def publish(args):
    receipt = json.loads(Path(args.context).read_text())
    if receipt.get('repository') != args.repo or receipt.get('number') != args.number:
        raise ValueError('Publication PR identity mismatch')
    base, head = receipt['base_sha'], receipt['head_sha']
    assert_current(metadata(args.repo, args.number), base, head)
    answer = Path(args.result).read_text()
    # Only publish a successful CLI receipt, tied to the expected input identity.
    rows = [json.loads(line) for line in Path(args.events).read_text().splitlines() if line.strip()]
    final = rows[-1] if rows else {}
    if (final.get('type') != 'result' or final.get('success') is not True or
            final.get('head_sha') != head or final.get('base_sha') != base or
            final.get('text', '') + '\n' != answer):
        raise ValueError('Missing/mismatched successful CLI result receipt')
    body = f'{MARKER}\n## Domovoy review\n\nBase: `{base}` · Head: `{head}`\n\n{answer}'
    if len(body.encode()) > 60000:
        raise ValueError('Review exceeds comment limit; no truncation/publication')
    pages = api(f'repos/{args.repo}/issues/{args.number}/comments?per_page=100', pages=True)
    old = matching_comment([c for page in pages for c in page])
    assert_current(metadata(args.repo, args.number), base, head)
    endpoint = f'repos/{args.repo}/issues/comments/{old["id"]}' if old else f'repos/{args.repo}/issues/{args.number}/comments'
    posted = api(endpoint, method='PATCH' if old else 'POST', payload={'body': body})
    # GitHub has no conditional write for a comment vs PR head. Detect the
    # residual race and withdraw the result so it cannot look current.
    try:
        assert_current(metadata(args.repo, args.number), base, head)
    except (ValueError, RuntimeError):
        api(f'repos/{args.repo}/issues/comments/{posted["id"]}', method='PATCH',
            payload={'body': f'{MARKER}\nReview obsolete: PR changed during publication. Waiting for a new run.'})
        raise
    print(json.dumps({'comment_url': posted['html_url'], 'head': head, 'updated': old is not None}))


def safe_rag_progress(row):
    if (row.get('type') != 'rag_progress' or
            not isinstance(row.get('stage'), str) or
            row.get('stage') not in {'chunking', 'embedding'} or
            type(row.get('done')) is not int or type(row.get('total')) is not int or
            not 0 <= row['done'] <= row['total'] <= 1_000_000_000):
        return None
    return {key: row[key] for key in ('stage', 'done', 'total')}


def watch_progress(events, interval=30):
    # Independent observer: never launches/handles the CLI or changes its exit.
    started = stage_started = last_report = time.monotonic()
    latest = None
    stream = None
    pending = ''
    try:
        while True:
            if stream is None and Path(events).exists():
                stream = Path(events).open()
            if stream is not None:
                while line := stream.readline():
                    pending += line
                    if not pending.endswith('\n'):
                        break
                    try:
                        row = json.loads(pending)
                        progress = safe_rag_progress(row) if isinstance(row, dict) else None
                    except ValueError:
                        progress = None
                    pending = ''
                    if progress is not None:
                        if latest is None or latest['stage'] != progress['stage']:
                            stage_started = time.monotonic()
                            last_report = started - interval
                        latest = progress
            now = time.monotonic()
            if now - last_report >= interval:
                print(json.dumps({'type': 'rag_progress_receipt',
                    'elapsed_seconds': int(now - started),
                    'stage_elapsed_seconds': int(now - stage_started) if latest else None,
                    'last_rag_progress': latest}), flush=True)
                last_report = now
            time.sleep(min(interval, 1))
    finally:
        if stream is not None:
            stream.close()


def execution_receipt(events, context):
    rows, malformed = [], 0
    for line in Path(events).read_text().splitlines():
        if not line.strip():
            continue
        try:
            row = json.loads(line)
            if isinstance(row, dict):
                rows.append(row)
            else:
                malformed += 1
        except ValueError:
            malformed += 1
    data = json.loads(Path(context).read_text())
    model = next((r for r in rows if r.get('type') == 'model_selected'), {})
    rag = next((r for r in rows if r.get('type') == 'rag'), {})
    sources = rag.get('corpus_sources', [])
    docs = [p for p in sources if PurePosixPath(p).suffix.lower() in {'.md', '.markdown', '.mdx', '.rst', '.txt'} or PurePosixPath(p).name.lower().startswith('readme')]
    terminal = next((r for r in reversed(rows) if r.get('type') in {'result', 'failed', 'error', 'stopped', 'cancelled'}), {})
    return {'base_sha': data.get('base_sha'), 'head_sha': data.get('head_sha'),
            'provider': model.get('provider'), 'model': model.get('model'),
            'rag_fingerprint': rag.get('fingerprint'), 'rag_generation': rag.get('generation'),
            'rag_cached': rag.get('cached'), 'vector_corpus_document_count': len(docs),
            'vector_corpus_other_source_count': len(sources)-len(docs),
            'retrieved_sources': sorted({c['chunk']['source'] for c in rag.get('candidates', []) if c.get('sent')}),
            'tool_call_count': sum(r.get('type') == 'tool_started' for r in rows),
            'terminal': terminal.get('type', 'missing'),
            'success': terminal.get('type') == 'result' and terminal.get('success') is True,
            'last_rag_progress': next((p for r in reversed(rows) if (p := safe_rag_progress(r)) is not None), None),
            'malformed_event_rows': malformed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('collect', 'bundle'):
        p = sub.add_parser(name)
        for opt in ('checkout', 'base', 'head', 'repo', 'out'):
            p.add_argument('--' + opt, required=True)
        if name == 'collect':
            p.add_argument('--number', type=int, required=True)
    p = sub.add_parser('publish')
    for opt in ('repo', 'context', 'result', 'events'):
        p.add_argument('--' + opt, required=True)
    p.add_argument('--number', type=int, required=True)
    p = sub.add_parser('receipt')
    p.add_argument('--events', required=True)
    p.add_argument('--context', required=True)
    p = sub.add_parser('progress', help='Counts-only observer; does not launch the CLI')
    p.add_argument('--events', required=True)
    args = parser.parse_args()
    try:
        if args.command == 'progress':
            watch_progress(args.events)
        elif args.command == 'receipt':
            print(json.dumps(execution_receipt(args.events, args.context), ensure_ascii=True))
        elif args.command == 'collect': collect(args)
        elif args.command == 'publish': publish(args)
        else: bundle(args.checkout, args.base, args.head, args.repo, args.out)
    except (ValueError, RuntimeError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        # Errors authored here contain identities/coverage only, never raw gh output.
        print(f'Review boundary failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
