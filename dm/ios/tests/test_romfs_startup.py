"""Run the actual iOS RomFS locator on macOS/Foundation with private Documents/temp folders (no device or game files)."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('romfs_image', REPO / 'dm/tools/romfs_image.py')
assert spec is not None and spec.loader is not None
image = importlib.util.module_from_spec(spec); spec.loader.exec_module(image)
import shutil


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required')
class Startup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.tools.cleanup)
        root = Path(cls.tools.name)
        main = (REPO / 'dm/ios/Sources/main.m').read_text()
        locator = main[main.index('static int romfs_image_complete'):main.index('// Boot prerequisites')]
        source = root / 'locator.m'
        source.write_text('#import <Foundation/Foundation.h>\n#include <stdio.h>\n#include "romfs_image.h"\n#include "romfs_identity.h"\n#import "GameFiles.h"\n'
                          'static NSString *fixture_doc, *fixture_tmp, *fixture_bundle;\n#define DM_GAME_ROMFS_MARKER "marker"\n'
                          'static int g_boot_ok, g_argc; static char **g_argv;\n'
                          'static void dm_host_preload_start(int argc, char **argv) { (void)argc; (void)argv; }\n'
                          '@interface FixtureBundle : NSObject\n+ (instancetype)mainBundle;\n- (NSString *)resourcePath;\n'
                          '- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table;\n@end\n'
                          '@implementation FixtureBundle\n+ (instancetype)mainBundle { return [self new]; }\n'
                          '- (NSString *)resourcePath { return fixture_bundle; }\n'
                          '- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)value table:(NSString *)table { (void)value; (void)table; return key; }\n@end\n#define NSBundle FixtureBundle\n'
                          '#define NSSearchPathForDirectoriesInDomains(a,b,c) @[fixture_doc]\n#define NSTemporaryDirectory() fixture_tmp\n' + locator +
                          '\nstatic void romfs_identity_report(NSString *doc) { (void)doc; }\n'
                          'int main(int argc, char **argv) { @autoreleasepool { if (argc < 3) return 2;\n'
                          'fixture_doc = @(argv[1]); fixture_tmp = @(argv[2]); fixture_bundle = argc > 3 ? @(argv[3]) : @"/nonexistent-fixture";\n'
                          'unsetenv("DM_ROMFS"); unsetenv("DM_AOC_DIR"); if (argc > 4) setenv("DM_AOC_DIR", argv[4], 1);\n'
                          'if (getenv("DM_FIXTURE_PREPARE_MISSING") && front_ios_prepare_game()) return 4;\n'
                          'const char *picked = getenv("DM_FIXTURE_IMPORT_FILE"); if (picked) { NSError *error = nil;\n'
                          'if (!dm_import_game_image([NSURL fileURLWithPath:@(picked)], [NSURL fileURLWithPath:fixture_doc], &error)) {\n'
                          'fprintf(stderr, "import failed:%s\\n", error.localizedDescription.UTF8String); return 3; }}\n'
                          'if (!front_ios_prepare_game()) return 1; puts(getenv("DM_ROMFS"));\n'
                          'fprintf(stderr, "fixture aoc:%s\\n", getenv("DM_AOC_DIR") ?: "unset"); return 0; }}\n')
        cls.locator = root / 'locator'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Werror', '-I', str(REPO / 'dm/host'), '-I', str(REPO / 'dm/ios/Sources'),
                        str(source), str(REPO / 'dm/ios/Sources/GameImageImport.m'), '-framework', 'Foundation', '-o', str(cls.locator)], check=True)

    def test_invalid_image_preserves_working_folder_and_valid_image_replaces_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; folder = doc / 'romfs'; folder.mkdir(parents=True)
            (folder / 'marker').write_text('working files')
            tmp = root / 'temp'; tmp.mkdir()
            img = doc / 'romfs.img'
            img.write_bytes(image.HEAD.pack(image.MAGIC, 32, 0, 0))
            result = subprocess.run([str(self.locator), str(doc), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(folder))
            self.assertTrue((folder / 'marker').is_file()); self.assertEqual(list(tmp.iterdir()), [])
            image.pack(folder, img)
            result = subprocess.run([str(self.locator), str(doc), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(img)); self.assertFalse(folder.exists())

    def test_bundled_image_is_used_in_place_and_documents_can_override_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            source = root / 'source'; source.mkdir(); (source / 'marker').write_text('resource')
            image.pack(source, bundle / 'romfs.img')
            def locate():
                result = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); return result.stdout.strip()
            self.assertEqual(locate(), str(bundle / 'romfs.img'))
            self.assertEqual(list(doc.iterdir()), []); self.assertFalse((bundle / 'romfs').exists())
            folder = doc / 'romfs'; folder.mkdir(); (folder / 'marker').touch()
            self.assertEqual(locate(), str(folder))
            image.pack(source, doc / 'romfs.img'); self.assertEqual(locate(), str(doc / 'romfs.img'))

    def test_slim_build_uses_only_the_image_it_was_built_for(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            wanted, other = root / 'wanted', root / 'other'
            for folder, name in ((wanted, 'a'), (other, 'b')): folder.mkdir(); (folder / 'marker').write_text('x'); (folder / name).write_text(name * 100)
            image.pack(wanted, root / 'wanted.img'); image.pack(other, root / 'other.img')
            (bundle / 'romfs.id').write_text(image.identity(root / 'wanted.img', 'T', '1.0', 'v0') + '\n')
            def locate():
                return subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
            self.assertEqual(locate().returncode, 1)   # slim build, no image yet
            shutil.copy(root / 'other.img', doc / 'romfs.img')
            result = locate(); self.assertEqual(result.returncode, 1, result.stdout)   # another version: never used
            self.assertIn('[RED]', result.stderr)
            folder = doc / 'romfs'; folder.mkdir(); (folder / 'marker').touch()
            result = locate()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(folder))   # a rejected image preserves the existing folder fallback
            self.assertIn('[RED]', result.stderr)
            self.assertTrue(folder.is_dir()); self.assertEqual(list(tmp.iterdir()), [])
            shutil.copy(root / 'wanted.img', doc / 'romfs.img')
            result = locate(); self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img'))
            (bundle / 'romfs.id').unlink()   # the default build has no identity: any complete image
            shutil.copy(root / 'other.img', doc / 'romfs.img')
            self.assertEqual(locate().stdout.strip(), str(doc / 'romfs.img'))

    def test_unpacked_base_and_dlc_work_without_an_image_even_with_a_build_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; base = doc / 'romfs'; base.mkdir(parents=True)
            (base / 'marker').write_text('base resource')
            dlc = doc / 'game-data/aoc/1'; dlc.mkdir(parents=True); (dlc / 'item').write_text('DLC resource')
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            bundled_base = bundle / 'romfs'; bundled_base.mkdir(); (bundled_base / 'marker').touch()
            bundled_aoc = bundle / 'aoc'; (bundled_aoc / '99').mkdir(parents=True)
            wanted = root / 'wanted.img'; image.pack(base, wanted)
            (bundle / 'romfs.id').write_text(image.identity(wanted, 'T', '1.0', 'v0') + '\n'); wanted.unlink()
            def start(aoc=None):
                args = [str(self.locator), str(doc), str(tmp), str(bundle)]
                if aoc is not None: args.append(str(aoc))
                result = subprocess.run(args, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); self.assertNotIn('[RED]', result.stderr)
                return result
            for configured in (None, bundled_aoc):
                result = start(configured)
                self.assertEqual(result.stdout.strip(), str(base))
                self.assertIn('fixture aoc:' + str(doc / 'game-data/aoc'), result.stderr)
            explicit = root / 'explicit-aoc'; explicit.mkdir()
            self.assertIn('fixture aoc:' + str(explicit), start(explicit).stderr)
            self.assertIn('fixture aoc:\n', start('').stderr)   # explicitly disabled DLC stays disabled
            self.assertEqual((base / 'marker').read_text(), 'base resource')
            self.assertEqual((dlc / 'item').read_text(), 'DLC resource')
            self.assertEqual(list(root.rglob('*.img')), []); self.assertEqual(list(tmp.iterdir()), [])
            shutil.rmtree(doc / 'game-data/aoc')
            self.assertIn('fixture aoc:' + str(bundled_aoc), start(bundled_aoc).stderr)
            shutil.rmtree(base)
            result = start(bundled_aoc)
            self.assertEqual(result.stdout.strip(), str(bundled_base))
            self.assertIn('fixture aoc:' + str(bundled_aoc), result.stderr)

    def test_existing_game_data_import_is_used_without_reimport_or_an_image(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; data = doc / 'game-data'
            base = data / 'romfs'; base.mkdir(parents=True); (base / 'marker').write_text('imported base')
            dlc = data / 'aoc/2'; dlc.mkdir(parents=True); (dlc / 'item').write_text('imported DLC')
            receipt = data / 'installed.json'; receipt.write_text('{"format":1,"title_id":"T"}')
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            bundled_base = bundle / 'romfs'; bundled_base.mkdir(); (bundled_base / 'marker').touch()
            bundled_aoc = bundle / 'aoc'; (bundled_aoc / '99').mkdir(parents=True)
            wanted = root / 'wanted.img'; image.pack(base, wanted)
            (bundle / 'romfs.id').write_text(image.identity(wanted, 'T', '1.0', 'v0') + '\n'); wanted.unlink()
            def start():
                result = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle), str(bundled_aoc)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); self.assertNotIn('[RED]', result.stderr)
                return result
            result = start()
            self.assertEqual(result.stdout.strip(), str(base))
            self.assertIn('fixture aoc:' + str(data / 'aoc'), result.stderr)
            self.assertEqual(list(root.rglob('*.img')), [])
            shutil.rmtree(data / 'aoc')   # without external DLC, the bundled DLC remains available
            self.assertIn('fixture aoc:' + str(bundled_aoc), start().stderr)
            (base / 'marker').rename(base / 'wrong-marker')
            result = start(); self.assertEqual(result.stdout.strip(), str(bundled_base))
            self.assertIn('fixture aoc:' + str(bundled_aoc), result.stderr)
            (base / 'wrong-marker').rename(base / 'marker')
            image.pack(base, doc / 'romfs.img')
            self.assertEqual(start().stdout.strip(), str(doc / 'romfs.img'))   # a matching image retains precedence
            self.assertEqual((base / 'marker').read_text(), 'imported base')
            self.assertEqual(receipt.read_text(), '{"format":1,"title_id":"T"}')

    def test_combined_build_accepts_its_base_image_and_obeys_folder_and_dlc_precedence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir(); tmp = root / 'temp'; tmp.mkdir()
            bundle = root / 'App'; bundle.mkdir(); base = root / 'base'; base.mkdir(); (base / 'marker').write_text('base')
            original = root / 'base.img'; image.pack(base, original)
            aoc = root / 'aoc/1'; aoc.mkdir(parents=True); (aoc / 'item').write_text('DLC')
            combined = root / 'combined.img'; tool = str(REPO / 'dm/tools/game_image.py')
            subprocess.run([sys.executable, '-I', tool, str(original), str(aoc.parent), str(combined)], check=True, capture_output=True)
            subprocess.run([sys.executable, '-I', tool, '--identities', str(combined), str(bundle), 'T', '1.0', 'v0'], check=True, capture_output=True)
            bundled_aoc = bundle / 'aoc'; (bundled_aoc / '99').mkdir(parents=True)
            imported_aoc = doc / 'game-data/aoc'; (imported_aoc / '2').mkdir(parents=True)
            legacy = doc / 'game-data/romfs'; legacy.mkdir(); (legacy / 'marker').touch()
            old_folder = doc / 'romfs'; old_folder.mkdir(); (old_folder / 'marker').touch()
            def start(picked=None):
                env = os.environ | ({'DM_FIXTURE_IMPORT_FILE': str(picked)} if picked is not None else {})
                result = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle), str(bundled_aoc)], env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr); self.assertNotIn('[RED]', result.stderr)
                return result
            result = start(original); self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img'))
            self.assertIn('fixture aoc:' + str(imported_aoc), result.stderr)
            shutil.copy(combined, doc / 'romfs.img')
            result = start(); self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img/romfs'))
            self.assertIn('fixture aoc:' + str(doc / 'romfs.img/aoc'), result.stderr)
            (doc / 'romfs.img').unlink()
            result = start(); self.assertEqual(result.stdout.strip(), str(legacy))
            self.assertIn('fixture aoc:' + str(imported_aoc), result.stderr)
            shutil.copy(original, doc / 'romfs.img'); shutil.rmtree(imported_aoc)
            self.assertIn('fixture aoc:' + str(bundled_aoc), start().stderr)
            # A missing optional base identity must never turn a mismatch into an unrestricted match.
            (bundle / 'romfs.base.id').unlink(); shutil.rmtree(legacy)
            image.pack(base, doc / 'romfs.img')
            rejected = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
            self.assertEqual(rejected.returncode, 1, rejected.stderr); self.assertIn('[RED]', rejected.stderr)

    def test_import_copies_a_combined_image_then_retries_startup_without_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir(); tmp = root / 'temp'; tmp.mkdir()
            bundle = root / 'App'; bundle.mkdir(); source = root / 'source'
            base = source / 'romfs'; base.mkdir(parents=True); (base / 'marker').write_text('base resource')
            dlc = source / 'aoc/2'; dlc.mkdir(parents=True); (dlc / 'item').write_text('DLC resource')
            picked = root / 'picked.img'; image.pack(source, picked)
            (bundle / 'romfs.id').write_text(image.identity(picked, 'T', '1.0', 'v0') + '\n')
            staging = doc / '.romfs-import.img'; staging.write_bytes(b'interrupted previous copy')
            env = os.environ | {'DM_FIXTURE_IMPORT_FILE': str(picked), 'DM_FIXTURE_PREPARE_MISSING': '1'}
            result = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('boot: game files not found;', result.stderr)   # initially missing, then ready in the same process
            self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img/romfs'))
            self.assertIn('fixture aoc:' + str(doc / 'romfs.img/aoc'), result.stderr)
            self.assertEqual((doc / 'romfs.img').read_bytes(), picked.read_bytes()); self.assertFalse(staging.exists())
            self.assertFalse((doc / 'romfs').exists()); self.assertFalse((doc / 'aoc').exists())
            env.pop('DM_FIXTURE_PREPARE_MISSING'); env['DM_FIXTURE_IMPORT_FILE'] = str(doc / 'romfs.img')
            again = subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], env=env, capture_output=True, text=True)
            self.assertEqual(again.returncode, 0, again.stderr)   # picking an image already in Documents needs no second copy

    def test_rejected_import_and_publish_failure_preserve_existing_game_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir(); tmp = root / 'temp'; tmp.mkdir()
            bundle = root / 'App'; bundle.mkdir(); base = root / 'base'; base.mkdir(); (base / 'marker').write_text('right title')
            wanted = root / 'wanted.img'; image.pack(base, wanted)
            (bundle / 'romfs.id').write_text(image.identity(wanted, 'T', '1.0', 'v0') + '\n')
            installed = doc / 'game-data'; (installed / 'romfs').mkdir(parents=True)
            (installed / 'romfs/marker').write_text('old base'); (installed / 'installed.json').write_text('keep receipt')
            destination = doc / 'romfs.img'; destination.write_bytes(b'keep old image')
            invalid = root / 'invalid.img'; invalid.write_bytes(b'incomplete')
            other = root / 'other'; other.mkdir(); (other / 'marker').write_text('different build layout')
            different = root / 'different.img'; image.pack(other, different)
            def import_image(picked):
                env = os.environ | {'DM_FIXTURE_IMPORT_FILE': str(picked)}
                return subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], env=env, capture_output=True, text=True)
            for picked in (invalid, different):
                result = import_image(picked); self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn('import failed:', result.stderr)
                self.assertEqual(destination.read_bytes(), b'keep old image')
                self.assertFalse((doc / '.romfs-import.img').exists())
            destination.unlink(); destination.mkdir(); (destination / 'keep').touch()   # the final rename must fail
            result = import_image(wanted); self.assertEqual(result.returncode, 3, result.stderr)
            self.assertTrue((destination / 'keep').exists()); self.assertFalse((doc / '.romfs-import.img').exists())
            self.assertEqual((installed / 'romfs/marker').read_text(), 'old base')
            self.assertEqual((installed / 'installed.json').read_text(), 'keep receipt')
            self.assertTrue(wanted.is_file())
            # The same marker check applies even in a bundled build without a version identity.
            (bundle / 'romfs.id').unlink(); (other / 'marker').unlink(); (other / 'unrelated').touch(); image.pack(other, different)
            result = import_image(different); self.assertEqual(result.returncode, 3, result.stderr)
            self.assertIn("does not contain this game's files", result.stderr)

    def test_combined_image_validates_whole_identity_and_supplies_base_and_dlc_views(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; doc.mkdir()
            tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
            legacy = bundle / 'aoc'; (legacy / '99').mkdir(parents=True)
            source = root / 'source'; base = source / 'romfs'; base.mkdir(parents=True)
            (base / 'marker').write_text('base resource')
            dlc = source / 'aoc/2'; dlc.mkdir(parents=True); (dlc / 'item').write_text('DLC resource')
            wanted = root / 'wanted.img'; image.pack(source, wanted)
            (bundle / 'romfs.id').write_text(image.identity(wanted, 'T', '1.0', 'v0') + '\n')
            shutil.copy(wanted, doc / 'romfs.img')
            def start(aoc=legacy):
                return subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle), str(aoc)], capture_output=True, text=True)
            result = start()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(doc / 'romfs.img/romfs'))
            self.assertIn('fixture aoc:' + str(doc / 'romfs.img/aoc'), result.stderr)
            self.assertFalse((doc / 'romfs').exists()); self.assertFalse((doc / 'aoc').exists())
            explicit = root / 'explicit-aoc'; explicit.mkdir()
            self.assertIn('fixture aoc:' + str(explicit), start(explicit).stderr)
            # Only the DLC's size/layout changes: the existing whole-image size/index identity rejects it before selecting either subtree.
            (dlc / 'item').write_text('different DLC resource'); image.pack(source, doc / 'romfs.img')
            fallback = doc / 'romfs'; fallback.mkdir(); (fallback / 'marker').touch()
            result = start()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(fallback))
            self.assertIn('fixture aoc:' + str(legacy), result.stderr)
            self.assertIn('[RED]', result.stderr); self.assertTrue(fallback.is_dir())

    def test_complete_image_without_profile_marker_preserves_working_folder(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); doc = root / 'Documents'; fallback = doc / 'romfs'; fallback.mkdir(parents=True)
            (fallback / 'marker').touch(); tmp = root / 'temp'; tmp.mkdir()
            source = root / 'source'; (source / 'romfs').mkdir(parents=True); (source / 'aoc').mkdir()
            (source / 'romfs/unrelated').write_text('another title')
            image.pack(source, doc / 'romfs.img')
            result = subprocess.run([str(self.locator), str(doc), str(tmp)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.strip(), str(fallback))
            self.assertTrue(fallback.is_dir()); self.assertEqual(list(tmp.iterdir()), [])

    def test_image_name_in_any_letter_case_on_a_case_sensitive_volume(self):
        # iOS's file system is case-sensitive and the NSP script names its image RomFS.img: a copy through Finder or Files keeps that name
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)   # removed after the volume is detached (cleanups run last first)
        root = Path(temporary.name); disk = root / 'cs.dmg'; mount = root / 'mount'; mount.mkdir()
        made = subprocess.run(['hdiutil', 'create', '-size', '8m', '-fs', 'Case-sensitive APFS', '-volname', 'romfs-case', str(disk)], capture_output=True, text=True)
        if made.returncode or subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(disk)], capture_output=True).returncode:
            self.skipTest('no case-sensitive disk image: ' + made.stderr.strip())
        self.addCleanup(subprocess.run, ['hdiutil', 'detach', '-force', str(mount)], capture_output=True)
        doc = mount / 'Documents'; doc.mkdir(); tmp = root / 'temp'; tmp.mkdir(); bundle = root / 'App'; bundle.mkdir()
        wanted, other = root / 'wanted', root / 'other'
        for folder, name in ((wanted, 'a'), (other, 'b')): folder.mkdir(); (folder / 'marker').write_text('x'); (folder / name).write_text(name * 100)
        image.pack(wanted, root / 'wanted.img'); image.pack(other, root / 'other.img')
        (bundle / 'romfs.id').write_text(image.identity(root / 'wanted.img', 'T', '1.0', 'v0') + '\n')
        def locate():
            return subprocess.run([str(self.locator), str(doc), str(tmp), str(bundle)], capture_output=True, text=True)
        shutil.copy(root / 'wanted.img', doc / 'RomFS.img')
        self.assertFalse((doc / 'romfs.img').exists())   # the volume does tell the names apart
        result = locate(); self.assertEqual(result.returncode, 0, result.stderr); self.assertEqual(result.stdout.strip(), str(doc / 'RomFS.img'))
        shutil.copy(root / 'other.img', doc / 'romfs.img')   # another version under the exact name: rejected, the other spelling is used
        result = locate(); self.assertEqual(result.stdout.strip(), str(doc / 'RomFS.img')); self.assertIn('[RED] boot: Documents/romfs.img is not', result.stderr)
        shutil.copy(root / 'wanted.img', doc / 'romfs.img'); shutil.copy(root / 'other.img', doc / 'RomFS.img')
        self.assertEqual(locate().stdout.strip(), str(doc / 'romfs.img'))
        (bundle / 'romfs.id').unlink()   # both accepted (no identity): the exact name wins
        shutil.copy(root / 'wanted.img', doc / 'RomFS.img')
        self.assertEqual(locate().stdout.strip(), str(doc / 'romfs.img'))
        (doc / 'romfs.img').write_bytes(b'cut off')   # an incomplete exact name: the complete other spelling
        self.assertEqual(locate().stdout.strip(), str(doc / 'RomFS.img'))


if __name__ == '__main__': unittest.main()
