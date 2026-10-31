"""NSP script --romfs bundle|separate (scripts/build_ipa_from_nsp.py): the option and setting, and the push_romfs.sh command printed for a separate build. No game files or Xcode needed."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import sys
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec is not None and spec.loader is not None
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
spec = importlib.util.spec_from_file_location('romfs_image', REPO / 'dm/tools/romfs_image.py')
assert spec is not None and spec.loader is not None
romfs_image = importlib.util.module_from_spec(spec); spec.loader.exec_module(romfs_image)


class RomfsOption(unittest.TestCase):
    def test_separate_image_combines_dlc_and_reuses_unchanged_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); base = root / 'base'; base.mkdir(); (base / 'marker').write_bytes(b'base')
            aoc = root / 'aoc'; (aoc / '1').mkdir(parents=True); (aoc / '1/content').write_bytes(b'dlc')
            work = root / 'build'; logs = work / 'logs'
            with mock.patch.object(nsp, 'PROG', nsp.Progress()), mock.patch('sys.stdout'):
                image = nsp.separate_game_image(sys.executable, REPO, work, base, aoc, dict(nsp.os.environ), logs)
                self.assertEqual(image, work / 'game-data/RomFS.img')
                self.assertEqual((nsp.rfs.Path(image) / 'romfs/marker').read_bytes(), b'base')
                self.assertEqual((nsp.rfs.Path(image) / 'aoc/1/content').read_bytes(), b'dlc')
                checked = subprocess.run([sys.executable, str(REPO / 'dm/tools/romfs.py'), str(image), 'marker'], capture_output=True)
                self.assertEqual(checked.returncode, 0, checked.stderr)
                before = image.stat()
                self.assertEqual(nsp.separate_game_image(sys.executable, REPO, work, base, aoc, dict(nsp.os.environ), logs), image)
                self.assertEqual((image.stat().st_ino, image.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
                self.assertEqual(nsp.separate_game_image(sys.executable, REPO, work, base, None, {}, logs), base)

    def test_push_transfers_one_combined_image_from_project_or_image(self):
        with tempfile.TemporaryDirectory(prefix='Combined game ') as temporary:
            root = Path(temporary); base = root / 'base'; base.mkdir(); (base / 'marker').write_bytes(b'base')
            aoc = root / 'aoc'; (aoc / '2').mkdir(parents=True); (aoc / '2/file').write_bytes(b'dlc')
            gen = root / 'xcode/Gen'; gen.mkdir(parents=True)
            resource_env = gen / 'resources.env'
            resource_env.write_text(''.join(f'{key}={shlex.quote(str(value))}\n' for key, value in
                [('DM_RESOURCE_ROMFS', base), ('DM_RESOURCE_AOC', aoc), ('DM_RESOURCE_MARKER', 'marker')]))
            bin_dir = root / 'bin'; bin_dir.mkdir(); args_file = root / 'copy.json'
            xcrun = bin_dir / 'xcrun'
            xcrun.write_text(f'#!{sys.executable}\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ["PUSH_ARGS"]).write_text(json.dumps(sys.argv[1:]))\n')
            xcrun.chmod(0o755)
            environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], PUSH_ARGS=str(args_file))
            combined = gen / 'game-data/RomFS.img'
            for source in (resource_env, combined):
                result = subprocess.run(['bash', str(REPO / 'scripts/push_romfs.sh'), 'fixture-device', 'org.fixture', str(source)],
                                        env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = json.loads(args_file.read_text())
                self.assertEqual(args[args.index('--source') + 1], str(combined))
                self.assertEqual(args[args.index('--destination') + 1], 'Documents/romfs.img')
                self.assertEqual((nsp.rfs.Path(combined) / 'romfs/marker').read_bytes(), b'base')
                self.assertEqual((nsp.rfs.Path(combined) / 'aoc/2/file').read_bytes(), b'dlc')

    def test_option_and_setting(self):
        self.assertEqual(nsp.ROMFS, 'bundle')   # the default build is the one that always was
        self.assertIsNone(nsp.parse_args([]).romfs)
        self.assertEqual(nsp.parse_args(['--romfs', 'separate']).romfs, 'separate')
        with self.assertRaises(SystemExit), mock.patch('sys.stderr'): nsp.parse_args(['--romfs', 'maybe'])

    def test_removed_separate_rom_option_is_rejected(self):
        for flag in ('--separate-rom', '--no-separate-rom'):
            with self.subTest(flag=flag), self.assertRaises(SystemExit), mock.patch('sys.stderr'):
                nsp.parse_args([flag])

    def test_separate_cannot_be_a_mac_build(self):
        with tempfile.TemporaryDirectory() as t, mock.patch.object(nsp, 'apple_silicon', return_value=True):
            with self.assertRaises(nsp.BuildError) as e: nsp.main(nsp.parse_args(['--platform', 'mac', '--romfs', 'separate', '-k', t, t]))
            self.assertIn('--romfs separate', str(e.exception))

    def test_separate_requires_keeping_the_image_for_deployment(self):
        for options, settings in ((['--romfs', 'separate', '--no-keep-extracted'], {'ROMFS': 'bundle', 'KEEP_EXTRACTED': True}),
                                  ([], {'ROMFS': 'separate', 'KEEP_EXTRACTED': False})):
            with self.subTest(options=options, settings=settings), tempfile.TemporaryDirectory() as t, mock.patch.multiple(nsp, **settings):
                with self.assertRaises(nsp.BuildError) as e:
                    nsp.main(nsp.parse_args([*options, '-k', t, t]))
                self.assertIn('--romfs separate requires --keep-extracted', str(e.exception))

    def test_push_command_names_the_image(self):
        said = []
        with tempfile.TemporaryDirectory() as t, mock.patch.object(nsp.PROG, 'say', side_effect=said.append):
            src = Path(t) / 'src'; (src / 'Data').mkdir(parents=True); (src / 'Data' / 'a').write_bytes(b'x')
            romfs_image.pack(src, Path(t) / 'RomFS.img')
            image = nsp.rfs.source(t)   # as main passes it: a romfs.Path, which sees the image's root as a folder (GitHub issue #530)
            nsp.say_push_romfs(image, 'org.nxnative.01007ef00011e000')
            text = '\n'.join(said)
            self.assertIn(f'scripts/push_romfs.sh <device UDID> org.nxnative.01007ef00011e000 "{image}"', text)
            self.assertIn('needed again only when the image changed', text)
            self.assertNotIn('[RED]', text)
            said.clear(); nsp.say_push_romfs(nsp.rfs.Path(src), 'org.x'); self.assertIn('[RED]', '\n'.join(said))   # a folder has no identity


if __name__ == '__main__':
    unittest.main()
