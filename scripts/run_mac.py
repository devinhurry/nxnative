#!/usr/bin/env python3
"""Rewrite and launch a game's Mac host from an extracted game build."""
import argparse
import os
import re
import subprocess
import sys
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
        return list(dict.fromkeys(tuple(_path(x) for x in (patched_arg or p, exefs_arg or e, romfs_arg or r)) for p, e, r in rows))
    candidates = candidate_rows(layouts)
    if romfs_arg and not exefs_arg and not any(e and e.is_dir() and r and r.is_dir() and all((e / m).is_file() for m in mods) for _, e, r in candidates):
        rom = _path(romfs_arg)
        candidates += candidate_rows([(patched_arg or base / f'patched_{version}', rom.parent / 'ExeFS', rom)])
    patched_candidates = list(dict.fromkeys(c[0] for c in candidates))
    exefs_candidates = list(dict.fromkeys(c[1] for c in candidates))
    romfs_candidates = list(dict.fromkeys(c[2] for c in candidates))
    valid = [(p, e, r) for p, e, r in candidates if p and e and e.is_dir() and r and r.is_dir() and all((e / m).is_file() for m in mods)]
    if len(valid) > 1:
        raise LaunchError('more than one complete build layout matches; specify --patched, --exefs and --romfs')
    if not valid:
        missing = []
        for label, paths in (('patched modules', patched_candidates), ('original ExeFS', exefs_candidates), ('RomFS', romfs_candidates)):
            found = next((p for p in paths if p and p.is_dir()), None)
            if not found: missing.append(f'{label}: tried ' + ', '.join(str(p) for p in paths))
        for exefs in exefs_candidates:
            if exefs and exefs.is_dir():
                absent = [m for m in mods if not (exefs / m).is_file()]
                if absent: missing.append(f'{exefs}: missing profile module(s): {", ".join(absent)}')
        if not missing: missing.append('no single layout contains all profile modules in ExeFS and matching patched/RomFS folders')
        raise LaunchError('could not resolve a complete build layout\n  ' + '\n  '.join(missing) + '\nUse --patched, --exefs and --romfs to name the actual folders.')
    return valid[0]


def chain_id(repo):
    try: return re.search(r'#define DMSH_CHAIN "([^"]+)"', (repo / 'dm/gfx/nvn/dmsh_chain.h').read_text()).group(1)
    except (OSError, AttributeError): return None


def nvn_stamp_matches(repo, library_dir, g):
    """Use the build pipeline's profile digest to distinguish games sharing the global chain folder."""
    from importlib.util import spec_from_file_location, module_from_spec
    spec = spec_from_file_location('dmsh_chain', repo / 'dm/gfx/tools/dmsh_chain.py')
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
    roots = list(dict.fromkeys(_path(p) for p in roots))
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


def resolve(args, env, repo):
    game_id = args.game or env.get('DM_GAME')
    g, discovered_build = resolve_game_input(repo, game_id, env)
    base = _path(args.build) or discovered_build or _path(env.get('DM_ROOT'))
    if not base or not base.is_dir(): raise LaunchError('set --build or DM_ROOT to an existing game build folder, or pass a game folder containing <ID>_build / <ID>-work')
    version = args.version or env.get('DM_VERSION') or g.get('package', '')
    if not version: raise LaunchError(f'{g.id} profile has no package version; pass --version')
    if version not in g.builds(): raise LaunchError(f'profile {g.id} has no build row for {version}; choose one of: {", ".join(g.builds())}')
    patched, exefs, romfs = resolve_layout(base, version, g.words('modules'), args.patched, args.exefs or env.get('DM_EXEFS'), args.romfs or env.get('DM_ROMFS'))
    layout = 'manual' if patched.parent == base / 'build' else 'runtime' if patched.parent == base else 'nsp'
    chain = chain_id(repo)
    msl, graphics, cache_roots = resolve_shader_cache(base, g, args.msl or env.get('DM_MSL_DIR'), layout, chain)
    return {'game': g, 'base': base, 'version': version, 'patched': patched, 'exefs': exefs, 'romfs': romfs, 'msl': msl, 'chain': chain, 'layout': layout, 'graphics': graphics, 'cache_roots': cache_roots}


def launch(plan, args, env, repo, rewrite_call=None, make_call=None, exec_call=None, builder=None):
    from importlib.util import spec_from_file_location, module_from_spec
    if builder is None:
        spec = spec_from_file_location('build_ipa_from_nsp', repo / 'scripts/build_ipa_from_nsp.py')
        builder = module_from_spec(spec); spec.loader.exec_module(builder)
    logs = plan['base'] / 'logs' / 'mac_rewrite'
    fresh, reason, _ = builder.rewrite_freshness(repo, plan['exefs'], plan['patched'], env, plan['game'], plan['romfs'])
    print(f'game: {plan["game"].id} ({plan["game"].get("name", "")})\nprofile: {plan["game"].dir}\nversion: {plan["version"]}\nbuild: {plan["base"]}\npatched: {plan["patched"]}\nExeFS: {plan["exefs"]}\nRomFS: {plan["romfs"]}\nshader cache root: {plan["msl"]}')
    graphics = plan.get('graphics')
    if graphics == 'nvn':
        shader_dir = plan['msl'] / f'b-{plan["chain"]}' if plan['chain'] else None
        shader_ready = bool(shader_dir and shader_dir.is_dir() and any(shader_dir.glob('*_b.metallib')) and plan['game'].table('shader_map.tsv').is_file() and nvn_stamp_matches(repo, shader_dir, plan['game']))
        shader_reason = f'NVN chain cache or profile shader map missing: {shader_dir}' if not shader_ready else 'NVN chain cache and profile shader map present'
    elif graphics in ('vulkan', 'gl'):
        api = 'vk' if graphics == 'vulkan' else 'gl' if graphics == 'gl' else None
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
    if not shader_ready: raise LaunchError(shader_reason)
    if not plan['msl'].is_dir(): raise LaunchError(f'shader cache folder does not exist: {plan["msl"]} (set --msl / DM_MSL_DIR)')
    if not fresh:
        print(f'rewrite: refreshing ({reason})')
        try:
            import lz4.block  # patch_nso.py uses this alongside capstone
            import capstone
        except ImportError as e:
            raise LaunchError(f'cannot rewrite stale modules; install the Python dependency {e.name!r} first') from e
        builder.PROG.plan(1)
        try: (rewrite_call or builder.rewrite)(Path(sys.executable), repo, plan['exefs'], plan['patched'], env, logs, plan['game'], plan['romfs'])
        except Exception as e: raise LaunchError(f'module rewrite failed: {e}') from e
        fresh, reason, _ = builder.rewrite_freshness(repo, plan['exefs'], plan['patched'], env, plan['game'], plan['romfs'])
        if not fresh: raise LaunchError(f'rewrite did not produce a complete current output: {reason}')
    game_id = plan['game'].id
    env.update(DM_GAME=game_id, DM_ROOT=str(plan['base']), DM_ROMFS=str(plan['romfs']), DM_MSL_DIR=str(plan['msl']))
    env.setdefault('DM_NVN_SHMAP', str(plan['game'].table('shader_map.tsv')))
    profile_root = plan['game'].dir.parent.resolve()
    repo_profiles = (repo / 'dm/games').resolve()
    if profile_root != repo_profiles:
        extras = [Path(p).resolve() for p in env.get('DM_GAMES_DIR', '').split(':') if p]
        extras = [profile_root] + [p for p in extras if p != profile_root]
        env['DM_GAMES_DIR'] = ':'.join(str(p) for p in extras)
        env['DM_GAMES_FIRST'] = '1'
    else:
        env.pop('DM_GAMES_FIRST', None)
    env.setdefault('DM_SAVE', str(plan['base'] / 'run' / 'save'))
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
            except (ValueError, ZeroDivisionError): raise LaunchError(f'invalid DM_ASPECT_RATIO: {env["DM_ASPECT_RATIO"]}')
    Path(env['DM_SAVE']).mkdir(parents=True, exist_ok=True)
    Path(env['DM_TEMP']).mkdir(parents=True, exist_ok=True)
    cmd = ['make', '-s', '-C', str(repo / 'dm/host'), f'GAME={game_id}', 'dmhost']
    if make_call: make_call(cmd, env)
    else: subprocess.run(cmd, env=env, check=True)
    exe = repo / 'dm/host/dmhost'
    print(f'launch: {exe} {plan["patched"]}')
    (exec_call or os.execvpe)(str(exe), [str(exe), str(plan['patched'])], env)
    return 0


def parser():
    p = argparse.ArgumentParser(description='Refresh rewritten game modules and launch the native Mac host.')
    p.add_argument('--game', help='game work folder, parent containing <ID>_build / <ID>-work, profile folder, or title ID (default: DM_GAME)')
    p.add_argument('--build', help='game build/work folder (default: DM_ROOT)')
    p.add_argument('--version', help='profile package version (default: profile package)')
    p.add_argument('--patched', help='rewritten module folder')
    p.add_argument('--exefs', help='original module folder')
    p.add_argument('--romfs', help='RomFS folder (default: DM_ROMFS or detected layout)')
    p.add_argument('--msl', help='shader cache parent (default: DM_MSL_DIR or detected layout)')
    p.add_argument('--windowed', action='store_true', help='disable fullscreen; DM_ASPECT_RATIO still sets the window size')
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
