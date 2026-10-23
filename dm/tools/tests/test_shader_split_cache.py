"""The NSP shader stage only invalidates for inputs the split and translation actually read."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[3] / 'scripts/build_ipa_from_nsp.py'
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp_cache_test', SCRIPT)
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class Profile:
    def __init__(self, root):
        self.dir = root; self.id = 'fixture'
        self.rows = [('shader_groups', ['a=b']), ('shader_note', ['test']), ('modules', ['main']), ('camera_aspect', ['old'])]
        for name in ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv', 'shader_facts_manual.tsv',
                     'shader_map.tsv.conflicts.tsv', 'bf_want.tsv', 'dmsh_chain.h'):
            (root / name).write_text('table\n')
        self._write_game()

    def table(self, name): return self.dir / name
    def get(self, key, default=None):
        row = next((vs for k, vs in self.rows if k == key), None)
        if row is not None: return '\t'.join(row)
        if default is not None: return default
        raise KeyError(key)
    def words(self, key, default=None): return self.get(key, default).split()
    def _write_game(self):
        (self.dir / 'game.tsv').write_text(''.join(f'{key}\t{chr(9).join(values)}\n' for key, values in self.rows))
    def setrow(self, key, values):
        for i, (existing, _) in enumerate(self.rows):
            if existing == key:
                self.rows[i] = (key, values); self._write_game(); return
        self.rows.append((key, values)); self._write_game()


class QuietProgress:
    def stage(self, *args, **kwargs): pass
    def set(self, **kwargs): pass
    def end(self, *args, **kwargs): pass


class SplitCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name); self.repo = root / 'repo'; profile_dir = root / 'profile'; profile_dir.mkdir()
        self.profile = Profile(profile_dir)
        for rel in nsp.split_tool_files(self.repo):
            rel.parent.mkdir(parents=True, exist_ok=True); rel.write_text(rel.name)
        self.version = root / 'v1'; self.rom = self.version / 'RomFS'; self.rom.mkdir(parents=True)
        (self.rom / 'asset.bin').write_bytes(b'rom')
        self.main = self.version / 'main'; self.main.write_bytes(b'main')
        (self.version / 'glslc_capture').mkdir(); (self.version / 'ue_shaders').mkdir()
        self.pkg = root / 'shader/pkg'; self.logs = root / 'logs'; self.logs.mkdir()
        self.env = {}; self.calls = 0; self.mismatch = False
        self.progress = QuietProgress()

    def fake_run(self, argv, log, **kwargs):
        self.calls += 1
        pkg = Path(argv[4]); pkg.mkdir(parents=True); (pkg / 'vs.bin').write_bytes(b'package')
        for target, name in zip(argv[5:], ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv')):
            data = self.profile.table(name).read_bytes()
            Path(target).write_bytes(data + (b'different row\n' if self.mismatch and name == 'shader_map.tsv' else b''))
        Path(log).write_text('shaders: 1 (')

    def split(self):
        with mock.patch.object(nsp, 'PROG', self.progress), mock.patch.object(nsp, 'run', side_effect=self.fake_run):
            return nsp.split_shaders('python', self.repo, [self.rom], [self.main], self.pkg, self.env, self.logs, self.profile)

    def test_unchanged_and_camera_only_change_reuse(self):
        self.split(); self.split()
        self.profile.setrow('camera_look', ['new'])
        self.split()
        self.assertEqual(self.calls, 1)

    def test_split_tools_game_shader_rules_and_sources_invalidate(self):
        self.split()
        (self.repo / 'dm/gfx/tools/unityfs.py').write_text('changed tool')
        self.split()
        self.profile.setrow('shader_groups', ['a=c'])
        self.split()
        (self.rom / 'asset.bin').write_bytes(b'changed')
        self.split()
        self.assertEqual(self.calls, 4)

    def test_shader_tables_and_capture_files_invalidate(self):
        self.split()
        self.profile.table('shader_facts.tsv').write_text('changed table\n')
        self.split()
        (self.version / 'glslc_capture' / 'one.glslc').write_bytes(b'capture')
        self.split()
        self.assertEqual(self.calls, 3)

    def test_glslc_module_change_invalidates_missing_capture_diagnostic(self):
        self.profile.setrow('modules', ['main moduleX'])
        module = self.version / 'moduleX'; module.write_bytes(b'old module')
        self.split()
        module.write_bytes(b'new module')
        self.split()
        self.assertEqual(self.calls, 2)

    def test_external_capture_override_is_hashed(self):
        external = Path(self.tmp.name) / 'custom-capture'; external.mkdir()
        self.env['DM_GLSLC_CAPTURE'] = str(external)
        self.split()
        (external / 'one.glslc').write_bytes(b'capture')
        self.split()
        self.assertEqual(self.calls, 2)

    def test_unrelated_tools_and_chain_lock_do_not_invalidate_split(self):
        self.split()
        unrelated = self.repo / 'dm/gfx/tools/dmsh_build.py'
        ios_metal = self.repo / 'dm/ios/tools/ios_metal.py'
        lock = self.repo / 'dm/gfx/tools/dmsh_chain.lock'
        for path in (unrelated, ios_metal, lock):
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text('changed')
        self.split()
        self.assertEqual(self.calls, 1)

    def test_missing_package_forces_split(self):
        self.split(); nsp.rmtree(self.pkg)
        self.split()
        self.assertEqual(self.calls, 2)

    def test_different_split_table_is_rejected_without_replacing_profile(self):
        before = {name: self.profile.table(name).read_bytes() for name in ('shader_map.tsv', 'shader_facts.tsv', 'shader_pairs.tsv')}
        self.mismatch = True
        with self.assertRaisesRegex(nsp.BuildError, 'shader_map.tsv'):
            self.split()
        self.assertEqual(before, {name: self.profile.table(name).read_bytes() for name in before})

    def test_translation_key_ignores_camera_rows_but_tracks_shader_rows(self):
        def key():
            return nsp.fingerprint(('files', nsp.shader_profile_files(self.profile)), nsp.shader_profile_rules(self.profile))
        first = key()
        self.profile.rows.append(('camera_look', ['camera']))
        self.assertEqual(first, key())
        self.profile.setrow('shader_tex_dyn_slots', ['on'])
        self.assertNotEqual(first, key())
        second = key()
        self.profile.table('bf_want.tsv').write_text('shader-key\n')
        self.assertNotEqual(second, key())


if __name__ == '__main__': unittest.main()
