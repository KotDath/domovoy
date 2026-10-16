#!/usr/bin/env python3
"""Export a fresh standalone clone as a bounded mobile-importable USTAR archive."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit, urlunsplit
import zlib

EXCLUDED_DIRECTORIES = {'.dart_tool', 'build', 'node_modules', '.venv', 'venv', '__pycache__',
                        '.idea', '.gradle', 'vendor', 'dist'}
GIT_EXCLUDED = {'hooks', 'logs', 'config', 'FETCH_HEAD'}
SECRET_NAMES = {'.netrc', '_netrc', '.git-credentials', '.gitcookies', '.npmrc',
                '.pypirc', '.dockercfg', '.pgpass', '.my.cnf', '.s3cfg', '.boto',
                '.vault-token', 'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519',
                'id_ecdsa_sk', 'id_ed25519_sk', 'credentials.json',
                'service-account.json', 'application_default_credentials.json'}
SECRET_PATHS = {('.aws', 'credentials'), ('.docker', 'config.json'),
                ('.kube', 'config'), ('.gem', 'credentials'), ('.bundle', 'config'),
                ('.config', 'gh', 'hosts.yml'), ('.config', 'hub'),
                ('.azure', 'accesstokens.json'), ('.azure', 'msal_token_cache.json')}
SECRET_PATTERNS = ['.env*', '*.pem', '*.key', '*.keystore', '*.jks',
                   *sorted(SECRET_NAMES), *sorted('/'.join(p) for p in SECRET_PATHS)]


def git(*args):
    return subprocess.check_output(['git', '--no-replace-objects', *args],
                                   text=True, stderr=subprocess.DEVNULL).strip()


def sensitive_path(path):
    # Concrete file/store names, never ordinary credential-related source/docs.
    parts = tuple(part.lower() for part in Path(path).parts)
    return (any(part.startswith('.env') or part in SECRET_NAMES
                or part.endswith(('.pem', '.key', '.keystore', '.jks')) for part in parts)
            or any(parts[i:i + len(store)] == store
                   for store in SECRET_PATHS for i in range(len(parts))))


def portable_objects(clone, work):
    """Use standard Git, not a pack parser, to preserve real OIDs as loose data."""
    object_format = git('-C', str(clone), 'rev-parse', '--show-object-format')
    if object_format not in {'sha1', 'sha256'}:
        raise ValueError('Unsupported Git object format')
    # Every reachable cloned commit is checked: excluded blobs must not survive
    # in the ODB even when their working-tree path would have been omitted.
    for commit in git('-C', str(clone), 'rev-list', '--all', 'HEAD').splitlines():
        paths = git('-C', str(clone), 'ls-tree', '-r', '-z', '--name-only', commit).split('\0')
        if any(sensitive_path(path) for path in paths if path):
            raise ValueError('Export refused: tracked sensitive file/store paths exist in Git objects; no archive published')
    oids = git('-C', str(clone), 'rev-list', '--objects', '--all', '--no-object-names', 'HEAD').splitlines()
    if len(oids) > 15000:
        raise ValueError('Git snapshot exceeds portable object count limit')
    target = Path(work) / 'portable-objects'
    target.mkdir()
    total = 0
    with subprocess.Popen(['git', '--no-replace-objects', '-C', str(clone), 'cat-file', '--batch'],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL) as process:
        try:
            for oid in oids:
                process.stdin.write((oid + '\n').encode('ascii'))
                process.stdin.flush()
                fields = process.stdout.readline(256).decode('ascii').strip().split(' ')
                if len(fields) != 3 or fields[0] != oid or fields[1] not in {'commit', 'tree', 'blob', 'tag'}:
                    raise ValueError('Unverifiable Git object')
                size = int(fields[2])
                total += size
                if size < 0 or size > 32 * 1024 * 1024 or total > 120 * 1024 * 1024:
                    raise ValueError('Git snapshot exceeds portable object size limit')
                payload = process.stdout.read(size)
                if len(payload) != size or process.stdout.read(1) != b'\n':
                    raise ValueError('Incomplete Git object')
                data = f'{fields[1]} {size}\0'.encode('ascii') + payload
                if hashlib.new(object_format, data).hexdigest() != oid:
                    raise ValueError('Git object identity mismatch')
                directory = target / oid[:2]
                directory.mkdir(exist_ok=True)
                (directory / oid[2:]).write_bytes(zlib.compress(data))
            process.stdin.close()
            if process.wait() != 0:
                raise ValueError('Git object export failed')
        finally:
            if process.poll() is None:
                process.kill()
    shutil.rmtree(clone / '.git' / 'objects')
    target.rename(clone / '.git' / 'objects')
    return object_format


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', help='Public repository URL or authorized local checkout path')
    parser.add_argument('output', type=Path)
    parser.add_argument('--ref', help='Branch or tag to clone (default: source HEAD)')
    args = parser.parse_args()
    source = args.source
    if '://' in source:
        url = urlsplit(source)
        if url.username or url.password or url.query or url.fragment:
            parser.error('Use a credential-free repository URL')
        source = urlunsplit((url.scheme, url.netloc, url.path, '', ''))
    args.output = args.output.resolve()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='domovoy-export-') as work:
        clone = Path(work) / 'checkout'
        command = ['git', 'clone', '--quiet', '--no-local', '--depth', '1']
        if args.ref:
            command += ['--branch', args.ref]
        subprocess.run([*command, '--', source, str(clone)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # Reserve our metadata name before any write. exists() alone misses a
        # dangling symlink; checking directory entries also catches case aliases.
        if any(p.name.lower() == 'project_provenance.json' for p in clone.iterdir()):
            raise ValueError('Project provenance namespace collision')
        object_format = portable_objects(clone, work)
        branch = subprocess.run(['git', '-C', str(clone), 'symbolic-ref', '--short', 'HEAD'],
                                capture_output=True, text=True)
        provenance = {'source': source, 'commit': git('-C', str(clone), 'rev-parse', 'HEAD'),
                      'branch': branch.stdout.strip() if branch.returncode == 0 else None,
                      'requested_ref': args.ref, 'baseline': 'fresh clone; no local modifications',
                      'licenses': [str(p.relative_to(clone)) for p in clone.iterdir()
                                   if p.name.lower().startswith(('license', 'copying'))],
                      'excluded_directories': sorted(EXCLUDED_DIRECTORIES), 'omitted_paths': [],
                      'refused_tracked_secret_patterns': SECRET_PATTERNS,
                      'object_layout': 'verified-loose-v1', 'object_format': object_format,
                      'sanitized_paths': ['.git/config']}
        files = []
        total = 0
        for directory, dirs, names in os.walk(clone, followlinks=False):
            parent = Path(directory)
            def excluded(path):
                rel = path.relative_to(clone)
                name = path.name.lower()
                return (path.is_symlink() or (path.is_dir() and name in EXCLUDED_DIRECTORIES)
                        or name == '.ds_store' or sensitive_path(rel)
                        or (len(rel.parts) > 1 and rel.parts[0] == '.git'
                            and rel.parts[1] in GIT_EXCLUDED))
            for name in list(dirs):
                if excluded(parent / name):
                    dirs.remove(name)
                    provenance['omitted_paths'].append(str((parent / name).relative_to(clone)))
            for name in names:
                path = parent / name
                if excluded(path):
                    provenance['omitted_paths'].append(str(path.relative_to(clone)))
                    continue
                size = path.stat().st_size
                if size > 32 * 1024 * 1024:
                    raise ValueError(f'File exceeds 32 MiB: {path.relative_to(clone)}')
                total += size
                files.append(path)
        if len(files) > 29999 or total > 120 * 1024 * 1024:
            raise ValueError('Checkout exceeds import bounds (30000 entries / 128 MiB archive)')
        tracked = git('-C', str(clone), 'ls-files', '-z').split('\0')
        provenance['omitted_tracked_paths'] = sorted(p for p in tracked if p and any(
            p == omitted or p.startswith(omitted + '/') for omitted in provenance['omitted_paths']))
        # Minimal portable repository config, never host credentials/remotes.
        config = '[core]\nrepositoryformatversion = 0\nbare = false\n'
        if object_format == 'sha256':
            config = '[core]\nrepositoryformatversion = 1\nbare = false\n[extensions]\nobjectFormat = sha256\n'
        (clone / '.git' / 'config').write_text(config, encoding='utf-8')
        files.append(clone / '.git' / 'config')
        manifest = clone / 'PROJECT_PROVENANCE.json'
        with manifest.open('x', encoding='utf-8') as metadata:
            metadata.write(json.dumps(provenance, indent=2) + '\n')
        files.append(manifest)
        temporary = Path(work) / 'project.tar'
        with tarfile.open(temporary, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for path in sorted(set(files)):
                archive.add(path, arcname=str(path.relative_to(clone)), recursive=False)
        if temporary.stat().st_size > 128 * 1024 * 1024:
            raise ValueError('Archive exceeds 128 MiB')
        # Work directory can be on another filesystem.
        with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as out:
            published = Path(out.name)
            try:
                with temporary.open('rb') as src:
                    shutil.copyfileobj(src, out)
            except BaseException:
                published.unlink(missing_ok=True)
                raise
        os.replace(published, args.output)
        args.output.with_suffix('.provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
        print(json.dumps({'archive': str(args.output), 'bytes': args.output.stat().st_size,
                          'commit': provenance['commit'], 'branch': provenance['branch'],
                          'omitted_paths': len(provenance['omitted_paths'])}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.SubprocessError):
        # Never print object data, command input, paths or a Git stderr dump.
        raise SystemExit('Export refused: sensitive tracked paths, unsupported/incoherent Git data, or export limits. No new archive published.')
