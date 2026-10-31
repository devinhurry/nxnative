#!/usr/bin/env python3
"""Run current source in test mode or a recorded, fixed release build."""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True


class LaunchError(Exception):
    pass


def profile(repo, game_id, env):
    sys.path.insert(0, str(repo / 'dm/games'))
    saved = {k: os.environ.get(k) for k in ('DM_GAME', 'DM_GAMES_DIR', 'DM_GAMES_FIRST')}
    try:
        os.environ['DM_GAME'] = game_id
        for key in ('DM_GAMES_DIR', 'DM_GAMES_FIRST'):
            if key in env: os.environ[key] = env[key]
            else: os.environ.pop(key, None)
        import game
        return game.load(game_id)
    except (SystemExit, OSError) as e:
        raise LaunchError(str(e)) from e
    finally:
        for key, value in saved.items():
            if value is None: os.environ.pop(key, None)
            else: os.environ[key] = value
        sys.path.pop(0)


def _path(value):
    return Path(value).expanduser().resolve() if value else None


_BUILD_NAME = re.compile(r'^([0-9A-Fa-f]{16})(?:_build|-work)$')


def resolve_game_input(repo, value, env):
    """Accept a profile selector, one standard work folder, or its parent."""
    if not value:
        raise LaunchError('set --game to a profile title ID, profile folder, or game work folder')
    path = _path(value)
    if path and path.is_dir():
        # A profile folder remains a profile selector, not a build root.
        if (path / 'game.tsv').is_file():
            return profile(repo, str(path), env), None

        direct = _BUILD_NAME.fullmatch(path.name)
        if direct:
            return profile(repo, direct.group(1).upper(), env), path

        # Only inspect immediate, conventionally named children. Do not search
        # arbitrary descendants or guess from the friendly parent-folder name.
        candidates = []
        try:
            children = sorted(path.iterdir(), key=lambda p: p.name)
        except OSError as e:
            raise LaunchError(f'cannot inspect game folder {path}: {e}') from e
        for child in children:
            match = _BUILD_NAME.fullmatch(child.name)
            if child.is_dir() and match:
                candidates.append((match.group(1).upper(), child))
        if len(candidates) > 1 and len({game_id for game_id, _ in candidates}) == 1:
            # The NSP pipeline's _build folder is canonical when both names exist.
            build_roots = [(game_id, child) for game_id, child in candidates if child.name.endswith('_build')]
            if len(build_roots) == 1:
                candidates = build_roots
        if len(candidates) > 1:
            choices = ', '.join(str(child) for _, child in candidates)
            raise LaunchError(f'multiple game builds found under {path}: {choices}; choose one with --game <folder>')
        if len(candidates) == 1:
            game_id, build = candidates[0]
            return profile(repo, game_id, env), build
        raise LaunchError(f'no prepared game build found under {path}; choose a game build/work folder or prepare it using build_ipa_from_nsp.py')

    # Preserve title-ID and external profile-directory selection.
    return profile(repo, value, env), None


def resolve_layout(base, version, mods, patched_arg=None, exefs_arg=None, romfs_arg=None):
    """Resolve one supported NSP/manual layout, with explicit ExeFS/RomFS pairing."""
    layouts = [
        (base / f'patched_{version}', base / 'extract' / version / 'ExeFS', base / 'extract' / version / 'RomFS'),
        (base / 'build' / f'patched_{version}', base / 'data' / version / 'ExeFS', base / 'data' / version / 'RomFS'),
    ]
    def candidate_rows(rows):
        return list(dict.fromkeys((_path(patched_arg or p), _path(exefs_arg or e), romfs_path(_path(romfs_arg or r))) for p, e, r in rows))
    candidates = candidate_rows(layouts)
    if romfs_arg and not exefs_arg and not any(e and e.is_dir() and r and r.exists() and all((e / m).is_file() for m in mods) for _, e, r in candidates):
        rom = _path(romfs_arg)
        assert rom is not None
        candidates += candidate_rows([(patched_arg or base / f'patched_{version}', rom.parent / 'ExeFS', rom)])
    patched_candidates = list(dict.fromkeys(c[0] for c in candidates))
    exefs_candidates = list(dict.fromkeys(c[1] for c in candidates))
    romfs_candidates = list(dict.fromkeys(c[2] for c in candidates))
    valid = [(p, e, r) for p, e, r in candidates if p and e and e.is_dir() and r and (r.is_dir() or r.is_file()) and all((e / m).is_file() for m in mods)]
    if len(valid) > 1:
        raise LaunchError('more than one complete build layout matches; specify --patched, --exefs and --romfs')
    if not valid:
        missing = []
        for label, paths in (('patched modules', patched_candidates), ('original ExeFS', exefs_candidates), ('RomFS', romfs_candidates)):
            found = next((p for p in paths if p and (p.is_dir() or (label == 'RomFS' and p.is_file()))), None)
            if not found: missing.append(f'{label}: tried ' + ', '.join(str(p) for p in paths))
        for exefs in exefs_candidates:
            if exefs and exefs.is_dir():
                absent = [m for m in mods if not (exefs / m).is_file()]
                if absent: missing.append(f'{exefs}: missing profile module(s): {", ".join(absent)}')
        if not missing: missing.append('no single layout contains all profile modules in ExeFS and matching patched/RomFS folders')
        raise LaunchError('could not resolve a complete build layout\n  ' + '\n  '.join(missing) + '\nUse --patched, --exefs and --romfs to name the actual folders.')
    return valid[0]


def romfs_path(path):
    if path and not path.exists() and path.with_name(path.name + '.img').is_file():
        return path.with_name(path.name + '.img')
    return path


def test_work(base, game):
    root = base.with_name(f'{game.id}-work') if base.name == f'{game.id}_build' else base
    return root / 'mac-test'


def chain_id(repo):
    try: match = re.search(r'#define DMSH_CHAIN "([^"]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text())
    except OSError: return None
    return match.group(1) if match else None


def nvn_stamp_matches(repo, library_dir, g):
    """Use the build pipeline's profile digest to distinguish games sharing the global chain folder."""
    from importlib.util import spec_from_file_location, module_from_spec
    spec = spec_from_file_location('dmsh_chain', repo / 'dm/gfx/tools/dmsh_chain.py')
    assert spec is not None and spec.loader is not None
    chain = module_from_spec(spec); spec.loader.exec_module(chain)
    stamp = chain.read_stamp(library_dir)
    return stamp.get('game') == g.id and stamp.get('inputs') == chain.inputs(g)


def resolve_shader_cache(base, g, override, layout, chain):
    """Select a cache by complete backend artifacts, never by game-name prose."""
    root = _path(override)
    if root and root.name.startswith('b-'):
        if not chain or root.name != f'b-{chain}': raise LaunchError(f'--msl must be the shader-cache parent, not mismatched chain folder {root}')
        root = root.parent
    roots = [root] if root else ([base / 'build/cache/metal_shader_cache', base / 'shader'] if layout == 'manual' else [base / 'shader/cache', base / 'shader'])
    roots = list(dict.fromkeys(Path(p).expanduser().resolve() for p in roots))
    matches = []
    for candidate in roots:
        nvn = candidate / f'b-{chain}' if chain else None
        if nvn and nvn.is_dir() and any(nvn.glob('*_b.metallib')) and g.table('shader_map.tsv').is_file() and nvn_stamp_matches(Path(__file__).resolve().parent.parent, nvn, g): matches.append(('nvn', candidate))
        for api, subdir, table, lib in (('vulkan', 'vk', 'vk_shaders.tsv', 'vk_shaders.metallib'), ('gl', 'gl', 'gl_shaders.tsv', 'gl_shaders.metallib')):
            d = candidate / subdir
            if (d / table).is_file() and (d / lib).is_file(): matches.append((api, candidate))
    matches = list(dict.fromkeys(matches))
    if len(matches) > 1:
        raise LaunchError('multiple complete shader cache backends were found: ' + ', '.join(f'{api} at {root}' for api, root in matches) + '; set --msl to the intended cache root')
    if matches: return matches[0][1], matches[0][0], roots
    return roots[0], None, roots


def resolve_release(base, g):
    """Load a recorded release, independent of subsequent working-tree changes."""
    manifest = base / 'run/mac-runtime.json'
    try:
        data = json.loads(manifest.read_text())
    except (OSError, ValueError) as e:
        raise LaunchError(f'no readable prepared runtime at {manifest}: {e}; prepare a Mac build first') from e
    if not isinstance(data, dict) or data.get('schema') != 2 or data.get('mode') != 'release' or data.get('game') != g.id:
        raise LaunchError(f'no current release record for {g.id}: {manifest}; prepare it with build_ipa_from_nsp.py --platform mac')
    def path(value):
        p = Path(value).expanduser()
        return (p if p.is_absolute() else manifest.parent / p).resolve()
    try:
        result = {k: path(data[k]) for k in ('host', 'patched', 'romfs', 'msl', 'cwd')}
        checks = data['checksums']
        if not isinstance(checks, dict): raise ValueError('missing checksums')
        checked_paths = {path(k) for k in checks}
        if result['host'] not in checked_paths: raise ValueError('missing host checksum')
        if not isinstance(data['version'], str): raise ValueError('missing version')
        for value, digest in checks.items():
            item = path(value)
            if hashlib.sha256(item.read_bytes()).hexdigest() != digest:
                raise LaunchError(f'prepared runtime changed: {item}; prepare it again')
        if not os.access(result['host'], os.X_OK): raise ValueError('host is not executable')
        for k in ('patched', 'msl', 'cwd'):
            if not result[k].is_dir(): raise ValueError(f'missing {k}: {result[k]}')
        if not (result['romfs'].is_dir() or result['romfs'].is_file()): raise ValueError(f'missing romfs: {result["romfs"]}')
        source = data['source']
        if not isinstance(source['commit'], str) or not isinstance(source['dirty'], bool) or not source['inputs']:
            raise ValueError('missing compiled source identity')
        if source['host_sha256'] != checks[str(result['host'])]: raise ValueError('compiled source does not name the recorded host')
        if data['graphics'] == 'nvn' and source['shader_chain'] != data['chain']: raise ValueError('host/shader chain mismatch')
        modules = data['modules']
        if not isinstance(modules, list) or not modules or not all(isinstance(m, str) for m in modules): raise ValueError('missing recorded module list')
        for mod in modules:
            for suffix in ('patched.bin', 'fixups.tsv', 'gates.tsv'):
                item = (result['patched'] / f'{mod}.{suffix}').resolve()
                if not item.is_file() or item not in checked_paths:
                    raise ValueError(f'missing prepared module: {mod}.{suffix}')
        if data['graphics'] == 'nvn':
            lib = result['msl'] / f'b-{data["chain"]}'
            if not any(lib.glob('*_b.metallib')): raise ValueError(f'missing prepared shaders: {lib}')
            if (lib / 'inputs.tsv').resolve() not in checked_paths:
                raise ValueError('missing shader stamp checksum')
        elif data['graphics'] not in ('vulkan', 'gl'):
            raise ValueError('unsupported prepared graphics backend')
        runtime_env = data.get('environment', {})
        if not isinstance(runtime_env, dict) or not all(k.startswith('DM_') and isinstance(v, str) for k, v in runtime_env.items()):
            raise ValueError('invalid prepared environment')
        if data['graphics'] == 'nvn' and path(runtime_env['DM_NVN_SHMAP']) not in checked_paths:
            raise ValueError('missing prepared shader map checksum')
    except (KeyError, TypeError, ValueError, OSError) as e:
        raise LaunchError(f'incomplete prepared runtime {manifest}: {e}') from e
    return dict(result, game=g, base=base, version=data['version'], runtime=manifest,
                runtime_env=runtime_env, source=source, chain=data['chain'], mode='release', description=data.get('description', 'prepared Mac build'))


def resolve(args, env, repo):
    game_id = args.game or env.get('DM_GAME')
    g, discovered_build = resolve_game_input(repo, game_id, env)
    if getattr(args, 'touch_preview', False) and g.id != '01007EF00011E000':
        raise LaunchError('--touch-preview is currently available only for Breath of the Wild (01007EF00011E000)')
    base = _path(args.build) or discovered_build or _path(env.get('DM_ROOT'))
    if not base or not base.is_dir(): raise LaunchError('set --build or DM_ROOT to an existing game build folder, or pass a game folder containing <ID>_build / <ID>-work')
    if getattr(args, 'mode', 'test') == 'release':
        if any(getattr(args, k, None) for k in ('version', 'patched', 'exefs', 'romfs', 'msl')):
            raise LaunchError('--release uses the recorded runtime; omit --version/--patched/--exefs/--romfs/--msl')
        if base.name == f'{g.id}-work': base = base.with_name(f'{g.id}_build')
        return resolve_release(base, g)
    version = args.version or env.get('DM_VERSION') or g.get('package', '')
    if not version: raise LaunchError(f'{g.id} profile has no package version; pass --version')
    if version not in g.builds(): raise LaunchError(f'profile {g.id} has no build row for {version}; choose one of: {", ".join(g.builds())}')
    if base.name == f'{g.id}-work' and not (base / 'extract').is_dir() and not (base / 'data').is_dir():
        sibling = base.with_name(f'{g.id}_build')
        if sibling.is_dir(): base = sibling
    patched, exefs, romfs = resolve_layout(base, version, g.words('modules'), args.patched, args.exefs or env.get('DM_EXEFS'), args.romfs or env.get('DM_ROMFS'))
    layout = 'manual' if patched.parent == base / 'build' else 'runtime' if patched.parent == base else 'nsp'
    work = test_work(base, g)
    patched = _path(args.patched) or work / f'patched_{version}'
    chain = chain_id(repo)
    override = args.msl or env.get('DM_MSL_DIR')
    msl, graphics, cache_roots = resolve_shader_cache(work, g, override, 'nsp', chain)
    if not graphics and not override:
        shared, graphics, roots = resolve_shader_cache(base, g, None, layout, chain)
        cache_roots += roots
        if graphics: msl = shared
    return {'game': g, 'base': base, 'work': work, 'mode': 'test', 'version': version, 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': chain, 'layout': layout, 'graphics': graphics, 'cache_roots': cache_roots}


def refresh_shaders(plan, env, repo, builder, logs):
    """Reuse the NSP builder's shader preparation, writing only into the test work folder."""
    progress = builder.PROG
    previous_mode = progress.mode
    progress.mode = builder.progress_mode('auto')
    progress.plan(1)
    progress.stage('Shader inputs', step='inspecting the extraction')
    success = False
    try:
        _refresh_shaders(plan, env, repo, builder, logs)
        success = True
    finally:
        progress.close(ok=success)
        progress.mode = previous_mode


def _refresh_shaders(plan, env, repo, builder, logs):
    from importlib.util import spec_from_file_location, module_from_spec
    spec = spec_from_file_location('test_profile_guess', repo / 'dm/games/profile_guess.py')
    assert spec is not None and spec.loader is not None
    pg = module_from_spec(spec); spec.loader.exec_module(pg)
    builder.pg = pg
    g, work = plan['game'], plan['work']
    py = Path(sys.executable)
    builder.check_native_python()
    sources = pg.build_sources(plan['exefs'], plan['romfs'], g.words('modules'))
    api = sources['graphics'][0]
    if api == 'nvn':
        builder.configure_dotnet(env)
        builder.check_translator(repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate', env)
    stages = 2 + sum(bool(sources[k][0]) for k in ('glslc_capture', 'ue_decode')) if api == 'nvn' else 1 + bool(sources['vk_capture' if api == 'vulkan' else 'gl_capture'][0])
    builder.PROG.add(stages)
    sh = work / 'shader'
    dirs = {}
    versions = g.words('shader_versions') or [plan['version']]
    for version in dict.fromkeys(versions + [plan['version']]):
        _, exefs, romfs = resolve_layout(plan['base'], version, g.words('modules'),
            patched_arg=plan['patched'] if version == plan['version'] else None,
            exefs_arg=plan['exefs'] if version == plan['version'] else None,
            romfs_arg=plan['romfs'] if version == plan['version'] else None)
        d = work / 'extract' / version; d.mkdir(parents=True, exist_ok=True)
        for target, source in ((d / 'ExeFS', exefs), (d / ('RomFS.img' if romfs.is_file() else 'RomFS'), romfs)):
            if target.is_symlink() and target.resolve() != source.resolve(): target.unlink()
            if not target.exists(): target.symlink_to(source, target_is_directory=source.is_dir())
        dirs[version] = d
    game = dirs[plan['version']]
    if api == 'nvn':
        builder.check_metal(py, repo, env)
        if sources['glslc_capture'][0]: builder.capture_glslc(repo, dirs, plan['version'], plan['patched'], work, env, logs, g)
        if sources['ue_decode'][0]: builder.decode_ue_shaders(repo, dirs, plan['version'], plan['patched'], work, env, logs, g)
        oodle = (lambda: dict(DM_OODLE_HOST=str(builder.build_mac_host(repo, work / 'tools/dmhost', env, logs, g)), DM_OODLE_MODULES=str(plan['patched']))) if sources['oodle_packs'][0] or sources['ue_legacy'][0] else None
        aoc = _path(env.get('DM_AOC_DIR')) or plan['base'] / 'aoc'
        dlc = sorted(p for p in aoc.iterdir() if p.is_dir() or p.suffix == '.img') if aoc.is_dir() else []
        key = builder.split_shaders(py, repo, [builder.rfs.source(dirs[v]) for v in versions],
            [dirs[v] / 'ExeFS/main' for v in versions], sh / 'pkg', env, logs, g, oodle=oodle, dlc_roms=dlc)
        msl = builder.build_shaders(py, repo, sh, repo / 'dm/gfx/tools/dmsh_xlate_bin/dmsh_xlate', env, logs, g, key, mac=True)
    else:
        capture = sources['vk_capture' if api == 'vulkan' else 'gl_capture'][0]
        cap = builder.capture_shaders(repo, game, plan['patched'], work, env, logs, g, 'vk' if api == 'vulkan' else 'gl') if capture else None
        roots = [plan['romfs']] + ([plan['exefs'] / 'main'] if api == 'gl' else []) + ([cap] if cap else [])
        build = builder.build_vk_shaders if api == 'vulkan' else builder.build_gl_shaders
        msl = build(py, repo, roots, sh, env, logs, g, mac=True)
    plan.update(msl=msl, graphics=api)


def profile_environment(env, g, repo):
    env = dict(env)
    profile_root = g.dir.parent.resolve()
    repo_profiles = (repo / 'dm/games').resolve()
    if profile_root != repo_profiles:
        extras = [Path(p).resolve() for p in env.get('DM_GAMES_DIR', '').split(':') if p]
        extras = [profile_root] + [p for p in extras if p != profile_root]
        env['DM_GAMES_DIR'] = ':'.join(str(p) for p in extras)
        env['DM_GAMES_FIRST'] = '1'
    else:
        env.pop('DM_GAMES_FIRST', None)
    return env


def launch(plan, args, env, repo, rewrite_call=None, host_call=None, exec_call=None, builder=None, shader_call=None):
    if plan.get('runtime'):
        print_runtime(plan)
        if args.check: return 0
        return launch_host(plan, args, env, repo, exec_call=exec_call, prepared_host=plan['host'])
    from importlib.util import spec_from_file_location, module_from_spec
    if builder is None:
        spec = spec_from_file_location('build_ipa_from_nsp', repo / 'scripts/build_ipa_from_nsp.py')
        assert spec is not None and spec.loader is not None
        builder = module_from_spec(spec); spec.loader.exec_module(builder)
    plan.setdefault('work', test_work(plan['base'], plan['game']))
    work = plan['work']
    logs = work / 'logs'
    env = profile_environment(dict(env, DM_GAME=plan['game'].id, DM_ROOT=str(plan['base']), WORK=str(work / 'tmp')), plan['game'], repo)
    if getattr(args, 'allow_other_metal', False): env['DM_ALLOW_OTHER_METAL'] = '1'
    if not args.check:
        logs.mkdir(parents=True, exist_ok=True)
        try: builder.chain_header(Path(sys.executable), repo, env, logs)
        except builder.BuildError as e: raise LaunchError(f'test shader-chain check failed: {e}') from e
        plan['chain'] = chain_id(repo)
    fresh, reason, _ = builder.rewrite_freshness(repo, plan['exefs'], plan['patched'], env, plan['game'], plan['romfs'])
    print(f'mode: test\ntest work: {work}\nhost target: {work / "tools/dmhost"}\ngame: {plan["game"].id} ({plan["game"].get("name", "")})\nprofile: {plan["game"].dir}\nversion: {plan["version"]}\nbuild: {plan["base"]}\npatched: {plan["patched"]}\nExeFS: {plan["exefs"]}\nRomFS: {plan["romfs"]}\nshader cache root: {plan["msl"]}')
    graphics = plan.get('graphics')
    if graphics == 'nvn':
        shader_dir = plan['msl'] / f'b-{plan["chain"]}' if plan['chain'] else None
        shader_ready = bool(shader_dir and shader_dir.is_dir() and any(shader_dir.glob('*_b.metallib')) and plan['game'].table('shader_map.tsv').is_file() and nvn_stamp_matches(repo, shader_dir, plan['game']))
        shader_reason = f'NVN chain cache or profile shader map missing: {shader_dir}' if not shader_ready else 'NVN chain cache and profile shader map present'
    elif graphics in ('vulkan', 'gl'):
        api = 'vk' if graphics == 'vulkan' else 'gl'
        shader_dir = plan['msl'] / api if api else None
        expected = {'vk': ('vk_shaders.tsv', 'vk_shaders.metallib'), 'gl': ('gl_shaders.tsv', 'gl_shaders.metallib')}.get(api, ())
        shader_ready = bool(shader_dir and all((shader_dir / x).is_file() for x in expected))
        shader_reason = f'{graphics} shader artifacts missing under {shader_dir}' if not shader_ready else f'{graphics} shader artifacts present'
    else:
        shader_ready = False
        shader_reason = 'no complete shader backend artifacts found under: ' + ', '.join(str(p) for p in plan.get('cache_roots', [plan['msl']]))
    print(f'shaders: {"ready" if shader_ready else "missing"} ({shader_reason})')
    if args.check:
        print(f'rewrite: {"fresh" if fresh else "stale"} ({reason})')
        return 0 if fresh and shader_ready else 1
    logs.mkdir(parents=True, exist_ok=True)
    (work / 'tmp').mkdir(parents=True, exist_ok=True)
    if not fresh:
        print(f'rewrite: refreshing ({reason})')
        try:
            for module in ('lz4.block', 'capstone'): __import__(module)
        except ImportError as e:
            raise LaunchError(f'cannot rewrite stale modules; install the Python dependency {e.name!r} first') from e
        builder.PROG.plan(1)
        try: (rewrite_call or builder.rewrite)(Path(sys.executable), repo, plan['exefs'], plan['patched'], env, logs, plan['game'], plan['romfs'])
        except Exception as e: raise LaunchError(f'module rewrite failed: {e}') from e
        fresh, reason, _ = builder.rewrite_freshness(repo, plan['exefs'], plan['patched'], env, plan['game'], plan['romfs'])
        if not fresh: raise LaunchError(f'rewrite did not produce a complete current output: {reason}')
    if not shader_ready or graphics in ('vulkan', 'gl'):
        print('shaders: preparing current inputs in the test work folder')
        try: (shader_call or refresh_shaders)(plan, env, repo, builder, logs)
        except Exception as e: raise LaunchError(f'test shader preparation failed: {e}') from e
    try:
        host = (host_call or builder.build_mac_host)(repo, work / 'tools/dmhost', env, logs, plan['game'])
        run_env = dict(env, DM_ROMFS=str(plan['romfs']), DM_MSL_DIR=str(plan['msl']))
        if plan['graphics'] == 'nvn': run_env['DM_NVN_SHMAP'] = str(plan['game'].table('shader_map.tsv'))
        if not run_env.get('DM_FONT_DIR') and (plan['base'] / 'font').is_dir(): run_env['DM_FONT_DIR'] = str(plan['base'] / 'font')
        (work / 'run').mkdir(exist_ok=True)
        manifest = builder.write_mac_runtime(work, host, plan['patched'], run_env, plan['game'], plan['graphics'],
            plan['chain'] if plan['graphics'] == 'nvn' else None, mode='test')
        recorded = json.loads(manifest.read_text())
    except (OSError, ValueError, builder.BuildError) as e: raise LaunchError(f'test host preparation failed: {e}') from e
    plan.update(host=host, source=recorded['source'], runtime_env=recorded['environment'], cwd=Path(recorded['cwd']), mode='test')
    print_runtime(plan)
    return launch_host(plan, args, env, repo, exec_call=exec_call, prepared_host=host)


def print_runtime(plan):
    source = plan['source']
    print(f'mode: {plan["mode"]}\nversion: {plan["version"]}\ncode: {source["commit"]}' + (' + uncommitted changes' if source['dirty'] else '') +
          f'\ncode inputs: {source["inputs"]}\nshader chain: {plan["chain"] or plan.get("graphics", "unknown")}\nhost: {plan["host"]}\npatched: {plan["patched"]}\nRomFS: {plan["romfs"]}\nshader cache: {plan["msl"]}')


def launch_host(plan, args, env, repo, exec_call=None, prepared_host=None):
    env = dict(plan.get('runtime_env', {}), **env)
    if prepared_host:
        for key in ('DM_NVN_SHMAP', 'DM_FONT_DIR', 'DM_AOC_DIR', 'DM_PSO_PAIRS'):
            if key in plan['runtime_env']: env[key] = plan['runtime_env'][key]
    game_id = plan['game'].id
    env.update(DM_GAME=game_id, DM_ROOT=str(plan['base']), DM_ROMFS=str(plan['romfs']), DM_MSL_DIR=str(plan['msl']))
    if getattr(args, 'touch_preview', False): env['DM_TOUCH_PREVIEW'] = '1'
    else: env.pop('DM_TOUCH_PREVIEW', None)
    env.setdefault('DM_NVN_SHMAP', str(plan['game'].table('shader_map.tsv')))
    env = profile_environment(env, plan['game'], repo)
    env.setdefault('DM_SAVE', str(plan['base'] / 'run' / 'save'))
    if getattr(args, 'save_copy', None) is not None:
        source = _path(args.save_copy)
        if not source or not source.is_dir(): raise LaunchError(f'save source is not a folder: {args.save_copy}')
        copies = (plan['base'] / 'run' / 'save-copies').resolve()
        if copies == source or source in copies.parents:
            raise LaunchError(f'save source contains the copy destination: {copies}; choose a narrower save folder')
        copies.mkdir(parents=True, exist_ok=True)
        save = Path(tempfile.mkdtemp(prefix=source.name + '-', dir=copies)) / 'save'
        # Follow source symlinks while copying so game writes cannot reach the original files.
        shutil.copytree(source, save)
        env['DM_SAVE'] = str(save)
        print(f'save source (unchanged): {source}')
    print(f'save folder: {env["DM_SAVE"]}')
    env.setdefault('DM_TEMP', str(plan['base'] / 'run' / 'tmp'))
    if env.get('DM_WINDOW') is None: env['DM_WINDOW'] = '1'
    if env.get('DM_FULLSCREEN') is None: env['DM_FULLSCREEN'] = '1'
    if args.windowed:
        env['DM_FULLSCREEN'] = '0'
        if not env.get('DM_WINDOW_SIZE') and env.get('DM_ASPECT_RATIO'):
            try:
                match = re.fullmatch(r'\s*([0-9.]+)\s*[:/x]\s*([0-9.]+)\s*', env['DM_ASPECT_RATIO'])
                ratio = float(match.group(1)) / float(match.group(2)) if match else float(env['DM_ASPECT_RATIO'])
                if not 0.1 <= ratio <= 10: raise ValueError('ratio out of range')
                env['DM_WINDOW_SIZE'] = f'1600x{round(1600 / ratio)}'
            except (ValueError, ZeroDivisionError) as e: raise LaunchError(f'invalid DM_ASPECT_RATIO: {env["DM_ASPECT_RATIO"]}') from e
    Path(env['DM_SAVE']).mkdir(parents=True, exist_ok=True)
    Path(env['DM_TEMP']).mkdir(parents=True, exist_ok=True)
    exe = prepared_host or repo / 'dm/host/dmhost'
    print(f'launch: {exe} {plan["patched"]}')
    previous_cwd = Path.cwd()
    try:
        if prepared_host: os.chdir(plan['cwd'])
        (exec_call or os.execvpe)(str(exe), [str(exe), str(plan['patched'])], env)
    finally:
        os.chdir(previous_cwd)
    return 0


def parser():
    p = argparse.ArgumentParser(description='Run current source (--test, default) or a fixed prepared build (--release).', allow_abbrev=False)
    mode = p.add_mutually_exclusive_group()
    mode.add_argument('--test', dest='mode', action='store_const', const='test', help='update current host, rewritten modules and required shaders in the test work folder (default)')
    mode.add_argument('--release', dest='mode', action='store_const', const='release', help='verify and launch the fixed runtime from build_ipa_from_nsp.py --platform mac')
    p.set_defaults(mode='test')
    p.add_argument('--game', help='game work folder, parent containing <ID>_build / <ID>-work, profile folder, or title ID (default: DM_GAME)')
    p.add_argument('--build', help='game build/work folder (default: DM_ROOT)')
    p.add_argument('--version', help='profile package version (default: profile package)')
    p.add_argument('--patched', help='rewritten module folder')
    p.add_argument('--exefs', help='original module folder')
    p.add_argument('--romfs', help='RomFS folder or image (default: DM_ROMFS or detected layout)')
    p.add_argument('--msl', help='shader cache parent (default: DM_MSL_DIR or detected layout)')
    p.add_argument('--save-copy', metavar='DIR', help='start from an independent copy of DIR under the game build/run/save-copies; original save unchanged, overrides DM_SAVE for this run')
    p.add_argument('--windowed', action='store_true', help='disable fullscreen; DM_ASPECT_RATIO still sets the window size')
    p.add_argument('--touch-preview', action='store_true', help='BOTW-only Mac preview of the iOS virtual touch controls and relocated touch HUD')
    p.add_argument('--allow-other-metal', action='store_true', help='allow an untested local Metal compiler when preparing test shaders; keeps the toolchain lock unchanged')
    p.add_argument('--check', action='store_true', help='report resolved paths and rewrite freshness without changing files or building')
    return p


def main(argv=None):
    args = parser().parse_args(argv)
    repo = Path(__file__).resolve().parent.parent
    try: return launch(resolve(args, os.environ, repo), args, dict(os.environ), repo)
    except (LaunchError, OSError, subprocess.CalledProcessError) as e:
        print(f'[RED] {e}', file=sys.stderr)
        return 1


if __name__ == '__main__': sys.exit(main())
