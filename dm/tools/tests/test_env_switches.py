"""docs/env_switches.tsv lists every DM_* switch the code reads, each with a class and a meaning (dm/tools/env_switches.py writes it; class and meaning are kept by hand).
A switch the code reads that the table does not list, a row for a switch nothing reads any more, or a row without a meaning fails here."""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('env_switches', REPO / 'dm/tools/env_switches.py')
assert spec is not None and spec.loader is not None
switches = importlib.util.module_from_spec(spec)
spec.loader.exec_module(switches)


class EnvSwitches(unittest.TestCase):
    def test_doc_key_families_are_not_complete_switches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'dm/games').mkdir(parents=True)
            (root / 'dm/games/settings.tsv').write_text('')
            (root / 'README.md').write_text('`DM_SHOW_FPS` `DM_SHOW_FPS=1` `DM_FAMILY_` `DM_FAMILY_A_*`')
            (root / 'dm/example.c').write_text('getenv("DM_SHOW_FPS")')
            with patch.object(switches, 'REPO', root), patch.object(switches, 'tracked', return_value=['README.md', 'dm/example.c']):
                reads, docs = switches.scan()
            self.assertEqual(set(reads), {'DM_SHOW_FPS'})
            self.assertEqual(set(docs), {'DM_SHOW_FPS'})

    def test_table_is_current_and_complete(self):
        r = subprocess.run([sys.executable, str(REPO / 'dm/tools/env_switches.py'), '--check'], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
