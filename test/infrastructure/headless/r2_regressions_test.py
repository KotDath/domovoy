"""Ordinary source lifecycle and pure portable-path checks, without outside writes."""
import hashlib
import importlib.util
import json
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('r2_review', 'tool/headless/github_review.py')
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)


def git(root, *args):
    return subprocess.check_output(['git', '-c', 'core.hooksPath=/dev/null',
        '-c', 'commit.gpgsign=false', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid',
        '-C', str(root), *args]).decode().strip()


class R2Regressions(unittest.TestCase):
    def test_native_drive_root_relative_drive_and_unsafe_syntax_denied_on_every_host(self):
        denied = ['C:/example/file.md', 'C:example.md', 'D:example.md', 'folder/name:stream.md',
                  '/root.md', r'\root.md', r'C:\example\file.md', r'\\server\share\file.md',
                  '//server/share/file.md', r'\\?\C:\file.md', 'a//file.md', 'a/../file.md',
                  'a/./file.md', 'a/file.md/', 'a/nul.py', 'a/CON.txt', 'a/CON .txt', 'a/aux  .py', 'COM1.md', 'Lpt9.py',
                  'a/space /file.md', 'a/dot./file.md', 'a/file?.md', 'a/file*.md',
                  'a/file|.md', 'a/file<.md', 'a/file>.md', 'a/file".md', 'a/\x00file.md', 'a/\nfile.md']
        allowed = ['README.md', 'src/code.py', '.github/workflows/review.yml',
                   'lib/credentials/credential_resolver.dart', 'docs/credentials.md', 'docs/пример.md']
        result = subprocess.run([shutil.which('dart'), 'test/support/headless_source_policy_probe.dart'],
                                input=json.dumps(denied+allowed), capture_output=True, text=True, check=True)
        dart = json.loads(result.stdout)
        for path in denied:
            self.assertFalse(review.valid_repository_path(path), path)
            self.assertFalse(review.permits(path), path)
            self.assertFalse(dart[path], path)
            # This rejects before native resolution or creation; no target write.
            with self.assertRaisesRegex(ValueError, 'Unsafe'):
                review.snapshot_target(Path('not-created-snapshot'), path)
        root = PureWindowsPath('C:/snapshot/sources')
        for path in allowed:
            self.assertTrue(review.valid_repository_path(path), path)
            self.assertTrue(review.permits(path), path)
            self.assertTrue(dart[path], path)
            self.assertTrue((root / path).is_relative_to(root), path)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'sources'
            root.mkdir()
            self.assertEqual(review.snapshot_target(root, 'pkg/file.py'), root/'pkg/file.py')

    def test_empty_whitespace_clear_unchanged_empty_and_deletion_keep_full_receipts(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'repo'
            root.mkdir()
            git(root, 'init', '-q')
            (root/'README.md').write_text('Ordinary package documentation\n')
            (root/'clear.py').write_text('value = 1\n')
            (root/'unchanged.py').write_text('')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'base')
            base = git(root, 'rev-parse', 'HEAD')
            (root/'pkg').mkdir()
            (root/'pkg/__init__.py').write_text('')
            (root/'clear.py').write_text('')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'ordinary empty package and cleared source')
            head = git(root, 'rev-parse', 'HEAD')
            data = review.bundle(root, base, head, 'local/project', Path(tmp)/'empty')
            self.assertEqual(set(data['changed_files']), {'pkg/__init__.py', 'clear.py'})
            for path in ('pkg/__init__.py', 'clear.py', 'unchanged.py'):
                self.assertEqual(data['source_hashes'][path], hashlib.sha256(b'').hexdigest())
                self.assertEqual((Path(tmp)/'empty/sources'/path).read_bytes(), b'')
            (root/'pkg/__init__.py').write_text('  \t\n')
            (root/'clear.py').unlink()
            git(root, 'add', '-A')
            git(root, 'commit', '-qm', 'whitespace and deletion')
            next_head = git(root, 'rev-parse', 'HEAD')
            data = review.bundle(root, head, next_head, 'local/project', Path(tmp)/'whitespace')
            self.assertEqual(set(data['changed_files']), {'pkg/__init__.py', 'clear.py'})
            self.assertEqual(data['source_hashes']['pkg/__init__.py'], hashlib.sha256(b'  \t\n').hexdigest())
            self.assertNotIn('clear.py', data['source_hashes'])
            (root/'pkg/__init__.py').unlink()
            git(root, 'add', '-A')
            git(root, 'commit', '-qm', 'remove package marker')
            data = review.bundle(root, next_head, git(root, 'rev-parse', 'HEAD'), 'local/project', Path(tmp)/'deleted')
            self.assertEqual(data['changed_files'], ['pkg/__init__.py'])
            self.assertNotIn('pkg/__init__.py', data['source_hashes'])
            self.assertIn('unchanged.py', data['source_hashes'])

    def test_literal_binary_phrase_is_text_but_real_binary_metadata_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)/'repo'
            root.mkdir()
            git(root, 'init', '-q')
            (root/'README.md').write_text('Documentation\n')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'base')
            base = git(root, 'rev-parse', 'HEAD')
            (root/'notes.md').write_text('GIT binary patch\nBinary files a/x and b/x differ\n')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'ordinary literal prose')
            head = git(root, 'rev-parse', 'HEAD')
            data = review.bundle(root, base, head, 'local/project', Path(tmp)/'text')
            self.assertIn('+GIT binary patch', data['diff'])
            self.assertEqual(data['changed_files'], ['notes.md'])
            (root/'binary.py').write_bytes(b'\0binary fixture')
            git(root, 'add', '.')
            git(root, 'commit', '-qm', 'binary source')
            out = Path(tmp)/'binary'
            with self.assertRaisesRegex(ValueError, 'Binary diff unsupported'):
                review.bundle(root, head, git(root, 'rev-parse', 'HEAD'), 'local/project', out)
            self.assertFalse(out.exists())


if __name__ == '__main__':
    unittest.main()
