"""Real filesystem and legacy-wire compatibility checks, using synthetic saves."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from typing import Any

REPO = Path(__file__).resolve().parents[3]
GAME = '010015100B514000'
OTHER_GAME = '01007EF00011E000'
SPEC = importlib.util.spec_from_file_location('saves_cli', REPO / 'scripts/saves.py')
if SPEC is None or SPEC.loader is None:
    raise ImportError('cannot load the save command')
CLI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CLI)


@unittest.skipUnless(sys.platform == 'darwin', 'the shared backend uses Apple Foundation')
class SaveManager(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tool = CLI.native_tool()
        cls.build = tempfile.TemporaryDirectory(prefix='save-manager-driver-')
        cls.driver = Path(cls.build.name) / 'driver'
        subprocess.run(['xcrun', 'clang', '-O1', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                        '-fobjc-arc', '-framework', 'Foundation', str(REPO / 'dm/host/tests/save_manager_driver.m'),
                        str(REPO / 'dm/host/save_manager.m'), str(REPO / 'dm/host/save_sync.c'), '-larchive', '-o', str(cls.driver)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='save-manager-')
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name).resolve()
        self.root = self.folder / 'Mac'
        self.phone = self.folder / 'Phone'
        self.cloud = self.folder / 'Cloud'
        self.env = dict(os.environ, DM_SAVE_SYNC=str(self.cloud))

    def call(self, command, *args, root=None, game=GAME, success=True) -> Any:
        result = subprocess.run([str(self.tool), str(root or self.root), game, command, *map(str, args)],
                                env=self.env, capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.returncode, 1, result.stderr)
        return result.stderr

    def prepare(self, root=None, success=True) -> Any:
        result = subprocess.run([str(self.driver), 'prepare', str(root or self.root), GAME],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return Path(result.stdout.strip()).resolve() if success else result.stderr

    def legacy(self, path):
        result = subprocess.run([str(self.driver), 'legacy', str(path), GAME],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)

    @staticmethod
    def put(path, contents):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    @staticmethod
    def set_guest_name(path, value):
        subprocess.run(['xattr', '-wx', 'org.d2rmobile.guest-name', value.hex(), str(path)], check=True)

    @staticmethod
    def guest_name(path):
        return bytes.fromhex(subprocess.check_output(['xattr', '-px', 'org.d2rmobile.guest-name', str(path)], text=True))

    def save(self, slot='default', root=None):
        return (root or self.root) / 'saves' / slot / 'save'

    def test_restartable_migration_keeps_both_saves_sync_and_backups(self):
        self.put(self.root / 'save/progress.dat', 'account')
        self.put(self.root / 'save_device/device.dat', 'device')
        self.put(self.root / 'save.sync', 'base\t' + '1' * 32 + '\n')
        self.put(self.root / 'save-backups/player-copy/save/old.dat', 'old')
        self.set_guest_name(self.root / 'save/progress.dat', b'Progress.dat')
        # Simulate an interruption after the first directory has moved.
        stage = self.root / 'saves/staging/legacy'
        stage.mkdir(parents=True)
        (stage / 'migration.json').write_text(json.dumps({'slot_id': 'default', 'title_id': GAME}))
        (self.root / 'save').rename(stage / 'save')
        save = self.prepare()
        self.assertEqual(save, self.save())
        self.assertEqual((save / 'progress.dat').read_text(), 'account')
        self.assertEqual(self.guest_name(save / 'progress.dat'), b'Progress.dat')
        self.assertEqual((save.parent / 'save_device/device.dat').read_text(), 'device')
        self.assertTrue((save.parent / 'save.sync').is_file())
        self.assertEqual((save.parent / 'save-backups/player-copy/save/old.dat').read_text(), 'old')
        self.assertFalse((self.root / 'save_device').exists())
        self.assertFalse((self.root / 'save-backups').exists())
        self.assertEqual(self.prepare(), save)

    def test_corrupt_selection_recovers_backup_and_never_guesses_between_slots(self):
        self.call('list')
        a = self.call('create', 'Second')['id']
        self.call('select', a)
        current = self.root / 'saves/current.json'
        current.write_text('{cut')
        self.assertEqual(self.prepare(), self.save())  # previous valid selection
        current.write_text('{cut')
        (self.root / 'saves/current.json.bak').write_text('[]')
        self.assertIsNone(self.call('list')['current'])
        self.assertIn('select one', self.prepare(success=False))
        self.assertEqual(len(self.call('list')['slots']), 2)
        self.call('select', a)
        self.assertEqual(self.prepare(), self.save(a))
        # A syntactically valid path escape must not be treated as a slot.
        current.write_text(json.dumps({'version': 1, 'slot_id': '../outside'}))
        (self.root / 'saves/current.json.bak').unlink()
        self.prepare(success=False)

    def test_single_slot_recovers_without_any_selection_or_info(self):
        self.call('list')
        (self.root / 'saves/current.json').unlink()
        (self.save().parent / 'info.json').write_text('null')
        self.assertEqual(self.prepare(), self.save())
        self.assertEqual(len(self.call('list')['slots']), 1)

    def test_copy_rename_export_import_and_trash_preserve_raw_game_data(self):
        self.call('list')
        self.put(self.save() / 'game.dat', 'original')
        self.put(self.save().parent / 'save_device/common.dat', 'device')
        self.set_guest_name(self.save() / 'game.dat', b'Game.dat')
        self.put(self.save().parent / 'save.sync', 'base\t' + '1' * 32 + '\n')
        slot = self.call('copy', 'default', 'Second')['id']
        self.assertFalse((self.save(slot).parent / 'save.sync').exists())
        self.call('rename', slot, 'Renamed')
        self.assertEqual(next(item['name'] for item in self.call('list')['slots'] if item['id'] == slot), 'Renamed')
        archive = self.folder / 'portable.dmsync'
        self.call('export', slot, archive)
        data = archive.read_bytes()
        self.call('export', slot, archive, success=False)
        self.assertEqual(archive.read_bytes(), data)
        imported = self.call('import', archive, 'Imported')['id']
        self.assertNotEqual(imported, slot)
        self.assertEqual((self.save(imported) / 'game.dat').read_text(), 'original')
        self.assertEqual(self.guest_name(self.save(imported) / 'game.dat'), b'Game.dat')
        self.assertEqual((self.save(imported).parent / 'save_device/common.dat').read_text(), 'device')
        self.call('select', slot)
        self.call('delete', slot, success=False)
        self.call('select', 'default')
        self.call('delete', slot)
        self.assertFalse(self.save(slot).exists())
        self.call('restore', slot)
        self.assertEqual((self.save(slot) / 'game.dat').read_text(), 'original')
        self.call('delete', 'default', success=False)

    def test_export_ignores_work_and_backups_and_refuses_a_non_directory_save(self):
        self.call('list')
        self.put(self.save() / 'main', 'committed')
        self.put(self.save().parent / 'save.work/main', 'uncommitted')
        backups = self.save().parent / 'save-backups'
        backups.mkdir()
        (backups / 'player-link').symlink_to(self.folder)
        archive = self.folder / 'only-committed.dmsync'
        self.call('export', 'default', archive)
        slot = self.call('import', archive, 'Committed')['id']
        self.assertEqual((self.save(slot) / 'main').read_text(), 'committed')
        self.assertFalse((self.save(slot).parent / 'save.work').exists())
        self.save().rename(self.save().with_name('kept-original'))
        self.save().write_text('a file in place of the save directory')
        self.assertIn('must be a directory', self.prepare(success=False))
        self.call('export', 'default', self.folder / 'bad.dmsync', success=False)
        self.assertEqual(self.save().read_text(), 'a file in place of the save directory')

    def test_external_import_validation_and_no_partial_publication(self):
        self.call('list')
        raw = self.folder / 'raw'
        self.put(raw / 'main', 'raw-save')
        imported = self.call('import-raw', raw, 'Raw')['id']
        self.assertEqual((self.save(imported) / 'main').read_text(), 'raw-save')
        (raw / 'escape').symlink_to(self.folder)
        before = len(self.call('list')['slots'])
        self.call('import-raw', raw, 'Bad', success=False)
        self.call('import-raw', self.root, 'Recursive', success=False)
        archive = self.folder / 'bad.dmsync'
        self.call('export', 'default', archive)
        archive.write_bytes(archive.read_bytes()[:-1])
        self.call('import', archive, 'Cut', success=False)
        other = self.folder / 'other.dmsync'
        self.call('export', 'default', other, game=OTHER_GAME, root=self.folder / 'OtherGame')
        self.call('import', other, 'Wrong game', success=False)
        self.assertEqual(len(self.call('list')['slots']), before)
        self.assertFalse((self.root / 'escape').exists())

    def test_zip_export_is_standard_and_preserves_committed_data_and_guest_names(self):
        self.call('list')
        self.call('rename', 'default', 'Portable save')
        self.put(self.save() / 'userdata/progress.dat', 'account progress')
        self.put(self.save() / 'name-\u6d4b\u8bd5.dat', 'unicode')
        self.put(self.save() / 'userdata/._game', 'game-owned hidden file')
        self.put(self.save().parent / 'save_device/common.dat', 'device progress')
        (self.save() / 'empty').mkdir()
        self.set_guest_name(self.save() / 'userdata', b'UserData')
        self.set_guest_name(self.save() / 'userdata/progress.dat', b'Progress.dat')
        os.utime(self.save() / 'userdata/progress.dat', (1577934246, 1577934246))
        for path in ('save.sync', 'save.work/main', 'save-backups/old/save/main'):
            self.put(self.save().parent / path, 'private')
        archive = self.folder / 'nxnative-portable.zip'
        self.call('export', 'default', archive)
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            wrappers = {name.split('/')[0] for name in package.namelist()}
            self.assertEqual(len(wrappers), 1)
            wrapper = wrappers.pop()
            self.assertTrue(wrapper.startswith('nxnative-' + GAME + '-'))
            self.assertEqual(package.read(wrapper + '/save/userdata/progress.dat'), b'account progress')
            self.assertEqual(package.read(wrapper + '/save_device/common.dat'), b'device progress')
            self.assertIn(wrapper + '/save/empty/', package.namelist())
            info = json.loads(package.read(wrapper + '/info.json'))
            self.assertEqual(info['title_id'], GAME)
            self.assertEqual(info['name'], 'Portable save')
            self.assertIn('save/userdata/progress.dat', info['guest_names'])
            self.assertFalse(any('save.sync' in p or 'save.work' in p or 'save-backups' in p for p in package.namelist()))
        original = archive.read_bytes()
        self.call('export', 'default', archive, success=False)
        self.assertEqual(archive.read_bytes(), original)
        imported = self.call('import', archive)['id']
        self.assertEqual((self.save(imported) / 'userdata/progress.dat').read_text(), 'account progress')
        self.assertEqual((self.save(imported) / 'userdata/._game').read_text(), 'game-owned hidden file')
        self.assertEqual(self.guest_name(self.save(imported) / 'userdata'), b'UserData')
        self.assertEqual(self.guest_name(self.save(imported) / 'userdata/progress.dat'), b'Progress.dat')
        self.assertLess((self.save(imported) / 'userdata/progress.dat').stat().st_mtime, 1600000000)
        self.assertEqual((self.save(imported).parent / 'save_device/common.dat').read_text(), 'device progress')
        self.assertTrue((self.save(imported) / 'empty').is_dir())
        self.assertNotIn('guest_names', json.loads((self.save(imported).parent / 'info.json').read_text()))
        before = len(self.call('list', root=self.phone, game=OTHER_GAME)['slots'])
        self.assertIn('different game', self.call('import', archive, root=self.phone, game=OTHER_GAME, success=False))
        self.assertEqual(len(self.call('list', root=self.phone, game=OTHER_GAME)['slots']), before)
        self.assertEqual(self.call('list')['current'], 'default')

    def test_exported_zip_can_be_extracted_into_saves_and_started_without_importing(self):
        self.call('list')
        self.put(self.save() / 'userdata/progress.dat', 'manual progress')
        self.set_guest_name(self.save() / 'userdata/progress.dat', b'Progress.dat')
        archive = self.folder / 'manual.zip'
        self.call('export', 'default', archive)
        with zipfile.ZipFile(archive) as package:
            package.extractall(self.phone / 'saves')
        inventory = self.call('list', root=self.phone)
        slot = next(item['id'] for item in inventory['slots'] if item['id'] != 'default')
        self.call('select', slot, root=self.phone)
        save = self.prepare(root=self.phone)
        self.assertEqual((save / 'userdata/progress.dat').read_text(), 'manual progress')
        self.assertEqual(self.guest_name(save / 'userdata/progress.dat'), b'Progress.dat')
        self.assertNotIn('guest_names', json.loads((save.parent / 'info.json').read_text()))
        (save / 'userdata/progress.dat').unlink()
        self.assertEqual(self.prepare(root=self.phone), save)
        imported = self.call('import', save.parent, 'Folder copy')['id']
        self.assertTrue((self.save(imported) / 'userdata').is_dir())

    def test_zip_file_name_metadata_rejects_invalid_values_and_path_escapes(self):
        self.call('list')
        self.put(self.save() / 'main', 'kept')
        before = self.call('list')
        for index, names in enumerate(({'save/../../outside': 'YQ=='}, {'save/main': '*'}, {'save/missing': 'YQ=='}, ['not a map'], {'save/main': 1})):
            with self.subTest(names=names):
                archive = self.compressed('zip', 'bad-names-' + str(index), {
                    'a/info.json': json.dumps({'title_id': GAME, 'guest_names': names}), 'a/save/main': 'new'})
                self.assertIn('metadata is invalid', self.call('import', archive, success=False))
                self.assertEqual(len(self.call('list')['slots']), len(before['slots']))
                self.assertEqual(self.call('list')['current'], before['current'])
                self.assertEqual((self.save() / 'main').read_text(), 'kept')

    def test_zip_export_handles_empty_saves_and_removes_failed_output(self):
        self.call('list')
        archive = self.folder / 'empty.zip'
        self.call('export', 'default', archive)
        imported = self.call('import', archive)['id']
        self.assertTrue(self.save(imported).is_dir())
        self.assertEqual(list(self.save(imported).iterdir()), [])
        deep = self.save().joinpath(*(['d'] * 32), 'main')
        self.put(deep, 'kept')
        destination = self.folder / 'too-deep.zip'
        self.assertIn('ZIP import limits', self.call('export', 'default', destination, success=False))
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.folder.glob('too-deep.zip.*.tmp')), [])
        self.assertEqual(deep.read_text(), 'kept')
        self.assertEqual(self.call('list')['current'], 'default')

    def compressed(self, kind, name, files):
        archive = self.folder / (name + '.' + kind)
        if kind == 'zip':
            with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as package:
                for path, contents in files.items():
                    info = zipfile.ZipInfo(path, (2020, 1, 2, 3, 4, 6))
                    info.external_attr = (stat.S_IFREG | 0o644) << 16
                    package.writestr(info, contents)
        else:
            source = self.folder / (name + '-source')
            for path, contents in files.items():
                p = source / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(contents.encode() if isinstance(contents, str) else contents)
                os.utime(p, (1577934246, 1577934246))
            subprocess.run(['/usr/bin/bsdtar', '--format=7zip', '-cf', str(archive), '-C', str(source), '.'],
                           check=True, capture_output=True, text=True)
        return archive

    def test_zip_and_7z_accept_all_three_layouts_and_preserve_game_subdirectories(self):
        self.call('list')
        self.put(self.save() / 'main', 'existing progress')
        data = {'0/progress.dat': 'first', '1/progress.dat': 'second',
                'settings.dat': 'options', 'name-\u6d4b\u8bd5.dat': 'unicode'}
        for kind in ('zip', '7z'):
            for index, prefix in enumerate(('', 'a/', 'a/save/')):
                with self.subTest(kind=kind, prefix=prefix):
                    archive = self.compressed(kind, f'layout-{kind}-{index}', {prefix + p: value for p, value in data.items()})
                    command = 'import-inside' if prefix == 'a/' else 'import'
                    slot = self.call(command, archive)['id']
                    for path, value in data.items():
                        self.assertEqual((self.save(slot) / path).read_text(), value)
                    self.assertEqual(len(list(self.save(slot).rglob('*.dat'))), len(data))
                    self.assertLess((self.save(slot) / '0/progress.dat').stat().st_mtime, 1600000000)
                    self.assertFalse((self.save(slot).parent / '.unpack').exists())
                    self.assertEqual(self.call('list')['current'], 'default')
                    self.assertEqual((self.save() / 'main').read_text(), 'existing progress')

    def test_archive_with_one_numeric_game_slot_keeps_that_directory(self):
        for kind in ('zip', '7z'):
            archive = self.compressed(kind, 'numeric-' + kind, {'0/progress.dat': 'progress'})
            self.assertIn('needs_layout', self.call('import', archive))
            slot = self.call('import-root', archive)['id']
            self.assertEqual((self.save(slot) / '0/progress.dat').read_text(), 'progress')
            self.assertFalse((self.save(slot) / 'progress.dat').exists())

    def test_recognized_numbered_progress_keeps_its_directory_through_wrappers(self):
        files = {'3/game_data.sav': 'progress', '3/caption.sav': 'caption', '3/caption.jpg': 'image'}
        self.call('list', game=OTHER_GAME)
        self.put(self.save() / 'option.sav', 'existing progress')
        for kind in ('zip', '7z'):
            for index, prefix in enumerate(('', 'backup/', '20261106/', 'backup/20261106/', 'a/save/')):
                with self.subTest(kind=kind, prefix=prefix):
                    archive = self.compressed(kind, f'numbered-{kind}-{index}', {prefix + p: data for p, data in files.items()})
                    for command in ('import', 'import-inside'):
                        result = self.call(command, archive, game=OTHER_GAME)
                        self.assertEqual(result['count'], 1)
                        save = self.save(result['id'])
                        for path, contents in files.items():
                            self.assertEqual((save / path).read_text(), contents)
                        self.assertEqual({p.relative_to(save).as_posix() for p in save.rglob('*') if p.is_file()}, set(files))
                        self.assertFalse((save / 'game_data.sav').exists())
        with_options = self.compressed('zip', 'with-options', {'option.sav': 'options', **files})
        result = self.call('import', with_options, game=OTHER_GAME)
        self.assertEqual((self.save(result['id']) / 'option.sav').read_text(), 'options')
        self.assertEqual((self.save() / 'option.sav').read_text(), 'existing progress')

    def test_selecting_a_numbered_progress_directory_preserves_its_name(self):
        source = self.folder / 'external/3'
        files = {'game_data.sav': 'progress', 'caption.sav': '', 'caption.jpg': 'image'}
        for path, contents in files.items():
            self.put(source / path, contents)
        operations = [('import', (source,)), ('import-inside', (source,)), ('import-raw', (source,)),
                      ('import-many', (json.dumps([str(source)]), '{}'))]
        for command, args in operations:
            with self.subTest(command=command):
                result = self.call(command, *args, game=OTHER_GAME)
                save = self.save(result['id'])
                for path, contents in files.items():
                    self.assertEqual((save / '3' / path).read_text(), contents)
                    self.assertFalse((save / path).exists())
        self.assertEqual((source / 'game_data.sav').read_text(), 'progress')

    def test_loose_progress_files_require_their_numbered_parent_without_publishing(self):
        self.call('list', game=OTHER_GAME)
        self.put(self.save() / 'option.sav', 'existing progress')
        before = self.call('list', game=OTHER_GAME)
        files = {'game_data.sav': 'progress', 'caption.sav': 'caption', 'caption.jpg': 'image'}
        for kind in ('zip', '7z'):
            for index, prefix in enumerate(('', 'backup/', 'backup/inner/')):
                archive = self.compressed(kind, f'loose-{index}', {prefix + p: data for p, data in files.items()})
                message = self.call('import', archive, game=OTHER_GAME, success=False)
                self.assertIn('numbered folder', message)
                self.assertEqual(self.call('list', game=OTHER_GAME), before)
        loose = self.folder / 'loose'
        for path, contents in files.items():
            self.put(loose / path, contents)
        valid = self.compressed('zip', 'valid-first', {'option.sav': 'other progress'})
        message = self.call('import-many', json.dumps([str(valid), str(loose)]), '{}', game=OTHER_GAME, success=False)
        self.assertIn('numbered folder', message)
        self.assertEqual(self.call('list', game=OTHER_GAME), before)
        self.assertFalse(any((self.root / 'saves/staging').iterdir()))

    def test_single_folder_import_requires_a_real_layout_choice_without_publishing(self):
        self.call('list')
        self.put(self.save() / 'option.sav', 'existing')
        for kind in ('zip', '7z'):
            archive = self.compressed(kind, 'dated-' + kind, {
                '20261105/option.sav': 'options', '20261105/3/progress.bin': 'progress',
                '20261105/3/caption.sav': 'caption', '20261105/3/caption.jpg': 'image'})
            before = self.call('list')
            layout = self.call('import', archive)['needs_layout']
            self.assertEqual(layout['folder'], '20261105')
            self.assertIn('option.sav', layout['files'])
            self.assertEqual(self.call('list'), before)
            self.assertFalse(any((self.root / 'saves/staging').iterdir()))
            result = self.call('import-many', json.dumps([str(archive)]), json.dumps({str(archive): 'inside'}))
            self.assertEqual(result['count'], 1)
            self.assertEqual((self.save(result['id']) / '3/progress.bin').read_text(), 'progress')
            self.assertFalse((self.save(result['id']) / '20261105').exists())
        archive = self.compressed('zip', 'game-directory', {'game-folder/main': 'game-owned directory'})
        self.assertIn('needs_layout', self.call('import', archive))
        slot = self.call('import-root', archive)['id']
        self.assertEqual((self.save(slot) / 'game-folder/main').read_text(), 'game-owned directory')
        self.assertEqual((self.save() / 'option.sav').read_text(), 'existing')

    def test_layout_choice_handles_adjacent_notes_and_real_game_root_files(self):
        self.call('list')
        for kind in ('zip', '7z'):
            packed = self.compressed(kind, 'notes-' + kind, {
                'README.txt': 'backup instructions', '20261105/option.sav': 'options',
                '20261105/3/game_data.sav': 'progress'})
            before = self.call('list')
            layout = self.call('import', packed)['needs_layout']
            self.assertEqual(layout['folder'], '20261105')
            self.assertIn('README.txt', layout['root_files'])
            self.assertEqual(self.call('list'), before)
            slot = self.call('import-inside', packed)['id']
            self.assertEqual((self.save(slot) / 'option.sav').read_text(), 'options')
            self.assertEqual((self.save(slot) / '3/game_data.sav').read_text(), 'progress')
            self.assertFalse((self.save(slot) / '20261105').exists())
            self.assertFalse((self.save(slot) / 'README.txt').exists())
            raw = self.compressed(kind, 'root-' + kind, {'option.sav': 'root options', '3/game_data.sav': 'root progress'})
            layout = self.call('import', raw)['needs_layout']
            self.assertEqual(layout['folder'], '3')
            self.assertIn('option.sav', layout['root_files'])
            slot = self.call('import-root', raw)['id']
            self.assertEqual((self.save(slot) / 'option.sav').read_text(), 'root options')
            self.assertEqual((self.save(slot) / '3/game_data.sav').read_text(), 'root progress')
            self.assertFalse((self.save(slot) / 'game_data.sav').exists())

    def test_export_multiple_saves_restores_names_data_and_preferred_save_as_new_copies(self):
        self.call('list')
        self.put(self.save() / 'main', 'legacy progress')
        a = self.call('create', 'Normal')['id']
        b = self.call('create', 'Master')['id']
        self.put(self.save(a) / 'main', 'normal progress')
        self.put(self.save(b) / '3/game_data.sav', 'master progress')
        self.put(self.save(b).parent / 'save_device/main', 'device')
        self.put(self.save(b) / '3/._game', 'literal hidden file')
        self.set_guest_name(self.save(b) / '3/game_data.sav', b'Game_Data.sav')
        self.call('select', b)
        archive = self.folder / 'multiple.zip'
        self.assertEqual(self.call('export-many', json.dumps([a, b]), archive)['count'], 2)
        with zipfile.ZipFile(archive) as package:
            self.assertIsNone(package.testzip())
            manifest = json.loads(package.read('saves/library.json'))
            self.assertEqual(len(manifest['slots']), 2)
            selected = json.loads(package.read('saves/' + manifest['current'] + '/info.json'))
            self.assertEqual(selected['name'], 'Master')
        self.call('list', root=self.phone)
        self.put(self.save(root=self.phone) / 'main', 'phone legacy')
        result = self.call('import', archive, root=self.phone)
        self.assertEqual(result['count'], 2)
        self.assertTrue(set(result['ids']).isdisjoint({a, b, 'default'}))
        slots = {item['name']: item['id'] for item in self.call('list', root=self.phone)['slots']}
        self.assertEqual(result['id'], slots['Master'])
        self.assertEqual((self.save(slots['Normal'], root=self.phone) / 'main').read_text(), 'normal progress')
        self.assertEqual((self.save(slots['Master'], root=self.phone) / '3/._game').read_text(), 'literal hidden file')
        self.assertEqual(self.guest_name(self.save(slots['Master'], root=self.phone) / '3/game_data.sav'), b'Game_Data.sav')
        self.assertEqual((self.save(slots['Master'], root=self.phone).parent / 'save_device/main').read_text(), 'device')
        self.assertEqual((self.save(root=self.phone) / 'main').read_text(), 'phone legacy')
        self.call('import', archive, root=self.phone)
        self.assertEqual(len(self.call('list', root=self.phone)['slots']), 5)
        self.assertEqual(self.call('list')['current'], b)
        all_archive = self.folder / 'all.zip'
        self.assertEqual(self.call('export-many', '[]', all_archive)['count'], 3)
        with zipfile.ZipFile(all_archive) as package:
            package.extractall(self.folder / 'manual-library')
        self.assertEqual(self.call('import', self.folder / 'manual-library')['count'], 3)
        single_archive = self.folder / 'one-selected.zip'
        self.assertEqual(self.call('export-many', json.dumps([a]), single_archive)['count'], 1)
        self.assertEqual(self.call('import', single_archive)['count'], 1)
        original = archive.read_bytes()
        self.call('export-many', '[]', archive, success=False)
        self.assertEqual(archive.read_bytes(), original)

    def test_multiple_import_sources_and_wrong_game_in_any_entry_publish_nothing(self):
        self.call('list')
        self.put(self.save() / 'main', 'original')
        native = self.folder / 'one.dmsync'
        self.call('export', 'default', native)
        directory = self.folder / 'two'
        self.put(directory / 'option.sav', 'folder')
        packed = self.compressed('zip', 'three', {'a/save/main': 'third', 'save/save/main': 'fourth'})
        result = self.call('import-many', json.dumps([str(native), str(directory), str(packed)]), '{}')
        self.assertEqual(result['count'], 4)
        main_files = [self.save(slot) / 'main' for slot in result['ids']]
        self.assertEqual({path.read_text() for path in main_files if path.is_file()}, {'original', 'third', 'fourth'})
        native_pack = self.compressed('zip', 'native-pack', {'one.dmsync': native.read_bytes(), 'two.dmsync': native.read_bytes()})
        self.assertEqual(self.call('import', native_pack)['count'], 2)
        before = self.call('list')
        bad = self.compressed('zip', 'wrong-entry', {
            'a/save/main': 'valid', 'b/save/main': 'wrong', 'b/info.json': json.dumps({'title_id': OTHER_GAME})})
        self.assertIn('different game', self.call('import-many', json.dumps([str(native), str(bad)]), '{}', success=False))
        self.assertEqual(self.call('list'), before)
        self.assertFalse(any((self.root / 'saves/staging').iterdir()))
        self.call('export-many', json.dumps(['default', 'default']), self.folder / 'duplicates.zip', success=False)
        self.assertFalse((self.folder / 'duplicates.zip').exists())
        for inputs in ('[null]', '[1]', json.dumps([str(self.folder) + '\x00/ignored'])):
            self.call('import-many', inputs, '{}', success=False)
            self.assertEqual(self.call('list'), before)

    def test_terminal_import_layout_multi_file_import_and_selected_export(self):
        def run(*args):
            return subprocess.run([sys.executable, str(REPO / 'scripts/saves.py'), '--game', GAME,
                                   '--root', str(self.root), *map(str, args)], env=self.env,
                                  capture_output=True, text=True, timeout=30)
        self.call('list')
        archive = self.compressed('zip', 'terminal-dated', {'20261105/option.sav': 'options', '20261105/3/game_data.sav': 'progress'})
        result = run('import', archive)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn('--layout inside', result.stderr)
        self.assertEqual(len(self.call('list')['slots']), 1)
        result = run('import', archive, '--layout', 'inside')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['count'], 1)
        a = self.compressed('zip', 'terminal-one', {'main': 'one'})
        b = self.compressed('zip', 'terminal-two', {'main': 'two'})
        result = run('import', a, b)
        self.assertEqual(result.returncode, 0, result.stderr)
        imported = json.loads(result.stdout)
        self.assertEqual(imported['count'], 2)
        exported = self.folder / 'terminal-chosen.zip'
        result = run('export-many', exported, *imported['ids'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['count'], 2)
        result = run('import', exported)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['count'], 2)
        self.assertEqual(self.call('list')['current'], 'default')

    def test_batch_manifest_is_validated_before_any_save_is_published(self):
        self.call('list')
        manifest = {'format': 'nxnative-save-library', 'version': 1, 'title_id': GAME, 'slots': ['a', 'b'], 'current': 'b'}
        files = {'saves/library.json': json.dumps(manifest), 'saves/a/save/main': 'one', 'saves/b/save/main': 'two'}
        for value in (['a', '../outside'], ['a', 'a'], ['a', 'missing']):
            manifest['slots'] = value
            files['saves/library.json'] = json.dumps(manifest)
            archive = self.compressed('zip', 'invalid-manifest', files)
            self.call('import', archive, success=False)
            self.assertEqual(len(self.call('list')['slots']), 1)
        manifest.update(slots=['a', 'b'], title_id=OTHER_GAME)
        files['saves/library.json'] = json.dumps(manifest)
        self.assertIn('different game', self.call('import', self.compressed('zip', 'wrong-library', files), success=False))
        self.assertEqual(len(self.call('list')['slots']), 1)
        self.assertFalse(any((self.root / 'saves/staging').iterdir()))

    def test_interrupted_batch_publication_resumes_without_replacing_existing_saves(self):
        self.call('list')
        self.put(self.save() / 'main', 'existing')
        slots = ['12e7fc2a-fc62-4d2b-ab2b-87dc6c317f06', '326d44c1-a7f7-49bf-a214-d22bd68e9439']
        job = self.root / 'saves/staging/import-resume'
        for slot in slots:
            self.put(job / 'entries' / slot / 'save/main', slot)
            self.put(job / 'entries' / slot / 'info.json', json.dumps({'name': slot, 'title_id': GAME, 'import_batch': job.name}))
        self.put(job / 'batch.json', json.dumps({'version': 1, 'title_id': GAME, 'ids': slots}))
        (job / 'entries' / slots[0]).rename(self.save(slots[0]).parent)
        self.assertEqual(len(self.call('list')['slots']), 3)
        self.assertFalse(job.exists())
        self.assertEqual((self.save() / 'main').read_text(), 'existing')
        for slot in slots:
            self.assertEqual((self.save(slot) / 'main').read_text(), slot)
        self.assertEqual(self.call('list')['current'], 'default')

    def test_batch_recovery_refuses_an_unrelated_destination_and_keeps_both_copies(self):
        self.call('list')
        slot = '12e7fc2a-fc62-4d2b-ab2b-87dc6c317f06'
        job = self.root / 'saves/staging/import-collision'
        self.put(job / 'entries' / slot / 'save/main', 'staged')
        self.put(job / 'entries' / slot / 'info.json', json.dumps({'title_id': GAME, 'import_batch': job.name}))
        self.put(job / 'batch.json', json.dumps({'version': 1, 'title_id': GAME, 'ids': [slot]}))
        self.put(self.save(slot) / 'main', 'unrelated')
        self.assertIn('without replacing', self.call('list', success=False))
        self.assertEqual((self.save(slot) / 'main').read_text(), 'unrelated')
        self.assertEqual((job / 'entries' / slot / 'save/main').read_text(), 'staged')

    def test_rar_and_rar5_import_real_archive_payloads(self):
        fixtures = REPO / 'dm/tools/tests/fixtures/save_archives'
        cases = [('test_read_format_rar_windows.rar', 'test.txt', b'test text file\r\n'),
                 ('test_read_format_rar5_stored.rar', 'helloworld.txt', b'hello libarchive test suite!\n')]
        for name, path, expected in cases:
            with self.subTest(archive=name):
                slot = self.call('import', fixtures / name)['id']
                self.assertEqual((self.save(slot) / path).read_bytes(), expected)
        compressed = self.call('import', fixtures / 'test_read_format_rar5_compressed.rar')['id']
        data = (self.save(compressed) / 'test.bin').read_bytes()
        self.assertEqual(len(data), 1200)
        self.assertEqual(hashlib.sha256(data).hexdigest(), '588870a2dade35c2650fbb7898c9a9c7f21fce7c281198604e8d0c9737f2c375')
        link = fixtures / 'test_read_format_rar.rar'
        self.assertIn('Links', self.call('import', link, success=False))

    def test_compressed_wrapper_retains_device_save_and_refuses_other_game_or_pending_data(self):
        files = {'a/save/progress.dat': 'account', 'a/save_device/device.dat': 'device',
                 'a/info.json': json.dumps({'title_id': GAME}), 'a/save.sync': 'private baseline'}
        archive = self.compressed('zip', 'wrapped-device', files)
        slot = self.call('import', archive)['id']
        self.assertEqual((self.save(slot) / 'progress.dat').read_text(), 'account')
        self.assertEqual((self.save(slot).parent / 'save_device/device.dat').read_text(), 'device')
        self.assertFalse((self.save(slot).parent / 'save.sync').exists())
        before = len(self.call('list')['slots'])
        files['a/info.json'] = json.dumps({'title_id': OTHER_GAME})
        wrong = self.compressed('zip', 'wrong-game', files)
        self.assertIn('different game', self.call('import', wrong, success=False))
        files['a/info.json'] = json.dumps({'title_id': GAME})
        files['a/cloud-pending'] = '{}'
        pending = self.compressed('zip', 'pending', files)
        self.assertIn('Download', self.call('import', pending, success=False))
        self.assertEqual(len(self.call('list')['slots']), before)

    def test_native_archive_can_also_be_inside_a_zip(self):
        self.call('list')
        self.put(self.save() / 'main', 'native progress')
        native = self.folder / 'portable.dmsync'
        self.call('export', 'default', native)
        packed = self.compressed('zip', 'portable', {'backup/portable.dmsync': native.read_bytes()})
        slot = self.call('import', packed)['id']
        self.assertEqual((self.save(slot) / 'main').read_text(), 'native progress')

    def test_bad_compressed_imports_keep_current_data_and_leave_no_partial_slot(self):
        self.call('list')
        self.put(self.save() / 'main', 'kept')
        before = self.call('list')['current']
        cases = ({'../escape.dat': 'escape'}, {'/absolute.dat': 'escape'},
                 {'C:/escape.dat': 'escape'}, {'..\\escape.dat': 'escape'},
                 {'A.dat': 'first', 'a.dat': 'second'}, {})
        for index, files in enumerate(cases):
            with self.subTest(index=index):
                archive = self.compressed('zip', 'invalid-' + str(index), files)
                self.call('import', archive, success=False)
        link = self.folder / 'link.zip'
        with zipfile.ZipFile(link, 'w') as package:
            info = zipfile.ZipInfo('escape')
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            package.writestr(info, '/tmp/outside')
        self.call('import', link, success=False)
        duplicate = self.folder / 'duplicate.zip'
        with zipfile.ZipFile(duplicate, 'w') as package:
            package.writestr('main', 'first')
            with self.assertWarns(UserWarning):
                package.writestr('main', 'second')
        self.call('import', duplicate, success=False)
        corrupt = self.compressed('zip', 'corrupt', {'main': 'checksum contents'})
        raw = bytearray(corrupt.read_bytes())
        start = 30 + len('main')
        raw[start] ^= 0x40
        corrupt.write_bytes(raw)
        self.call('import', corrupt, success=False)
        cut = self.compressed('zip', 'cut', {'main': 'must be complete'})
        cut.write_bytes(cut.read_bytes()[:-15])
        self.call('import', cut, success=False)
        self.assertEqual(self.call('list')['current'], before)
        self.assertEqual(len(self.call('list')['slots']), 1)
        self.assertEqual((self.save() / 'main').read_text(), 'kept')
        self.assertFalse(any((self.root / 'saves/staging').iterdir()))
        self.assertFalse((self.root / 'saves/escape.dat').exists())

    def test_compressed_import_ignores_macos_metadata_and_rejects_oversized_files(self):
        archive = self.compressed('zip', 'mac-metadata', {'a/main': 'progress',
                                  '__MACOSX/a/._main': 'finder metadata', 'a/.DS_Store': 'finder settings'})
        slot = self.call('import-inside', archive)['id']
        self.assertEqual((self.save(slot) / 'main').read_text(), 'progress')
        self.assertEqual([p.name for p in self.save(slot).iterdir()], ['main'])
        huge = self.folder / 'oversized.zip'
        with zipfile.ZipFile(huge, 'w') as package:
            info = zipfile.ZipInfo('main')
            info.extra = struct.pack('<HHQQ', 1, 16, (8 << 30) + 1, 0)
            package.writestr(info, b'')
        raw = bytearray(huge.read_bytes())
        central = raw.index(b'PK\x01\x02')
        struct.pack_into('<I', raw, central + 24, 0xffffffff)
        huge.write_bytes(raw)
        self.assertIn('too large', self.call('import', huge, success=False))

    def test_password_and_split_packages_report_the_limit_without_publishing(self):
        archive = self.compressed('zip', 'private', {'main': 'private progress'})
        raw = bytearray(archive.read_bytes())
        raw[6] |= 1
        central = raw.index(b'PK\x01\x02')
        raw[central + 8] |= 1
        archive.write_bytes(raw)
        self.assertIn('Password', self.call('import', archive, success=False))
        split = self.compressed('zip', 'backup.part1', {'main': 'progress'})
        split = split.rename(self.folder / 'backup.part1.rar')
        self.assertIn('Split archives', self.call('import', split, success=False))

    def test_downgrade_recreated_legacy_save_is_recovered_without_overwrite(self):
        self.call('list')
        self.put(self.save() / 'main', 'new-version')
        self.put(self.root / 'save/main', 'old-version')
        self.legacy(self.root / 'save')
        slots = self.call('list')['slots']
        self.assertEqual(len(slots), 2)
        recovered = next(s['id'] for s in slots if s['id'] != 'default')
        self.assertEqual((self.save(recovered) / 'main').read_text(), 'old-version')
        self.assertEqual((self.save() / 'main').read_text(), 'new-version')
        self.assertFalse((self.root / 'save').exists())
        self.assertFalse((self.save(recovered).parent / 'save.sync').exists())
        self.call('sync', recovered)
        self.assertTrue((self.cloud / GAME / 'slots' / recovered / 'save.dmsync').is_file())

    def test_old_new_cloud_matrix_preserves_default_and_isolates_extra_slots(self):
        old = self.folder / 'Old/save'
        self.put(old / 'main', 'old-start')
        self.legacy(old)
        cloud_file = self.cloud / GAME / 'save.dmsync'
        self.assertTrue(cloud_file.is_file())
        self.call('sync', 'default')
        self.assertEqual((self.save() / 'main').read_text(), 'old-start')
        self.put(self.save() / 'main', 'new-default')
        self.call('sync', 'default')
        self.legacy(old)
        self.assertEqual((old / 'main').read_text(), 'new-default')
        self.put(old / 'main', 'old-return')
        self.legacy(old)
        self.call('sync', 'default')
        self.assertEqual((self.save() / 'main').read_text(), 'old-return')
        baseline = cloud_file.read_bytes()
        slot = self.call('create', 'Separate')['id']
        self.put(self.save(slot) / 'main', 'separate-progress')
        self.call('select', slot)
        self.call('sync', slot)
        self.assertEqual(cloud_file.read_bytes(), baseline)
        self.assertTrue((self.cloud / GAME / 'slots' / slot / 'save.dmsync').is_file())
        self.legacy(old)
        self.assertEqual((old / 'main').read_text(), 'old-return')
        self.call('refresh', root=self.phone)
        self.assertEqual(self.call('list', root=self.phone)['current'], 'default')
        self.call('sync', slot, root=self.phone)
        self.assertEqual((self.save(slot, self.phone) / 'main').read_text(), 'separate-progress')
        self.put(self.save(slot, self.phone) / 'main', 'phone-progress')
        self.call('sync', slot, root=self.phone)
        self.call('sync', slot)
        self.assertEqual((self.save(slot) / 'main').read_text(), 'phone-progress')
        self.assertEqual(cloud_file.read_bytes(), baseline)
        self.call('select', 'default')
        self.call('delete', slot)
        self.assertEqual(self.call('refresh')['discovered'], 0)
        self.assertFalse(self.save(slot).exists())

    def test_cloud_game_folder_selection_and_placeholder_discovery(self):
        self.env['DM_SAVE_SYNC'] = str(self.cloud / GAME)
        slot = self.call('create', 'Separate')['id']
        self.put(self.save(slot) / 'main', 'own-game-folder')
        self.call('sync', slot)
        remote = self.cloud / GAME / 'slots' / slot
        self.assertTrue((remote / 'save.dmsync').exists())
        self.assertFalse((self.cloud / GAME / GAME).exists())
        (remote / 'save.dmsync').rename(remote / '.save.dmsync.icloud')
        self.assertEqual(self.call('refresh', root=self.phone)['discovered'], 1)

    def test_legacy_cloud_only_default_must_download_before_first_new_start(self):
        old = self.folder / 'Old/save'
        self.put(old / 'main', 'legacy-progress')
        self.legacy(old)
        self.call('refresh', root=self.phone)
        cloud = self.cloud / GAME / 'save.dmsync'
        placeholder = cloud.with_name('.save.dmsync.icloud')
        cloud.rename(placeholder)
        self.assertIn('has not downloaded', self.prepare(root=self.phone, success=False))
        self.assertFalse((self.save(root=self.phone) / 'main').exists())
        placeholder.rename(cloud)
        self.prepare(root=self.phone)
        self.assertEqual((self.save(root=self.phone) / 'main').read_text(), 'legacy-progress')

    def test_cloud_only_slot_cannot_start_or_export_an_empty_save_offline(self):
        slot = self.call('create', 'Remote')['id']
        self.put(self.save(slot) / 'main', 'remote-progress')
        self.call('sync', slot)
        self.call('refresh', root=self.phone)
        self.call('select', slot, root=self.phone)
        cloud = self.cloud / GAME / 'slots' / slot / 'save.dmsync'
        packed = cloud.read_bytes()
        cloud.unlink()
        self.assertIn('has not downloaded', self.prepare(root=self.phone, success=False))
        self.call('export', slot, self.folder / 'empty.dmsync', root=self.phone, success=False)
        self.assertFalse((self.folder / 'empty.dmsync').exists())
        self.assertTrue((self.save(slot, self.phone).parent / 'cloud-pending').exists())
        cloud.write_bytes(packed)
        self.prepare(root=self.phone)
        self.assertEqual((self.save(slot, self.phone) / 'main').read_text(), 'remote-progress')
        self.assertFalse((self.save(slot, self.phone).parent / 'cloud-pending').exists())

    def test_sync_initialization_failure_is_not_reported_as_success(self):
        self.call('list')
        self.put(self.save() / 'main', 'local-progress')
        locked = self.save().parent / 'save.sync-tmp/locked'
        locked.mkdir(parents=True)
        locked.chmod(0)
        try:
            self.call('sync', 'default', success=False)
            self.assertEqual((self.save() / 'main').read_text(), 'local-progress')
            self.assertFalse((self.cloud / GAME / 'save.dmsync').exists())
        finally:
            locked.chmod(0o700)

    def test_lifetime_lock_prevents_mutation_until_game_exits(self):
        process = subprocess.Popen([str(self.driver), 'hold', str(self.root), GAME], env=self.env,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert process.stdout is not None
            self.assertEqual(Path(process.stdout.readline().strip()).resolve(), self.save())
            self.assertIn('in use', self.call('create', 'Unsafe', success=False))
            self.assertEqual(self.call('inspect')['current'], 'default')
            # Read-only inspection must not repair or rewrite the selection.
            current = self.root / 'saves/current.json'
            current.write_text('{damaged')
            self.call('inspect')
            self.assertEqual(current.read_text(), '{damaged')
        finally:
            process.communicate('\n', timeout=10)
        self.assertEqual(process.returncode, 0)
        self.call('create', 'Safe')

    def test_custom_folder_without_metadata_is_selectable_and_syncs_independently(self):
        self.call('list')
        name = 'My adventure'
        self.put(self.save(name) / '0/main', 'custom-progress')
        self.call('refresh')
        entry = next(s for s in self.call('list')['slots'] if s['id'] == name)
        self.assertEqual(entry['name'], name)
        self.assertEqual(entry['files'], 1)
        self.assertEqual(entry['bytes'], len('custom-progress'))
        self.assertGreater(entry['saved_at'], 0)
        self.assertFalse((self.save(name).parent / 'info.json').exists())
        self.call('select', name)
        self.assertEqual(self.prepare(), self.save(name))
        self.call('sync', name)
        self.assertTrue((self.cloud / GAME / 'slots' / name / 'save.dmsync').is_file())
        self.assertFalse((self.cloud / GAME / 'save.dmsync').exists())
        self.call('refresh', root=self.phone)
        self.assertIn(name, [s['id'] for s in self.call('list', root=self.phone)['slots']])
        self.call('select', name, root=self.phone)
        self.assertEqual((self.prepare(root=self.phone) / '0/main').read_text(), 'custom-progress')

    def test_first_launch_keeps_custom_saves_and_reserved_default(self):
        custom = 'Adventure-\u65b0'
        self.put(self.save(custom) / 'main', 'custom')
        slots = self.call('list')['slots']
        self.assertEqual({s['id'] for s in slots}, {'default', custom})
        self.call('select', custom)
        self.assertEqual(self.prepare(), self.save(custom))

    def test_nested_layout_migrates_selection_and_cloud_history(self):
        self.call('list')
        slot = self.call('create', 'Earlier version')['id']
        self.put(self.save(slot) / 'main', 'earlier-progress')
        self.call('select', slot)
        self.put(self.save(slot).parent / 'save.sync', 'base\t' + 'a' * 32)
        old = self.root / 'saves/slots'
        old.mkdir()
        for name in (slot, 'default'): self.save(name).parent.rename(old / name)
        self.assertEqual(self.call('list')['current'], slot)
        self.assertEqual((self.save(slot) / 'main').read_text(), 'earlier-progress')
        self.assertTrue((self.save(slot).parent / 'save.sync').is_file())
        self.assertEqual(list(old.iterdir()), [])

    def test_nested_layout_collision_never_overwrites_either_save(self):
        self.put(self.root / 'saves/slots/default/save/main', 'old')
        self.put(self.save() / 'main', 'custom')
        self.assertIn('both', self.call('list', success=False))
        self.assertEqual((self.root / 'saves/slots/default/save/main').read_text(), 'old')
        self.assertEqual((self.save() / 'main').read_text(), 'custom')

    def test_custom_folder_links_and_other_game_metadata_are_not_usable(self):
        self.call('list')
        source = self.folder / 'outside'
        self.put(source / 'save/main', 'external')
        (self.root / 'saves/link').symlink_to(source, target_is_directory=True)
        self.assertNotIn('link', [s['id'] for s in self.call('list')['slots']])
        self.call('select', 'link', success=False)
        self.put(self.save('wrong') / 'main', 'wrong-game')
        self.put(self.save('wrong').parent / 'info.json', json.dumps({'title_id': OTHER_GAME}))
        self.call('select', 'wrong')
        self.assertIn('different game', self.prepare(success=False))


if __name__ == '__main__':
    unittest.main()
