#!/usr/bin/env python3
"""Export a fresh standalone clone as a bounded mobile-importable USTAR archive."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit, urlunsplit

EXCLUDED = {'.dart_tool', 'build', 'node_modules', '.venv', 'venv', '__pycache__',
            '.idea', '.gradle', 'vendor', 'dist', '.env', '.DS_Store'}
GIT_EXCLUDED = {'hooks', 'logs', 'config', 'FETCH_HEAD'}


def git(*args):
    return subprocess.check_output(['git', *args], text=True, stderr=subprocess.DEVNULL).strip()


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
        branch = subprocess.run(['git', '-C', str(clone), 'symbolic-ref', '--short', 'HEAD'],
                                capture_output=True, text=True)
        provenance = {'source': source, 'commit': git('-C', str(clone), 'rev-parse', 'HEAD'),
                      'branch': branch.stdout.strip() if branch.returncode == 0 else None,
                      'requested_ref': args.ref, 'baseline': 'fresh clone; no local modifications',
                      'licenses': [str(p.relative_to(clone)) for p in clone.iterdir()
                                   if p.name.lower().startswith(('license', 'copying'))],
                      'excluded': sorted(EXCLUDED), 'omitted_paths': [],
                      'secret_file_patterns': ['.env*', '*.pem', '*.key', '*.keystore', '*.jks', 'id_rsa', 'id_ed25519', 'credentials.json', 'service-account.json'],
                      'sanitized_paths': ['.git/config']}
        files = []
        total = 0
        for directory, dirs, names in os.walk(clone, followlinks=False):
            parent = Path(directory)
            def excluded(path):
                rel = path.relative_to(clone)
                name = path.name.lower()
                return (path.is_symlink() or name in {s.lower() for s in EXCLUDED}
                        or name.startswith('.env') or name in {'id_rsa', 'id_ed25519', 'credentials.json', 'service-account.json'}
                        or name.endswith(('.pem', '.key', '.keystore', '.jks'))
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
        (clone / '.git' / 'config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n', encoding='utf-8')
        files.append(clone / '.git' / 'config')
        manifest = clone / 'PROJECT_PROVENANCE.json'
        manifest.write_text(json.dumps(provenance, indent=2) + '\n', encoding='utf-8')
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
                    import shutil
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
    main()
