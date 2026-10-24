import importlib.util
import io
import shutil
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace


REPO = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('run_mac', REPO / 'scripts/run_mac.py')
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


class MacLauncherTests(unittest.TestCase):
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
        b = module_from_spec(spec); spec.loader.exec_module(b)
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
            self.assertEqual((plan['patched'], plan['exefs'], plan['romfs']), (patched.resolve(), exefs.resolve(), romfs.resolve()))
            self.assertEqual(plan['msl'], msl.resolve())

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
                             (patched.resolve(), exefs.resolve(), romfs.resolve()))

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
            self.assertEqual(plan['patched'], (root / 'build' / f'patched_{g.get("package")}').resolve())
            self.assertFalse(plan['patched'].exists())
            self.assertEqual(plan['msl'], (root / 'build/cache/metal_shader_cache').resolve())
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
                def __init__(self, directory): self.dir = directory
                def get(self, key, default=None): return default
                def table(self, name): return self.dir / name
            bare = BareProfile(root / 'bare-profile'); bare.dir.mkdir()
            (bare.table('shader_map.tsv')).write_text('header\n')
            (bare.table('dmsh_chain.h')).write_text('#define DMSH_CHAIN "chain-id"\n')
            nvn = root / 'shader/cache/b-chain-id'; nvn.mkdir(parents=True)
            (nvn / 'test_b.metallib').write_bytes(b'x')
            (root / 'shader/vk').mkdir()
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, None, 'nsp')
            self.assertEqual((cache, api), ((root / 'shader/cache').resolve(), 'nvn'))

            external = root / 'external shader output'; (external / 'vk').mkdir(parents=True)
            (external / 'vk/vk_shaders.tsv').write_text('table')
            (external / 'vk/vk_shaders.metallib').write_bytes(b'x')
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, external, 'nsp')
            self.assertEqual((cache, api), (external.resolve(), 'vulkan'))
            (external / 'gl').mkdir()
            (external / 'gl/gl_shaders.tsv').write_text('table')
            (external / 'gl/gl_shaders.metallib').write_bytes(b'x')
            with self.assertRaisesRegex(run_mac.LaunchError, 'multiple complete'):
                run_mac.resolve_shader_cache(root, bare, external, 'nsp')
            (external / 'vk/vk_shaders.tsv').unlink(); (external / 'vk/vk_shaders.metallib').unlink()
            cache, api, _ = run_mac.resolve_shader_cache(root, bare, external, 'nsp')
            self.assertEqual((cache, api), (external.resolve(), 'gl'))

    def test_external_profile_shadow_is_forwarded_to_make(self):
        g0 = game_profile()
        with tempfile.TemporaryDirectory(prefix='External profiles ') as t:
            root = Path(t); profiles = root / 'profiles'; ext = profiles / g0.id; ext.mkdir(parents=True)
            for name in ('game.tsv', 'dmsh_chain.h', 'shader_map.tsv'):
                shutil.copy2(g0.dir / name, ext / name)
            env = {'DM_GAMES_DIR': str(profiles), 'DM_GAMES_FIRST': '1'}
            build = root / 'game work'; build.mkdir()
            exefs, romfs, patched, msl = self.make_layout(build, g0)
            chain = run_mac.chain_id(g0)
            cache = msl / f'b-{chain}'; cache.mkdir(parents=True); (cache / 'test_b.metallib').write_bytes(b'x')
            args = SimpleNamespace(game=g0.id, build=str(build), version=None, patched=None, exefs=None, romfs=None, msl=None)
            plan = run_mac.resolve(args, env, REPO)
            self.assertEqual(plan['game'].dir.resolve(), ext.resolve())
            self.fill_outputs(REPO, exefs, patched, env, plan['game'])
            observed = []
            def make(_cmd, make_env):
                observed.extend((make_env['DM_GAMES_DIR'].split(':')[0], make_env['DM_GAMES_FIRST'], make_env['DM_NVN_SHMAP']))
            with redirect_stdout(io.StringIO()):
                run_mac.launch(plan, SimpleNamespace(check=False, windowed=False), dict(env), REPO,
                               make_call=make, exec_call=lambda *_: None)
            self.assertEqual(observed, [str(profiles.resolve()), '1', str((ext / 'shader_map.tsv').resolve())])

            repo_args = SimpleNamespace(game=str(g0.dir), build=str(build), version=None, patched=None, exefs=None, romfs=None, msl=None)
            repo_plan = run_mac.resolve(repo_args, env, REPO)
            self.assertEqual(repo_plan['game'].dir.resolve(), g0.dir.resolve())
            observed.clear()
            def make_repo(_cmd, make_env):
                observed.extend((make_env.get('DM_GAMES_FIRST'), make_env['DM_NVN_SHMAP']))
            with redirect_stdout(io.StringIO()):
                run_mac.launch(repo_plan, SimpleNamespace(check=False, windowed=False), dict(env), REPO,
                               make_call=make_repo, exec_call=lambda *_: None)
            self.assertEqual(observed, [None, str((g0.dir / 'shader_map.tsv').resolve())])

    def test_freshness_requires_all_rewrite_sidecars(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
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

    def test_stale_rewrite_updates_then_reuses_without_rewrite(self):
        g = game_profile()
        with tempfile.TemporaryDirectory(prefix='Launcher work ') as t:
            root = Path(t); exefs, romfs, patched, msl = self.make_layout(root, g)
            args = SimpleNamespace(check=False, windowed=True)
            chain = run_mac.chain_id(g)
            cache = msl / f'b-{chain}'; cache.mkdir(parents=True); (cache / 'test_b.metallib').write_bytes(b'x')
            plan = {'game': g, 'base': root, 'version': g.get('package'), 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': chain, 'graphics': 'nvn'}
            env = {'DM_ASPECT_RATIO': '21:10'}
            calls = {'rewrite': 0, 'make': 0, 'exec': 0}
            def rewrite(*params):
                calls['rewrite'] += 1
                self.fill_outputs(REPO, exefs, patched, env, g)
            def make(cmd, run_env):
                calls['make'] += 1
                self.assertIn(f'GAME={g.id}', cmd)
                self.assertEqual(run_env['DM_ROMFS'], str(romfs))
                self.assertEqual(run_env['DM_WINDOW_SIZE'], '1600x762')
            def exec_host(path, argv, run_env):
                calls['exec'] += 1
                self.assertEqual(argv[1], str(patched))
            with redirect_stdout(io.StringIO()):
                self.assertEqual(run_mac.launch(plan, args, env, REPO, rewrite_call=rewrite, make_call=make, exec_call=exec_host), 0)
                self.assertEqual(run_mac.launch(plan, args, env, REPO, rewrite_call=rewrite, make_call=make, exec_call=exec_host), 0)
            self.assertEqual(calls, {'rewrite': 1, 'make': 2, 'exec': 2})

    def test_failed_rewrite_preserves_old_output_and_does_not_launch(self):
        from importlib.util import spec_from_file_location, module_from_spec
        spec = spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        b = module_from_spec(spec); spec.loader.exec_module(b)
        g = game_profile()
        with tempfile.TemporaryDirectory() as t:
            root = Path(t); exefs, romfs, patched, msl = self.make_layout(root, g)
            chain = run_mac.chain_id(g)
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
                               rewrite_call=lambda _py, repo, source, out, env, logs, game: b.rewrite(fake_python, repo, source, out, env, logs, game),
                               make_call=lambda *a: calls.append('make'), exec_call=lambda *a: calls.append('exec'))
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
