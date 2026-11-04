"""Real filesystem and legacy-wire compatibility checks, using synthetic saves."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
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
                        str(REPO / 'dm/host/save_manager.m'), str(REPO / 'dm/host/save_sync.c'), '-o', str(cls.driver)], check=True)

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
