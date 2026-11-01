"""Stored graphics ZIPs, stable compatibility and actual Foundation imports."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
import zipfile

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('graphics_pack', REPO / 'dm/tools/graphics_pack.py')
gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)


class GraphicsPack(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.native_binary = None
        if sys.platform != 'darwin' or not shutil.which('xcrun'): return
        cls.compiler_tmp = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.compiler_tmp.cleanup)
        root = Path(cls.compiler_tmp.name)
        source = root / 'import.m'
        source.write_text('''#import <Foundation/Foundation.h>
#import "GraphicsPack.h"
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=5) return 2;
    NSURL *documents=[NSURL fileURLWithPath:@(argv[2])], *bundle=[NSURL fileURLWithPath:@(argv[3])];
    NSError *error=nil; BOOL ok;
    if(!strcmp(argv[1],"import")) ok=dm_import_graphics_package([NSURL fileURLWithPath:@(argv[4])],documents,dm_graphics_requirements(bundle),nil,&error);
    else if(!strcmp(argv[1],"configure")) {
        ok=dm_graphics_configure(documents,bundle,&error);
        if(ok) printf("msl=%s\\nmap=%s\\npso=%s\\n",getenv("DM_MSL_DIR")?:"",getenv("DM_NVN_SHMAP")?:"",getenv("DM_PSO_BUNDLE")?:"");
    } else { NSString *why=dm_graphics_status(documents,bundle); ok=why==nil;
        if(why) error=[NSError errorWithDomain:@"fixture" code:1 userInfo:@{NSLocalizedDescriptionKey:why}]; }
    if(!ok) fprintf(stderr,"%s\\n",error.localizedDescription.UTF8String ?: "failed");
    return ok ? 0 : 1;
}}
''')
        cls.native_binary = root / 'import'
        result = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Werror', '-Wno-deprecated-declarations',
                                 '-I', str(REPO / 'dm/ios/Sources'), str(source), str(REPO / 'dm/ios/Sources/GraphicsPack.m'),
                                 '-framework', 'Foundation', '-larchive', '-o', str(cls.native_binary)], capture_output=True, text=True)
        if result.returncode: raise RuntimeError(result.stdout + result.stderr)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.shaders, self.tables = self.root / 'shaders', self.root / 'tables'
        self.documents, self.bundle = self.root / 'Documents', self.root / 'App'
        for p in (self.shaders, self.tables, self.documents, self.bundle / 'dm'): p.mkdir(parents=True)
        (self.shaders / 'a_b.metallib').write_bytes(b'MTLBfixture shader')
        (self.shaders / 'a_b.metal').write_text('build source stays outside the package')
        (self.shaders / 'a_b.json').write_text(json.dumps({'chain': 'fixture', 'chain_compiler': 'a' * 64, 'chain_metal': 'fixture compiler flags'}))
        (self.shaders / 'inputs.tsv').write_text('game\tfixture\ninputs\tfixture\n')
        (self.tables / 'shader_map.tsv').write_text('fixture map\n')
        self.required = dict(schema=1, series='1-fixture', minimum_version=2, external=True,
                             compatibility=dict(game='01007EF00011E000', build='v1114112', platform='ios', api='nvn', chain='fixture', library='b-fixture', contract='fixture'))
        self.zip = self.root / 'graphics.zip'
        self.save_required()
        with contextlib.redirect_stdout(io.StringIO()):
            self.manifest = gp.build(self.zip, self.required, self.shaders, self.tables, version=3)

    def save_required(self):
        gp.atomic_json(self.bundle / 'dm/graphics-required.json', self.required)

    def native(self, mode='import', archive=None, success=True):
        if self.__class__.native_binary is None: self.skipTest('Foundation/libarchive require macOS')
        result = subprocess.run([str(self.__class__.native_binary), mode, str(self.documents), str(self.bundle), str(archive or self.zip)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0 if success else 1, result.stdout + result.stderr)
        return result

    def rewrite(self, name, *, manifest=None, replacement=None, extra=None, symlink=False):
        output = self.root / name
        with zipfile.ZipFile(self.zip) as source, zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as target:
            target.writestr('manifest.json', json.dumps(manifest or self.manifest))
            for item in source.infolist():
                if item.filename == 'manifest.json': continue
                data = source.read(item)
                if replacement and item.filename == replacement[0]: data = replacement[1]
                if symlink and item.filename.endswith('.metallib'):
                    info = zipfile.ZipInfo(item.filename); info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    target.writestr(info, b'/outside')
                else: target.writestr(item.filename, data)
            if extra: target.writestr(*extra)
        return output

    def test_stored_zip_reuse_and_runtime_resources_only(self):
        with zipfile.ZipFile(self.zip) as archive:
            self.assertTrue(all(i.compress_type == zipfile.ZIP_STORED for i in archive.infolist()))
            self.assertEqual(archive.infolist()[0].filename, 'manifest.json')
            self.assertFalse(any(i.filename.endswith('.metal') for i in archive.infolist()))
        before = self.zip.stat().st_mtime_ns
        with contextlib.redirect_stdout(io.StringIO()) as output:
            gp.build(self.zip, self.required, self.shaders, self.tables, version=3)
        self.assertEqual(self.zip.stat().st_mtime_ns, before)
        self.assertIn('REUSE', output.getvalue())
        self.assertEqual(self.manifest['id'], gp.package_id(self.manifest))
        self.assertIsNone(gp.compatible(self.manifest, self.required))

    def test_changed_payload_increments_version_but_identical_moved_inputs_reuse(self):
        moved = self.root / 'moved'; shutil.copytree(self.shaders, moved)
        before = self.zip.read_bytes()
        with contextlib.redirect_stdout(io.StringIO()):
            same = gp.build(self.zip, self.required, moved, self.tables)
        self.assertEqual(same, self.manifest); self.assertEqual(self.zip.read_bytes(), before)
        (moved / 'a_b.metallib').write_bytes(b'MTLBupdated shader')
        with contextlib.redirect_stdout(io.StringIO()):
            updated = gp.build(self.zip, self.required, moved, self.tables)
        self.assertEqual(updated['version'], 4)
        self.assertEqual(updated['series'], self.manifest['series'])
        self.assertNotEqual(updated['id'], self.manifest['id'])
        self.native()

    def test_restore_published_package_without_shader_build_cache(self):
        cache = self.root / 'cache'
        directory, manifest = gp.restore(self.zip, self.required, cache)
        self.assertEqual(manifest, self.manifest)
        self.assertEqual((directory / 'msl/b-fixture/a_b.metallib').read_bytes(), b'MTLBfixture shader')
        self.assertEqual(gp.restore(self.zip, self.required, cache)[0], directory)
        wrong = dict(self.required, minimum_version=4)
        with self.assertRaisesRegex(ValueError, 'below required'): gp.restore(self.zip, wrong, cache)
        corrupt = self.rewrite('corrupt.zip', replacement=('msl/b-fixture/a_b.metallib', b'MTLBcorrupt shader'))
        with self.assertRaisesRegex(ValueError, 'integrity'): gp.restore(corrupt, self.required, cache)
        self.assertEqual((directory / 'msl/b-fixture/a_b.metallib').read_bytes(), b'MTLBfixture shader')
        self.assertFalse(list(cache.glob('.graphics-*')))

    def test_zip64_archive_import(self):
        # Force ZIP64 headers even for the small fixture; no game data needed.
        output = self.root / 'zip64.zip'
        with zipfile.ZipFile(self.zip) as source, zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as target:
            for item in source.infolist():
                with target.open(item.filename, 'w', force_zip64=True) as destination:
                    destination.write(source.read(item))
        self.native(archive=output)

    def test_ui_changes_do_not_change_series_but_renderer_and_tables_do(self):
        repo = self.root / 'repo'; render = repo / 'dm/gfx/nvn/renderer.m'; render.parent.mkdir(parents=True)
        render.write_text('renderer contract')
        ui = repo / 'dm/ios/Sources/Launcher.swift'; ui.parent.mkdir(parents=True); ui.write_text('old UI')
        game = types.SimpleNamespace(load=lambda gid: None, header=lambda _: '// local source path\n#define DM_GAME_X 1\n')
        with patch.dict(sys.modules, game=game):
            args = ('01007EF00011E000', 'v1114112', 'nvn', 'b-fixture', self.tables)
            first = gp.requirements(*args, repo=repo)
            ui.write_text('new UI')
            self.assertEqual(gp.requirements(*args, repo=repo)['series'], first['series'])
            render.write_text('another renderer contract')
            self.assertNotEqual(gp.requirements(*args, repo=repo)['series'], first['series'])
            render.write_text('renderer contract'); (self.tables / 'shader_map.tsv').write_text('new map')
            self.assertNotEqual(gp.requirements(*args, repo=repo)['series'], first['series'])

    def test_foundation_import_select_and_minimum_version(self):
        self.native()
        active = json.loads((self.documents / 'graphics/current.json').read_text())
        installed = self.documents / 'graphics' / active['directory']
        self.assertEqual((installed / 'msl/b-fixture/a_b.metallib').read_bytes(), b'MTLBfixture shader')
        result = self.native('configure')
        self.assertIn(str(installed / 'msl'), result.stdout)
        self.assertIn(str(installed / 'tables/shader_map.tsv'), result.stdout)
        self.required['minimum_version'] = 4; self.save_required()
        result = self.native('status', success=False)
        self.assertIn('version 4', result.stderr)
        self.assertEqual(json.loads((self.documents / 'graphics/current.json').read_text()), active)

    def test_wrong_series_and_corrupt_payload_preserve_previous_import(self):
        self.native(); active = (self.documents / 'graphics/current.json').read_bytes()
        changed = dict(self.manifest, series='another-series')
        wrong = self.rewrite('wrong.zip', manifest=changed)
        self.native(archive=wrong, success=False)
        corrupt = self.rewrite('corrupt.zip', replacement=('msl/b-fixture/a_b.metallib', b'MTLBcorrupt shader'))
        self.native(archive=corrupt, success=False)
        self.assertEqual((self.documents / 'graphics/current.json').read_bytes(), active)
        self.assertFalse(list((self.documents / 'graphics').glob('.import-*')))
        self.native('status')

    def test_paths_symlinks_and_unlisted_entries_are_rejected(self):
        changed = json.loads(json.dumps(self.manifest)); changed['files'][0]['path'] = '../escape'
        changed['files'].sort(key=lambda e: e['path']); changed['id'] = gp.package_id(changed)
        self.native(archive=self.rewrite('escape.zip', manifest=changed), success=False)
        self.native(archive=self.rewrite('symlink.zip', symlink=True), success=False)
        self.native(archive=self.rewrite('extra.zip', extra=('extra.file', b'wrong')), success=False)
        self.assertFalse((self.root / 'escape').exists())
        self.assertFalse((self.documents / 'graphics/current.json').exists())

    def test_interrupted_zip_is_rejected_and_reimport_repairs_existing_files(self):
        self.native()
        active = json.loads((self.documents / 'graphics/current.json').read_text())
        installed = self.documents / 'graphics' / active['directory']
        file = installed / 'msl/b-fixture/a_b.metallib'; file.write_bytes(b'broken')
        self.native('status', success=False)
        self.native(); self.assertEqual(file.read_bytes(), b'MTLBfixture shader')
        truncated = self.root / 'truncated.zip'; truncated.write_bytes(self.zip.read_bytes()[:100])
        self.native(archive=truncated, success=False)
        self.native('status')


if __name__ == '__main__': unittest.main()
