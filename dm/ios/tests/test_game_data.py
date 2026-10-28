"""Python packer → actual Swift importer, including rejected and interrupted imports."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/ios/tools'))
import game_data


class GameDataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler_dir = tempfile.TemporaryDirectory()
        cls.reader = Path(cls.compiler_dir.name) / 'reader'
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(REPO / 'dm/ios/Sources/GameData.swift'),
                        str(REPO / 'dm/ios/tests/game_data_harness.swift'), '-o', str(cls.reader)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.compiler_dir.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.romfs, self.aoc, self.documents = [self.root / p for p in ('romfs', 'aoc', 'documents')]
        for folder in (self.romfs / 'empty', self.aoc / '7', self.documents / 'save'):
            folder.mkdir(parents=True)
        (self.romfs / 'marker').write_bytes(b'game' * 300000)  # multiple streaming chunks
        (self.romfs / '中文 file').touch()
        (self.aoc / '7/content').write_bytes(b'dlc')
        (self.documents / 'save/progress').write_bytes(b'keep')
        self.out, self.metadata, self.stamp = [self.root / p for p in ('Game.nxrom', 'expected.json', 'stamp.json')]

    def pack(self, out=None, metadata=None, stamp=None):
        return game_data.pack(out or self.out, self.romfs, self.aoc, '010015100B514000', '1.2.1', 'marker',
                              metadata or self.metadata, stamp)

    def reader_run(self, package=None, ready=False, succeeds=True):
        command = [str(self.reader), 'ready' if ready else 'install', str(self.metadata), str(self.documents)]
        if not ready:
            command.append(str(package or self.out))
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, succeeds, result.stdout + result.stderr)
        return result

    def test_round_trip_determinism_and_cache(self):
        first = self.pack(stamp=self.stamp)
        before = self.out.stat().st_mtime_ns
        self.assertEqual(self.pack(stamp=self.stamp), first)
        self.assertEqual(self.out.stat().st_mtime_ns, before)
        # Changing source timestamps or output location does not change package identity.
        os.utime(self.romfs / 'marker', (1, 1))
        second = self.pack(self.root / 'other.nxrom', self.root / 'other.json')
        self.assertEqual(first, second)
        self.assertEqual(hashlib.sha256(self.out.read_bytes()).hexdigest(), first['sha256'])
        self.reader_run()
        self.assertEqual((self.documents / 'game-data/romfs/marker').read_bytes(), (self.romfs / 'marker').read_bytes())
        self.assertTrue((self.documents / 'game-data/romfs/empty').is_dir())
        self.assertTrue((self.documents / 'game-data/romfs/中文 file').exists())
        self.assertEqual((self.documents / 'game-data/aoc/7/content').read_bytes(), b'dlc')
        self.reader_run(ready=True)
        # A killed earlier import must not consume the space needed for its retry.
        staging = self.documents / '.game-data-import'
        staging.mkdir()
        (staging / 'partial').write_bytes(b'incomplete')
        self.reader_run(ready=True)
        self.assertFalse(staging.exists())
        # Settings/name/version metadata do not require reimporting unchanged content.
        descriptor = json.loads(self.metadata.read_bytes())
        descriptor['version'] = 'custom display version'
        self.metadata.write_bytes(game_data.json_bytes(descriptor))
        self.reader_run(ready=True)

    def test_image_input_keeps_the_existing_import_format(self):
        import romfs_image
        self.pack()
        expected = self.out.read_bytes()
        image = self.root / 'RomFS.img'
        romfs_image.pack(self.romfs, image)
        game_data.pack(self.out, image, self.aoc, '010015100B514000', '1.2.1', 'marker', self.metadata)
        self.assertEqual(self.out.read_bytes(), expected)
        self.reader_run()

    def test_update_corruption_and_recovery_preserve_previous_data_and_saves(self):
        old = self.pack()
        self.reader_run()
        (self.aoc / '7/content').write_bytes(b'new dlc')
        new = self.pack()
        self.assertNotEqual(old['sha256'], new['sha256'])
        self.reader_run(ready=True, succeeds=False)
        corrupt = self.root / 'corrupt.nxrom'
        data = bytearray(self.out.read_bytes()); data[-1] ^= 1
        corrupt.write_bytes(data)
        result = self.reader_run(corrupt, succeeds=False)
        self.assertIn('verification failed', result.stderr)
        self.assertEqual((self.documents / 'game-data/aoc/7/content').read_bytes(), b'dlc')
        self.assertFalse((self.documents / '.game-data-import').exists())
        self.reader_run()
        self.assertEqual((self.documents / 'game-data/aoc/7/content').read_bytes(), b'new dlc')
        # Simulate process termination between the two directory renames.
        (self.documents / 'game-data').rename(self.documents / '.game-data-backup')
        self.reader_run(ready=True)
        self.assertEqual((self.documents / 'save/progress').read_bytes(), b'keep')

    def test_reject_truncated_wrong_type_and_unsafe_indices(self):
        descriptor = self.pack()
        original = self.out.read_bytes()
        for data in (original[:-1], b'notanNSP' + original[8:]):
            self.out.write_bytes(data)
            self.reader_run(succeeds=False)
        for table in (
            {'directories': ['romfs'], 'files': [{'path': 'romfs/../escaped', 'size': 1}]},
            {'directories': ['romfs'], 'files': [{'path': 'romfs/file', 'size': 1}] * 2},
            {'directories': ['romfs'], 'files': [{'path': '/escaped', 'size': 1}]},
            {'directories': ['romfs'], 'files': [{'path': 'romfs/missing/file', 'size': 1}]},
            {'directories': ['romfs'], 'files': [{'path': 'romfs/file', 'size': 2**64 - 1}]},
        ):
            index = game_data.json_bytes(table)
            data = game_data.MAGIC + struct.pack('<Q', len(index)) + index + b'xx'
            self.out.write_bytes(data)
            descriptor.update(size=len(data), sha256=hashlib.sha256(data).hexdigest())
            self.metadata.write_bytes(game_data.json_bytes(descriptor))
            self.reader_run(succeeds=False)
        self.assertFalse((self.documents / 'escaped').exists())
        self.assertFalse((self.documents / 'game-data').exists())

    def test_empty_romfs_and_symlinks(self):
        shutil.rmtree(self.romfs)
        self.romfs.mkdir()
        game_data.pack(self.out, self.romfs, None, 'empty', '1', '.', self.metadata)
        self.reader_run()
        self.assertTrue((self.documents / 'game-data/romfs').is_dir())
        (self.romfs / 'link').symlink_to(self.aoc / '7/content')
        with self.assertRaisesRegex(ValueError, 'regular files'):
            game_data.pack(self.out, self.romfs, None, 'empty', '1', '.', self.metadata)


if __name__ == '__main__':
    unittest.main()
