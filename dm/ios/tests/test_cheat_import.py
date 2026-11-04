"""Exercise the production iOS cheat file importer with synthetic files on macOS."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class CheatImportTests(unittest.TestCase):
    def test_import_builds_companions_and_backups(self):
        with tempfile.TemporaryDirectory() as temporary:
            scratch = Path(temporary)
            executable = scratch / 'cheat_import_check'
            result = subprocess.run([
                'xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-parse-as-library',
                '-module-cache-path', str(scratch / 'modules'), '-o', str(executable),
                str(REPO / 'dm/ios/Sources/CheatFiles.swift'),
                str(REPO / 'dm/ios/tests/cheat_import_check.swift'),
            ], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('cheat import: passed', result.stdout)


if __name__ == '__main__':
    unittest.main()
