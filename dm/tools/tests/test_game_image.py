"""Combined external game images: direct reads, metadata reuse and atomic failure.

All inputs are small synthetic files; no game extraction or host build is used.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import game_image
import romfs
import romfs_image


class GameImages(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / 'base'; (self.base / 'Data/empty').mkdir(parents=True)
        (self.base / 'Data/a').write_bytes(b'base bytes')
        (self.base / 'Data/zero').touch()
        self.base_image = self.root / 'RomFS.img'; romfs_image.pack(self.base, self.base_image)
        self.aoc = self.root / 'aoc'; self.aoc.mkdir()
        self.dst = self.root / 'game.img'

    def dlc(self, index, data=b'DLC bytes', folder=False):
        source = self.aoc / str(index) if folder else self.root / ('dlc-' + str(index))
        (source / 'content/empty').mkdir(parents=True)
        (source / 'content/a').write_bytes(data)
        if folder: return source
        image = self.aoc / (str(index) + '.img'); romfs_image.pack(source, image); return image

    def virtual(self): return romfs.Path(self.dst)

    def mutate_image(self, path, entry, data):
        before = path.stat()
        _, offset, size = romfs_image.read_index(path)[entry]
        self.assertEqual(len(data), size)
        with path.open('r+b') as f: f.seek(offset); f.write(data)
        os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))

    def test_images_are_flattened_and_read_directly_without_extracting(self):
        first = self.dlc(1); second = self.dlc(10, b'another DLC')
        with patch.object(game_image.rfi, 'entries', side_effect=AssertionError('images must not be expanded')), \
             patch.object(game_image, '_copy', wraps=game_image._copy) as copied:
            count = game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertEqual(copied.call_count, 3)   # one contiguous data range per input image
        expected_sizes = [p.stat().st_size - romfs_image.HEAD.size - len(romfs.Image(p).index) for p in (self.base_image, first, second)]
        self.assertEqual([call.args[2] for call in copied.call_args_list], expected_sizes)
        image = romfs.Image(self.dst); self.assertEqual(count, image.count)
        root = self.virtual()
        self.assertEqual([p.name for p in root.iterdir()], ['aoc', 'romfs'])
        self.assertEqual((root / 'romfs/Data/a').read_bytes(), b'base bytes')
        self.assertEqual((root / 'romfs/Data/zero').read_bytes(), b'')
        self.assertEqual((root / 'aoc/1/content/a').read_bytes(), b'DLC bytes')
        self.assertEqual((root / 'aoc/10/content/a').read_bytes(), b'another DLC')
        self.assertTrue((root / 'romfs/Data/empty').is_dir())
        self.assertTrue((root / 'aoc/1/content/empty').is_dir())
        self.assertEqual(list(root.rglob('*.img')), [])
        # Every final file range belongs to this image, not a nested image blob.
        for p in root.rglob('*'):
            if not p.is_file(): continue
            entry = image.entry(image.find(p.relative_to(root).as_posix()))
            with self.dst.open('rb') as f:
                f.seek(entry[0]); self.assertEqual(f.read(entry[1]), p.read_bytes())

    def test_empty_romfs_and_no_dlc_keep_both_root_directories(self):
        empty = self.root / 'empty'; empty.mkdir()
        for aoc in (None, '-', self.aoc):
            with self.subTest(aoc=aoc):
                self.assertEqual(game_image.pack(empty, aoc, self.dst), 3)
                self.assertTrue((self.virtual() / 'romfs').is_dir())
                self.assertEqual(list((self.virtual() / 'aoc').iterdir()), [])

    def test_macos_metadata_does_not_become_dlc(self):
        self.dlc(1)
        (self.aoc / '.DS_Store').write_bytes(b'finder metadata')
        (self.aoc / '._1.img').write_bytes(b'extended attributes')
        game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertEqual([p.name for p in (self.virtual() / 'aoc').iterdir()], ['1'])

    def test_unchanged_reuse_never_copies_file_data(self):
        self.dlc(1)
        count = game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        identity = romfs_image.file_identity(self.dst)
        with patch.object(game_image._Source, 'copy', side_effect=AssertionError('unchanged images must not be copied')):
            self.assertEqual(game_image.pack(self.base_image, self.aoc, self.dst, reuse=True), count)
        self.assertEqual(romfs_image.file_identity(self.dst), identity)

    def test_packaged_identities_accept_the_original_base_only_with_a_current_output_stamp(self):
        self.dlc(1)
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        ids = self.root / 'identities'; game_image.write_identities(self.dst, ids, 'T', '1.0', 'v0')
        self.assertTrue(romfs_image.same_identity((ids / 'romfs.id').read_text(), romfs_image.identity(self.dst)))
        self.assertTrue(romfs_image.same_identity((ids / 'romfs.base.id').read_text(), romfs_image.identity(self.base_image)))
        self.base_image.unlink()   # preparing the app reads the recorded identity, not another full game image
        result = subprocess.run([sys.executable, '-I', str(REPO / 'dm/tools/game_image.py'), '--identities', str(self.dst), str(ids), 'T', '1.0', 'v0'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr); self.assertTrue((ids / 'romfs.base.id').exists())
        self.mutate_image(self.dst, 'romfs/Data/a', b'next bytes')   # the old stamp no longer describes this output
        game_image.write_identities(self.dst, ids)
        self.assertFalse((ids / 'romfs.base.id').exists())
        (ids / 'romfs.base.id').write_text('stale')
        plain = self.root / 'plain.img'; romfs_image.pack(self.base, plain)
        game_image.write_identities(plain, ids)
        self.assertFalse((ids / 'romfs.base.id').exists())

    def test_reuse_detects_same_size_base_and_dlc_writes_with_restored_mtime(self):
        dlc = self.dlc(1)
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.mutate_image(self.base_image, 'Data/a', b'next bytes')
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.assertEqual((self.virtual() / 'romfs/Data/a').read_bytes(), b'next bytes')
        self.mutate_image(dlc, 'content/a', b'new bytes')
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.assertEqual((self.virtual() / 'aoc/1/content/a').read_bytes(), b'new bytes')

    def test_reuse_detects_dlc_additions_and_removals(self):
        first = self.dlc(1)
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.dlc(2)
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.assertEqual([p.name for p in (self.virtual() / 'aoc').iterdir()], ['1', '2'])
        first.unlink()
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        self.assertEqual([p.name for p in (self.virtual() / 'aoc').iterdir()], ['2'])

    def test_legacy_folders_preserve_guest_names_and_invalidate_changed_children(self):
        dlc = self.dlc(2, folder=True)
        (self.base / '.dm-case-1').write_bytes(b'guest name')
        guest = romfs_image.guest
        def name(parent, host): return 'A' if host == '.dm-case-1' else guest(parent, host)
        with patch.object(game_image.rfi, 'guest', side_effect=name):
            game_image.pack(self.base, self.aoc, self.dst, reuse=True)
            self.assertEqual((self.virtual() / 'romfs/A').read_bytes(), b'guest name')
            self.assertTrue((self.virtual() / 'aoc/2/content/empty').is_dir())
            (dlc / 'content/a').write_bytes(b'changed DLC')
            (self.base / 'Data/a').rename(self.base / 'Data/renamed')
            game_image.pack(self.base, self.aoc, self.dst, reuse=True)
        self.assertEqual((self.virtual() / 'aoc/2/content/a').read_bytes(), b'changed DLC')
        self.assertEqual((self.virtual() / 'romfs/Data/renamed').read_bytes(), b'base bytes')
        self.assertFalse((self.virtual() / 'romfs/Data/a').exists())

    def test_invalid_dlc_names_and_duplicate_numeric_indices_are_rejected(self):
        first = self.dlc(1)
        for name in ('extra.img', '01.img', '1'):
            with self.subTest(name=name):
                duplicate = self.aoc / name
                if name == '1': duplicate.mkdir()
                else: duplicate.write_bytes(first.read_bytes())
                with self.assertRaisesRegex(ValueError, 'non-numeric|duplicate DLC index'):
                    game_image.pack(self.base_image, self.aoc, self.dst)
                self.assertFalse(self.dst.exists())
                if duplicate.is_dir(): duplicate.rmdir()
                else: duplicate.unlink()

    def test_self_overwrite_and_outputs_inside_sources_are_rejected(self):
        before = self.base_image.read_bytes()
        for destination in (self.base_image, self.base / 'out.img', self.aoc / 'out.img'):
            with self.subTest(destination=destination), self.assertRaisesRegex(ValueError, 'overlaps its source'):
                game_image.pack(self.base if destination.parent == self.base else self.base_image, self.aoc, destination)
        self.assertEqual(self.base_image.read_bytes(), before)
        # A hard-linked scratch path must not truncate an input before copying it.
        scratch = Path(str(self.dst) + '.part'); os.link(self.base_image, scratch)
        with self.assertRaisesRegex(ValueError, 'overlaps its source'):
            game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertEqual(self.base_image.read_bytes(), before)

    def test_input_mutation_during_copy_does_not_publish_a_mixed_image(self):
        self.dlc(1)
        game_image.pack(self.base_image, self.aoc, self.dst, reuse=True)
        before = self.dst.read_bytes(); stamp = Path(str(self.dst) + '.inputs.json').read_bytes()
        copy = game_image._copy
        changed = False
        def mutate(src, out, size):
            nonlocal changed
            copy(src, out, size)
            if not changed:
                changed = True
                self.mutate_image(self.base_image, 'Data/a', b'next bytes')
        with patch.object(game_image, '_copy', side_effect=mutate), self.assertRaisesRegex(RuntimeError, 'changed while packing'):
            game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertEqual(self.dst.read_bytes(), before)
        self.assertEqual(Path(str(self.dst) + '.inputs.json').read_bytes(), stamp)
        self.assertFalse(Path(str(self.dst) + '.part').exists())

    def test_failed_copy_or_invalid_source_never_publishes_an_incomplete_output(self):
        def fail(src, out, size):
            out.write(b'partial data'); raise OSError('synthetic copy failure')
        with patch.object(game_image, '_copy', side_effect=fail), self.assertRaisesRegex(OSError, 'copy failure'):
            game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertFalse(self.dst.exists()); self.assertFalse(Path(str(self.dst) + '.part').exists())
        self.base_image.write_bytes(self.base_image.read_bytes()[:-1])
        with self.assertRaises(ValueError): game_image.pack(self.base_image, self.aoc, self.dst)
        self.assertFalse(self.dst.exists())

    def test_changed_output_is_not_reused_and_cli_works_in_isolated_mode(self):
        command = [sys.executable, '-I', str(REPO / 'dm/tools/game_image.py'), '--reuse', str(self.base_image), '-', str(self.dst)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('entries, ', result.stdout)
        self.dst.write_bytes(b'incomplete')
        game_image.pack(self.base_image, None, self.dst, reuse=True)
        self.assertEqual((self.virtual() / 'romfs/Data/a').read_bytes(), b'base bytes')
        (self.aoc / 'wrong.img').touch()
        command[-2] = str(self.aoc)
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('[RED] non-numeric DLC index', result.stderr)


if __name__ == '__main__': unittest.main()
