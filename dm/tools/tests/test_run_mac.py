import importlib.util
import hashlib
import json
import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace


REPO = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('run_mac', REPO / 'scripts/run_mac.py')
assert SPEC is not None and SPEC.loader is not None
run_mac = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(run_mac)


def game_profile(game_id='010015100B514000'):
    import sys
    sys.path.insert(0, str(REPO / 'dm/games'))
    try:
        import game
        return game.load(game_id)
    finally:
        sys.path.pop(0)


def stamp_nvn(lib, g):
    import importlib.util
    spec = importlib.util.spec_from_file_location('dmsh_chain_test', REPO / 'dm/gfx/tools/dmsh_chain.py')
    assert spec is not None and spec.loader is not None
    chain = importlib.util.module_from_spec(spec); spec.loader.exec_module(chain)
    chain.write_stamp(lib, g.id, chain.inputs(g))


class MacLauncherTests(unittest.TestCase):
    def test_only_test_and_release_modes_are_accepted(self):
        from contextlib import redirect_stderr
        self.assertEqual(run_mac.parser().parse_args([]).mode, 'test')
        self.assertEqual(run_mac.parser().parse_args(['--test']).mode, 'test')
        self.assertEqual(run_mac.parser().parse_args(['--release']).mode, 'release')
        self.assertFalse(run_mac.parser().parse_args([]).allow_other_metal)
        self.assertTrue(run_mac.parser().parse_args(['--allow-other-metal']).allow_other_metal)
        for args in (['--quick'], ['--test', '--release']):
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                run_mac.parser().parse_args(args)

    def test_test_mode_isolates_outputs_and_refreshes_only_missing_shaders(self):
        g = game_profile('01007EF00011E000')
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / f'{g.id}_build'
            exefs, romfs, release_patched, _ = self.make_layout(root, g)
            sentinel = release_patched/'main.patched.bin'; sentinel.write_bytes(b'fixed release')
            args = run_mac.parser().parse_args(['--game', str(root), '--test', '--allow-other-metal'])
            plan = run_mac.resolve(args, {}, REPO)
            self.assertEqual(plan['work'], root.resolve().with_name(f'{g.id}-work')/'mac-test')
            self.assertFalse(plan['patched'].is_relative_to(root))
            counts = dict(rewrite=0, shader=0, execute=0)
            def rewrite(repo_py, repo, source, output, env, logs, game, game_romfs):
                counts['rewrite'] += 1
                self.fill_outputs(repo,source,output,env,game)
            def shaders(plan, env, repo, builder, logs):
                self.assertEqual(env['DM_ALLOW_OTHER_METAL'], '1')
                counts['shader'] += 1
                msl = plan['work']/'shader/cache'; lib = msl/f'b-{plan["chain"]}'
                lib.mkdir(parents=True); (lib/'test_b.metallib').write_bytes(b'current shaders'); stamp_nvn(lib,g)
                plan.update(msl=msl,graphics='nvn')
            def execute(exe, argv, env):
                counts['execute'] += 1
                self.assertEqual(exe,str(plan['work']/'tools/dmhost'))
                self.assertEqual(argv[1],str(plan['patched']))
                self.assertEqual(env['DM_SAVE'],str(root/'chosen save'))
            with redirect_stdout(io.StringIO()) as output:
                for _ in range(2):
                    run_mac.launch(plan,args,{'DM_SAVE':str(root/'chosen save'),'UNRELATED_SETTING':'not a runtime setting'},REPO,
                        rewrite_call=rewrite,host_call=self.fake_host,shader_call=shaders,exec_call=execute)
            self.assertEqual(counts,dict(rewrite=1,shader=1,execute=2))
            self.assertEqual(sentinel.read_bytes(),b'fixed release')
            self.assertFalse((root/'run/mac-runtime.json').exists())
            self.assertIn('code: 0123456789abcdef',output.getvalue())
            self.assertIn('mode: test',output.getvalue())
            record = json.loads((plan['work']/'run/mac-runtime.json').read_text())
            self.assertEqual(record['mode'],'test')
            self.assertNotIn('UNRELATED_SETTING',record['environment'])

    def test_test_mode_accepts_romfs_image_without_expanding_it(self):
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            exefs, romfs, _, _ = self.make_layout(root,g)
            romfs.rmdir(); image = romfs.with_name('RomFS.img'); image.write_bytes(b'romfs image')
            args = run_mac.parser().parse_args(['--game',g.id,'--build',str(root)])
            plan = run_mac.resolve(args,{},REPO)
            self.assertEqual(plan['romfs'],image.resolve())
            self.assertEqual(plan['exefs'],exefs.resolve())

    def test_shader_preparation_preserves_resolved_layout(self):
        from unittest.mock import Mock, patch
        g = game_profile('01007EF00011E000')
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / f'{g.id}_build'
            exefs, romfs, _, _ = self.make_layout(root, g)
            romfs.rmdir(); image = romfs.with_name('RomFS.img'); image.write_bytes(b'romfs image')
            args = run_mac.parser().parse_args(['--game', str(root), '--test'])
            plan = run_mac.resolve(args, {}, REPO)
            sources = dict(graphics=('nvn', ''), **{key: (False, '') for key in ('glslc_capture', 'ue_decode', 'oodle_packs', 'ue_legacy')})
            guess = SimpleNamespace(build_sources=Mock(return_value=sources))
            builder = Mock()
            env = {}
            builder.configure_dotnet.side_effect = lambda e: e.setdefault('DOTNET_ROOT', '/detected/runtime')
            builder.build_shaders.return_value = plan['work'] / 'shader/cache'
            original_mode = builder.PROG.mode
            # Stub binary inspection and compilation; exercise real layout selection and input links.
            with patch('importlib.util.spec_from_file_location', return_value=Mock()), \
                 patch('importlib.util.module_from_spec', return_value=guess):
                run_mac.refresh_shaders(plan, env, REPO, builder, plan['work'] / 'logs')
                builder.check_translator.assert_called_once_with(REPO / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate', env)
                self.assertEqual(builder.split_shaders.call_args.args[3], [plan['work'] / 'extract' / plan['version'] / 'ExeFS/main'])
                self.assertEqual(builder.split_shaders.call_args.args[5]['DOTNET_ROOT'], '/detected/runtime')
                self.assertEqual(builder.build_shaders.call_args.args[4]['DOTNET_ROOT'], '/detected/runtime')
                builder.progress_mode.assert_called_once_with('auto')
                builder.PROG.plan.assert_called_once_with(1)
                builder.PROG.add.assert_called_once_with(2)
                builder.PROG.close.assert_called_once_with(ok=True)
                self.assertIs(builder.PROG.mode, original_mode)
                builder.reset_mock()
                builder.check_translator.side_effect = RuntimeError('translator runtime missing')
                with self.assertRaisesRegex(RuntimeError, 'translator runtime missing'):
                    run_mac.refresh_shaders(plan, env, REPO, builder, plan['work'] / 'logs')
                builder.split_shaders.assert_not_called()
                builder.build_shaders.assert_not_called()
                builder.PROG.close.assert_called_once_with(ok=False)
                self.assertIs(builder.PROG.mode, original_mode)
            extraction = plan['work'] / 'extract' / plan['version']
            self.assertEqual((extraction / 'ExeFS').resolve(), exefs.resolve())
            self.assertEqual((extraction / 'RomFS.img').resolve(), image.resolve())
            self.assertEqual(plan['graphics'], 'nvn')

    def test_release_runtime_uses_matched_artifacts_and_preserves_save(self):
        from unittest.mock import Mock
        spec = importlib.util.spec_from_file_location('build_release', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        g = game_profile('01007EF00011E000')
        with tempfile.TemporaryDirectory(prefix='Release runtime ') as t:
            root = Path(t) / f'{g.id}_build'; root.mkdir()
            origin = root/'source-profile'/g.id; shutil.copytree(g.dir,origin)
            g = type(g)(origin)
            _, romfs, patched, msl = self.make_layout(root, g)
            romfs.rmdir(); romfs = romfs.with_name('RomFS.img'); romfs.write_bytes(b'romfs image')
            host = root / 'prepared host'; host.write_bytes(b'prepared host'); host.chmod(0o755)
            (patched / 'build_src.sha256').write_text('prepared source')
            for mod in g.words('modules'):
                for suffix in ('patched.bin', 'fixups.tsv', 'gates.tsv'):
                    (patched / f'{mod}.{suffix}').write_bytes(b'prepared module')
            # Prepared bundles can share unchanged modules through symlinks.
            shared = root / 'shared module'; shared.write_bytes(b'prepared module')
            linked = patched / f'{g.words("modules")[-1]}.patched.bin'
            linked.unlink(); linked.symlink_to(shared)
            # The prepared host may use an older chain than the working tree.
            old_chain = 'previous-chain'; lib = msl / f'b-{old_chain}'; lib.mkdir()
            (lib / 'test_b.metallib').write_bytes(b'prepared shaders'); stamp_nvn(lib, g)
            self.record_host_source(host, old_chain)
            (root/'run').mkdir()
            builder.write_mac_runtime(root, host, patched,
                                      dict(DM_ROMFS=romfs, DM_MSL_DIR=msl, DM_NVN_SHMAP=g.table('shader_map.tsv'),
                                           DM_SAVE='/old/test/save', DM_TEMP='/old/test/temp'), g, 'nvn', old_chain)
            g.table('shader_map.tsv').write_text('new working-tree shader map')
            args = run_mac.parser().parse_args(['--game', str(root.parent), '--release', '--touch-preview', '--windowed'])
            plan = run_mac.resolve(args, {}, REPO)
            rewrite, make, execute = Mock(), Mock(), Mock()
            execute.side_effect = lambda *_: self.assertEqual(Path.cwd(), (root/'run').resolve())
            with redirect_stdout(io.StringIO()):
                run_mac.launch(plan, args, {'DM_SAVE': str(root/'my save'), 'DM_NVN_SHMAP': '/wrong/map'}, REPO,
                               rewrite_call=rewrite, host_call=make, exec_call=execute, builder=Mock())
            rewrite.assert_not_called(); make.assert_not_called()
            path, argv, env = execute.call_args.args
            self.assertEqual(path, str(host.resolve())); self.assertEqual(argv[1], str(patched.resolve()))
            self.assertEqual(env['DM_SAVE'], str(root/'my save'))
            self.assertEqual(env['DM_NVN_SHMAP'], plan['runtime_env']['DM_NVN_SHMAP'])
            self.assertNotEqual(env['DM_NVN_SHMAP'], str(g.table('shader_map.tsv')))
            self.assertEqual(env['DM_TOUCH_PREVIEW'], '1'); self.assertEqual(env['DM_FULLSCREEN'], '0')
            source = root / 'original save'; source.mkdir()
            original = source / 'game_data.sav'; original.write_bytes(b'original progress')
            (source / 'linked.sav').symlink_to(original)
            args.save_copy = run_mac.parser().parse_args(['--save-copy', str(source)]).save_copy
            with redirect_stdout(io.StringIO()):
                run_mac.launch(plan, args, {'DM_SAVE': str(root/'my save')}, REPO,
                               rewrite_call=rewrite, host_call=make, exec_call=execute)
            copied = Path(execute.call_args.args[2]['DM_SAVE'])
            self.assertEqual(copied.parent.parent, (root / 'run/save-copies').resolve())
            self.assertFalse(copied.is_symlink())
            self.assertEqual((copied/'game_data.sav').read_bytes(), b'original progress')
            self.assertFalse((copied/'linked.sav').is_symlink())
            (copied/'game_data.sav').write_bytes(b'new progress')
            (copied/'linked.sav').write_bytes(b'linked progress')
            self.assertEqual(original.read_bytes(), b'original progress')
            with redirect_stdout(io.StringIO()):
                run_mac.launch(plan, args, {}, REPO, rewrite_call=rewrite, host_call=make, exec_call=execute)
            another = Path(execute.call_args.args[2]['DM_SAVE'])
            self.assertNotEqual(copied, another)
            self.assertEqual((another/'game_data.sav').read_bytes(), b'original progress')
            for invalid, message in ((str(root), 'copy destination'), (str(root/'missing'), 'not a folder'), ('', 'not a folder')):
                args.save_copy = invalid
                with redirect_stdout(io.StringIO()), self.assertRaisesRegex(run_mac.LaunchError, message):
                    run_mac.launch(plan, args, {}, REPO, exec_call=execute)
            args.save_copy = str(source)
            args.check = True
            before = list((root / 'run/save-copies').iterdir())
            with redirect_stdout(io.StringIO()): run_mac.launch(plan, args, {}, REPO, exec_call=execute)
            self.assertEqual(list((root/'run/save-copies').iterdir()), before)
            rewrite.assert_not_called(); make.assert_not_called()
            host.write_bytes(b'new unrelated host')
            with self.assertRaisesRegex(run_mac.LaunchError, 'prepared runtime changed'):
                run_mac.resolve(args, {}, REPO)
            record = root/'run/mac-runtime.json'; data = json.loads(record.read_text())
            data['schema'] = 1; record.write_text(json.dumps(data))
            with self.assertRaisesRegex(run_mac.LaunchError,'no current release record'):
                run_mac.resolve(args,{},REPO)

    def test_touch_preview_is_explicitly_botw_only(self):
        args = SimpleNamespace(game='010015100B514000', build=None, version=None, patched=None,
                               exefs=None, romfs=None, msl=None, touch_preview=True)
        with self.assertRaisesRegex(run_mac.LaunchError, 'only for Breath of the Wild'):
            run_mac.resolve(args, {}, REPO)

        botw = SimpleNamespace(game='01007EF00011E000', build=None, version=None, patched=None,
                               exefs=None, romfs=None, msl=None, touch_preview=True)
        with self.assertRaisesRegex(run_mac.LaunchError, 'set --build'):
            run_mac.resolve(botw, {}, REPO)

    @staticmethod
    def record_host_source(host, chain):
        data = dict(commit='0123456789abcdef', dirty=False, inputs='test-build-inputs', shader_chain=chain,
                    host_sha256=hashlib.sha256(host.read_bytes()).hexdigest())
        host.with_name(host.name+'.source.json').write_text(json.dumps(data))

    def fake_host(self, repo, out, env, logs, g):
        out.parent.mkdir(parents=True, exist_ok=True); out.write_bytes(b'fresh test host'); out.chmod(0o755)
        self.record_host_source(out,run_mac.chain_id(repo))
        return out

    def make_layout(self, root, g):
        v = g.get('package')
        exefs, romfs, patched, msl = (root / p for p in (Path('extract') / v / 'ExeFS', Path('extract') / v / 'RomFS', Path(f'patched_{v}'), Path('shader') / 'cache'))
        for d in (exefs, romfs, patched, msl): d.mkdir(parents=True)
        for mod in g.words('modules'): (exefs / mod).write_bytes(b'original-' + mod.encode())
        return exefs, romfs, patched, msl

    @staticmethod
    def fill_outputs(repo, exefs, patched, env, g):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', repo / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        b = module_from_spec(spec); spec.loader.exec_module(b)
        patched.mkdir(parents=True,exist_ok=True)
        _, _, key = b.rewrite_freshness(repo, exefs, patched, env, g)
        for name in b.rewrite_outputs(g.words('modules')): (patched / name).write_bytes(b'generated')
        patched.with_name(patched.name + '.key').write_text(key + '\n')

    def test_generic_profile_and_paths_with_spaces(self):
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='Mac build with spaces ') as t:
            root = Path(t) / 'work folder'; root.mkdir()
            exefs, romfs, patched, msl = self.make_layout(root, g)
            args = SimpleNamespace(game=g.id, build=str(root), version=None, patched=None, exefs=None, romfs=None, msl=None)
            plan = run_mac.resolve(args, {}, REPO)
            self.assertEqual(plan['game'].id, g.id)
            self.assertEqual((plan['patched'], plan['exefs'], plan['romfs']), (run_mac.test_work(root.resolve(), g) / f'patched_{g.get("package")}', exefs.resolve(), romfs.resolve()))
            self.assertEqual(plan['msl'], run_mac.test_work(root.resolve(),g) / 'shader/cache')

    def test_game_folder_resolves_one_standard_work_child_or_direct_work_folder(self):
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='Game folder with spaces ') as t:
            parent = Path(t) / 'ZeldaWild'; parent.mkdir()
            child = parent / f'{g.id}-work'
            exefs, romfs, patched, msl = self.make_layout(child, g)
            args = SimpleNamespace(game=str(parent), build=None, version=None, patched=None,
                                   exefs=None, romfs=None, msl=None)
            stale_root = Path(t) / 'stale-global-root'
            stale_root.mkdir()
            plan = run_mac.resolve(args, {'DM_ROOT': str(stale_root)}, REPO)
            self.assertEqual(plan['game'].id, g.id)
            self.assertEqual(plan['base'], child.resolve())
            self.assertEqual((plan['patched'], plan['exefs'], plan['romfs']),
                             (child.resolve() / f'mac-test/patched_{g.get("package")}', exefs.resolve(), romfs.resolve()))

            explicit_root = Path(t) / 'explicit-root'
            self.make_layout(explicit_root, g)
            explicit_args = SimpleNamespace(game=str(parent), build=str(explicit_root), version=None,
                                            patched=None, exefs=None, romfs=None, msl=None)
            explicit = run_mac.resolve(explicit_args, {'DM_ROOT': str(stale_root)}, REPO)
            self.assertEqual(explicit['base'], explicit_root.resolve())

            direct_args = SimpleNamespace(game=str(child), build=None, version=None, patched=None,
                                          exefs=None, romfs=None, msl=None)
            direct = run_mac.resolve(direct_args, {}, REPO)
            self.assertEqual((direct['game'].id, direct['base']), (g.id, child.resolve()))

    def test_game_folder_ambiguity_lists_standard_children(self):
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='Ambiguous games ') as t:
            parent = Path(t)
            first = parent / f'{g.id}-work'
            second = parent / '0100000000000000_build'
            first.mkdir(); second.mkdir()
            args = SimpleNamespace(game=str(parent), build=None, version=None, patched=None,
                                   exefs=None, romfs=None, msl=None)
            with self.assertRaisesRegex(run_mac.LaunchError, 'multiple game builds found') as error:
                run_mac.resolve(args, {}, REPO)
            self.assertIn(str(first), str(error.exception))
            self.assertIn(str(second), str(error.exception))
            self.assertIn('choose one with --game <folder>', str(error.exception))

    def test_unrecognized_game_folder_has_concise_error(self):
        with tempfile.TemporaryDirectory(prefix='Unprepared game ') as t:
            args = SimpleNamespace(game=t, build=None, version=None, patched=None,
                                   exefs=None, romfs=None, msl=None)
            with self.assertRaisesRegex(run_mac.LaunchError, 'no prepared game build found under'):
                run_mac.resolve(args, {}, REPO)

    def test_manual_layout_without_patched_output_and_external_vk_gl_caches(self):
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / 'manual'; root.mkdir()
            data = root / 'data' / g.get('package')
            exefs, romfs = data / 'ExeFS', data / 'RomFS'
            exefs.mkdir(parents=True); romfs.mkdir()
            for mod in g.words('modules'): (exefs / mod).write_bytes(b'original')
            args = SimpleNamespace(game=g.id, build=str(root), version=None, patched=None, exefs=None, romfs=str(romfs), msl=None)
            plan = run_mac.resolve(args, {}, REPO)
            self.assertEqual(plan['patched'], root.resolve() / 'mac-test' / f'patched_{g.get("package")}')
            self.assertFalse(plan['patched'].exists())
            self.assertEqual(plan['msl'], root.resolve() / 'mac-test/shader/cache')
            self.assertEqual(plan['layout'], 'manual')

            runtime = root / 'runtime-only'; (runtime / f'patched_{g.get("package")}').mkdir(parents=True)
            external_data = root / 'external-work' / 'data' / g.get('package')
            (external_data / 'ExeFS').mkdir(parents=True); (external_data / 'RomFS').mkdir()
            for mod in g.words('modules'): (external_data / 'ExeFS' / mod).write_bytes(b'original')
            legacy_args = SimpleNamespace(game=g.id, build=str(runtime), version=None, patched=None, exefs=None,
                                          romfs=str(external_data / 'RomFS'), msl=None)
            legacy = run_mac.resolve(legacy_args, {}, REPO)
            self.assertEqual(legacy['exefs'], (external_data / 'ExeFS').resolve())
            self.assertEqual(legacy['romfs'], (external_data / 'RomFS').resolve())

            class BareProfile:
                def __init__(self, directory): self.dir = directory; self.id = g.id; self.rows = g.rows
                def get(self, key, default=None): return default
                def table(self, name): return self.dir / name
            bare = BareProfile(root / 'bare-profile'); bare.dir.mkdir()
            (bare.table('shader_map.tsv')).write_text('header\n')
            (bare.table('dmsh_chain.h')).write_text('#define DMSH_CHAIN "ignored-per-profile-header"\n')
            chain = run_mac.chain_id(REPO)
            nvn = root / 'shader/cache' / f'b-{chain}'; nvn.mkdir(parents=True)
            (nvn / 'test_b.metallib').write_bytes(b'x')
            stamp_nvn(nvn, bare)
            (root / 'shader/vk').mkdir()
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, None, 'nsp', chain)
            self.assertEqual((cache, api), ((root / 'shader/cache').resolve(), 'nvn'))

            external = root / 'external shader output'; (external / 'vk').mkdir(parents=True)
            (external / 'vk/vk_shaders.tsv').write_text('table')
            (external / 'vk/vk_shaders.metallib').write_bytes(b'x')
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, external, 'nsp', chain)
            self.assertEqual((cache, api), (external.resolve(), 'vulkan'))
            (external / 'gl').mkdir()
            (external / 'gl/gl_shaders.tsv').write_text('table')
            (external / 'gl/gl_shaders.metallib').write_bytes(b'x')
            with self.assertRaisesRegex(run_mac.LaunchError, 'multiple complete'):
                run_mac.resolve_shader_cache(root, bare, external, 'nsp', chain)
            (external / 'vk/vk_shaders.tsv').unlink(); (external / 'vk/vk_shaders.metallib').unlink()
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, external, 'nsp', chain)
            self.assertEqual((cache, api), (external.resolve(), 'gl'))

            # Global chain folders are shared by profiles; a library's pipeline stamp must match this profile.
            stamp_nvn(nvn, game_profile('0100000000010000'))
            _, rejected_api, _ = run_mac.resolve_shader_cache(root, bare, None, 'nsp', chain)
            self.assertIsNone(rejected_api)
            stamp_nvn(nvn, bare)

    def test_external_profile_shadow_is_forwarded_to_make(self):
        g0 = game_profile()
        with tempfile.TemporaryDirectory(prefix='External profiles ') as t:
            root = Path(t); profiles = root / 'profiles'; ext = profiles / g0.id; ext.mkdir(parents=True)
            for name in ('game.tsv', 'shader_map.tsv'):
                shutil.copy2(g0.dir / name, ext / name)
            env = {'DM_GAMES_DIR': str(profiles), 'DM_GAMES_FIRST': '1'}
            build = root / 'game work'; build.mkdir()
            exefs, romfs, patched, msl = self.make_layout(build, g0)
            chain = run_mac.chain_id(REPO)
            cache = msl / f'b-{chain}'; cache.mkdir(parents=True); (cache / 'test_b.metallib').write_bytes(b'x')
            stamp_nvn(cache, run_mac.profile(REPO, str(ext), env))
            args = SimpleNamespace(game=g0.id, build=str(build), version=None, patched=None, exefs=None, romfs=None, msl=None)
            plan = run_mac.resolve(args, env, REPO)
            self.assertEqual(plan['game'].dir.resolve(), ext.resolve())
            self.fill_outputs(REPO, exefs, plan['patched'], env, plan['game'])
            observed = []
            def make(repo, out, make_env, logs, g):
                observed.extend((make_env['DM_GAMES_DIR'].split(':')[0], make_env['DM_GAMES_FIRST'], str(g.table('shader_map.tsv'))))
                return self.fake_host(repo,out,make_env,logs,g)
            with redirect_stdout(io.StringIO()):
                run_mac.launch(plan, SimpleNamespace(check=False, windowed=False), dict(env), REPO,
                               host_call=make, exec_call=lambda *_: None)
            self.assertEqual(observed, [str(profiles.resolve()), '1', str((ext / 'shader_map.tsv').resolve())])

            stamp_nvn(cache, g0)
            repo_args = SimpleNamespace(game=str(g0.dir), build=str(build), version=None, patched=None, exefs=None, romfs=None, msl=None)
            repo_plan = run_mac.resolve(repo_args, env, REPO)
            self.assertEqual(repo_plan['game'].dir.resolve(), g0.dir.resolve())
            observed.clear()
            self.fill_outputs(REPO,exefs,repo_plan['patched'],{},repo_plan['game'])
            def make_repo(repo, out, make_env, logs, g):
                observed.extend((make_env.get('DM_GAMES_FIRST'), str(g.table('shader_map.tsv'))))
                return self.fake_host(repo,out,make_env,logs,g)
            with redirect_stdout(io.StringIO()):
                run_mac.launch(repo_plan, SimpleNamespace(check=False, windowed=False), dict(env), REPO,
                               host_call=make_repo, exec_call=lambda *_: None)
            self.assertEqual(observed, [None, str((g0.dir / 'shader_map.tsv').resolve())])

    def test_freshness_requires_all_rewrite_sidecars(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        b = module_from_spec(spec); spec.loader.exec_module(b)
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); exefs = root / 'ExeFS'; out = root / 'patched'; exefs.mkdir(); out.mkdir()
            for mod in g.words('modules'): (exefs / mod).write_bytes(mod.encode())
            fresh, reason, key = b.rewrite_freshness(REPO, exefs, out, {}, g)
            self.assertFalse(fresh)
            for name in b.rewrite_outputs(g.words('modules')):
                if name == f'{g.words("modules")[0]}.obs.tsv': continue
                (out / name).write_bytes(b'x')
            out.with_name(out.name + '.key').write_text(key + '\n')
            fresh, reason, _ = b.rewrite_freshness(REPO, exefs, out, {}, g)
            self.assertFalse(fresh)
            self.assertIn('obs.tsv', reason)
            (out / f'{g.words("modules")[0]}.obs.tsv').write_bytes(b'x')
            self.assertTrue(b.rewrite_freshness(REPO, exefs, out, {}, g)[0])
            (exefs / g.words('modules')[0]).write_bytes(b'changed-original')
            self.assertFalse(b.rewrite_freshness(REPO, exefs, out, {}, g)[0])

    def test_nro_manifest_patch_and_explicit_romfs_share_freshness_inputs(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        b = module_from_spec(spec); spec.loader.exec_module(b)
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='NRO rewrite contract ') as t:
            root = Path(t); exefs = root / 'ExeFS'; sibling_romfs = root / 'RomFS'
            explicit_romfs = root / 'elsewhere' / 'RomFS'; out = root / 'patched'; nro_dir = root / 'nro_patched'
            exefs.mkdir(); sibling_romfs.mkdir(); explicit_romfs.mkdir(parents=True); out.mkdir(); nro_dir.mkdir()
            for mod in g.words('modules'):
                (exefs / mod).write_bytes(bytes(0x80))
            module_build = '00112233445566778899aabbccddeeff'
            nro = nro_dir / 'plugin.nro'; blob = bytearray(0x80); blob[0x40:0x50] = bytes.fromhex(module_build); nro.write_bytes(blob)
            (explicit_romfs / 'plugin.nrr').write_bytes(b'registration')
            manifest = nro_dir / 'nro.tsv'; manifest.write_text('plugin\tregistered\n')
            nro_dir.with_name(nro_dir.name + '.key').write_text(b.nro_collection_key(REPO, explicit_romfs, b.nrr_files(explicit_romfs)) + '\n')

            # A patch registry entry selected solely by an NRO's build ID is a rewrite input.
            patch_repo = root / 'repo'; (patch_repo / 'dm/tools').mkdir(parents=True); (patch_repo / 'dm/games/plugin').mkdir(parents=True)
            (patch_repo / 'dm/tools/sdk_patches.py').write_text('')
            nro_patch = patch_repo / 'dm/games/plugin/patches.py'; nro_patch.write_text(f"build = '{module_build}'\n")
            self.assertIn(nro_patch, b.patch_files(patch_repo, exefs, g.words('modules'), [nro]))

            # The rewrite entry point must collect from the launcher's explicit RomFS, not ExeFS.parent.
            import sys
            from unittest.mock import patch
            seen = []
            with patch.object(b, 'collect_nros', side_effect=lambda _py, _repo, source, _dst, _env, logs: (seen.append((Path(source), Path(logs).is_dir())) or {})), \
                 patch.object(b, 'rewrite_state', return_value=(True, 'current', 'key')):
                b.PROG.plan(1)
                b.rewrite(Path(sys.executable), REPO, exefs, out, {}, root / 'logs', g, explicit_romfs)
            self.assertEqual(seen, [(explicit_romfs, True)])

            fresh, reason, key = b.rewrite_freshness(REPO, exefs, out, {}, g, explicit_romfs)
            self.assertFalse(fresh)
            names = g.words('modules') + ['plugin']
            for name in b.rewrite_outputs(names, has_nro_manifest=True): (out / name).write_bytes(b'generated')
            out.with_name(out.name + '.key').write_text(key + '\n')
            self.assertTrue(b.rewrite_freshness(REPO, exefs, out, {}, g, explicit_romfs)[0])
            self.assertFalse(b.rewrite_freshness(REPO, exefs, out, {}, g)[0], 'sibling RomFS must not validate an explicit RomFS rewrite')
            nro.unlink()
            fresh, reason, _ = b.rewrite_freshness(REPO, exefs, out, {}, g, explicit_romfs)
            self.assertFalse(fresh)
            self.assertIn('missing collected NRO', reason)

    def test_stale_rewrite_updates_then_reuses_without_rewrite(self):
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='Launcher work ') as t:
            root = Path(t); exefs, romfs, patched, msl = self.make_layout(root, g)
            args = SimpleNamespace(check=False, windowed=True)
            chain = run_mac.chain_id(REPO)
            cache = msl / f'b-{chain}'; cache.mkdir(parents=True); (cache / 'test_b.metallib').write_bytes(b'x')
            stamp_nvn(cache, g)
            plan = {'game': g, 'base': root, 'version': g.get('package'), 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': chain, 'graphics': 'nvn'}
            env = {'DM_ASPECT_RATIO': '21:10'}
            calls = {'rewrite': 0, 'make': 0, 'exec': 0}
            def rewrite(*params):
                calls['rewrite'] += 1
                self.fill_outputs(REPO, exefs, patched, env, g)
            def make(repo, out, run_env, logs, game):
                calls['make'] += 1
                self.assertEqual(run_env['DM_GAME'], g.id)
                return self.fake_host(repo,out,run_env,logs,game)
            def exec_host(path, argv, run_env):
                calls['exec'] += 1
                self.assertEqual(argv[1], str(patched))
                self.assertEqual(run_env['DM_ROMFS'], str(romfs))
                self.assertEqual(run_env['DM_WINDOW_SIZE'], '1600x762')
            with redirect_stdout(io.StringIO()):
                self.assertEqual(run_mac.launch(plan, args, env, REPO, rewrite_call=rewrite, host_call=make, exec_call=exec_host), 0)
                self.assertEqual(run_mac.launch(plan, args, env, REPO, rewrite_call=rewrite, host_call=make, exec_call=exec_host), 0)
            self.assertEqual(calls, {'rewrite': 1, 'make': 2, 'exec': 2})

    def test_failed_rewrite_preserves_old_output_and_does_not_launch(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        b = module_from_spec(spec); spec.loader.exec_module(b)
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); exefs, romfs, patched, msl = self.make_layout(root, g)
            chain = run_mac.chain_id(REPO)
            cache = msl / f'b-{chain}'; cache.mkdir(parents=True); (cache / 'test_b.metallib').write_bytes(b'x')
            for name in b.rewrite_outputs(g.words('modules')): (patched / name).write_bytes(b'old-good-output')
            fresh, _, key = b.rewrite_freshness(REPO, exefs, patched, {}, g)
            patched.with_name(patched.name + '.key').write_text(key + '\n')
            self.assertTrue(b.rewrite_freshness(REPO, exefs, patched, {}, g)[0])
            first = g.words('modules')[0]
            sentinel = patched / f'{first}.patched.bin'
            sentinel.write_bytes(b'old-good-output')
            (exefs / first).write_bytes(b'changed-original')
            plan = {'game': g, 'base': root, 'version': g.get('package'), 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': chain, 'graphics': 'nvn'}
            fake_python = root / 'fake-python'
            fake_python.write_text('#!/bin/sh\nprintf partial > "$3/$4.patched.bin"\necho simulated rewrite failure >&2\nexit 9\n')
            fake_python.chmod(0o755)
            calls = []
            with self.assertRaises(run_mac.LaunchError), redirect_stdout(io.StringIO()):
                run_mac.launch(plan, SimpleNamespace(check=False, windowed=False), {}, REPO,
                               rewrite_call=lambda _py, repo, source, out, env, logs, game, romfs: b.rewrite(fake_python, repo, source, out, env, logs, game, romfs),
                               host_call=lambda *a: calls.append('make'), exec_call=lambda *a: calls.append('exec'))
            self.assertEqual(sentinel.read_bytes(), b'old-good-output')
            self.assertEqual(patched.with_name(patched.name + '.key').read_text(), key + '\n')
            self.assertEqual(calls, [])

    def test_check_is_read_only_and_reports_stale(self):
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); exefs, romfs, patched, msl = self.make_layout(root, g)
            before = set(root.rglob('*'))
            args = SimpleNamespace(check=True, windowed=False)
            plan = {'game': g, 'base': root, 'version': g.get('package'), 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': None}
            with redirect_stdout(io.StringIO()) as output:
                rc = run_mac.launch(plan, args, {}, REPO)
            self.assertEqual(rc, 1)
            self.assertIn('rewrite: stale', output.getvalue())
            self.assertEqual(set(root.rglob('*')), before)


if __name__ == '__main__': unittest.main()
