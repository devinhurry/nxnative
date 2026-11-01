#!/usr/bin/env python3
"""Build a stored ZIP of runtime graphics resources and its app requirements.

Compatibility series are derived from the graphics contract, independently of
the app commit or UI. Versions increase within a series; package IDs identify
the actual bytes and recorded compilers. No shader translation happens here.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[2]
SCHEMA = 1
VERSION = 1
MINIMUM_VERSION = 1
TABLES = ('shader_map.tsv', 'pso_manifest.tsv', 'c1_full.tsv', 'cb_extent.tsv',
          'shader_pairs.tsv', 'pso_pairs.tsv')
INPUT_TABLES = ('shader_map.tsv', 'pso_manifest.tsv', 'shader_pairs.tsv', 'pso_pairs.tsv',
                'shader_facts.tsv', 'bf_want.tsv', 'geo_mesh.tsv', 'dual_want.tsv', 'shader_map.tsv.conflicts.tsv')


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''): h.update(block)
    return h.hexdigest()


def atomic_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.part')
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def requirements(game, build, api, library, tables, external=True, minimum=MINIMUM_VERSION, repo=REPO):
    """Conservatively include renderer contracts, never launcher or touch UI files."""
    if not 1 <= minimum <= 1_000_000: raise ValueError('invalid minimum graphics version')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', library): raise ValueError('invalid shader library directory')
    chain = library[2:] if api == 'nvn' and library.startswith('b-') else ''
    chain_tool = repo / 'dm/gfx/tools/dmsh_chain.py'
    if api == 'nvn' and chain_tool.is_file():
        sys.path.insert(0, str(chain_tool.parent))
        import dmsh_chain
        if chain != dmsh_chain.version():
            raise ValueError('shader chain differs from current sources; rebuild the shaders and prepare the app again')
    h = hashlib.sha256()
    # A renderer change not proven ABI-neutral starts another series. Compiler
    # caches still reuse unchanged shader binaries; UI-only changes keep it.
    backend = 'vk' if api == 'vulkan' else api
    folders = ['dm/gfx/nvn', 'dm/gfx/nvn/include', 'dm/gfx/tex'] + ([f'dm/gfx/{backend}'] if backend in ('vk', 'gl') else [])
    files = sorted({p for folder in folders for p in (repo / folder).glob('*')
                    if p.is_file() and p.suffix in ('.h', '.m', '.c', '.inc', '.metal') and p.name != 'dmsh_chain.h'})
    if backend in ('vk', 'gl'):
        tools = ['dm/gfx/tools/vk_shaders.py' if backend == 'vk' else 'dm/gfx/tools/gl_shaders.py',
                 'dm/ios/tools/ios_metal.py', 'dm/gfx/tools/dmsh_chain.lock']
        if backend == 'gl': tools.append('dm/gfx/tools/mvgl.py')
        files = sorted(set(files) | {repo / name for name in tools if (repo / name).is_file()})
    for p in files:
        h.update(str(p.relative_to(repo)).encode() + b'\0' + p.read_bytes() + b'\0')
    for name in INPUT_TABLES:
        p = Path(tables) / name
        h.update(name.encode() + b'\0' + (p.read_bytes() if p.is_file() else b'missing') + b'\0')
    # The generated header covers graphics constants compiled into this host.
    sys.path.insert(0, str(repo / 'dm/games'))
    import game as game_module
    profile = game_module.load(game)
    h.update('\n'.join(line for line in game_module.header(profile).splitlines() if line.startswith('#define ')).encode())
    h.update(json.dumps([r for r in getattr(profile, 'rows', []) if r[0].startswith(('nvn_', 'shader_'))], separators=(',', ':')).encode())
    compatibility = dict(game=game.upper(), build=build, platform='ios', api=api,
                         chain=chain, library=library, contract=h.hexdigest())
    text = json.dumps(compatibility, sort_keys=True, separators=(',', ':')).encode()
    series = f'{SCHEMA}-' + hashlib.sha256(text).hexdigest()[:20]
    return dict(schema=SCHEMA, series=series, minimum_version=minimum,
                compatibility=compatibility, external=bool(external))


def restore(archive, required, cache):
    """Restore a compatible published package when local iOS build caches are gone."""
    with zipfile.ZipFile(archive) as z:
        info = z.getinfo('manifest.json')
        if info.file_size > 64 * 1024 * 1024: raise ValueError('graphics manifest is too large')
        manifest = json.loads(z.read(info))
        why = compatible(manifest, required)
        if why: raise ValueError(why)
        compilers = manifest.get('compilers')
        if not isinstance(compilers, dict) or hashlib.sha256(json.dumps(compilers, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest() != manifest.get('compiler_id'):
            raise ValueError('invalid graphics compiler identity')
        files = manifest.get('files')
        if not isinstance(files, list) or not 0 < len(files) <= 200000: raise ValueError('invalid graphics file count')
        previous = ''; names = set(); total = 0
        for e in files:
            if not isinstance(e, dict): raise ValueError('invalid graphics inventory')
            path, size, sha = e.get('path'), e.get('size'), e.get('sha256')
            if not isinstance(path, str) or not re.fullmatch(r'(msl|tables|pso)/[A-Za-z0-9_./-]+', path) or any(p in ('', '.', '..') for p in path.split('/')) or path <= previous or path.lower() in names:
                raise ValueError('invalid graphics path')
            if type(size) is not int or size < 0 or not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{64}', sha):
                raise ValueError('invalid graphics inventory')
            names.add(path.lower()); previous = path; total += size
        library = 'msl/' + required['compatibility']['library'] + '/'
        if total > 64 * 2**30 or 'tables/shader_map.tsv' not in names or not any(e['path'].startswith(library) and e['path'].endswith('.metallib') for e in files):
            raise ValueError('invalid graphics inventory')
        if not re.fullmatch(r'[0-9a-f]{64}', str(manifest.get('id', ''))) or manifest['id'] != package_id(manifest):
            raise ValueError('invalid graphics package identity')
        expected = {e['path']: e for e in files}
        entries = z.infolist()
        if len(entries) != len(files) + 1 or {e.filename for e in entries} != set(expected) | {'manifest.json'}:
            raise ValueError('graphics ZIP inventory differs from manifest')
        cache = Path(cache); cache.mkdir(parents=True, exist_ok=True)
        destination = cache / manifest['id']
        archive_stat = [str(Path(archive).resolve()), Path(archive).stat().st_size, Path(archive).stat().st_mtime_ns]
        try:
            if json.loads((destination / '.archive.json').read_text()) == archive_stat and json.loads((destination / 'manifest.json').read_text()) == manifest and all(
                    not (destination / e['path']).is_symlink() and (destination / e['path']).stat().st_size == e['size'] for e in files):
                return destination, manifest
        except (OSError, ValueError): pass
        stage = Path(tempfile.mkdtemp(prefix='.graphics-', dir=cache))
        try:
            for entry in entries:
                if entry.filename == 'manifest.json': continue
                record = expected[entry.filename]
                if entry.file_size != record['size'] or entry.compress_type != zipfile.ZIP_STORED or entry.external_attr >> 28 == 0xA:
                    raise ValueError('invalid graphics ZIP entry')
                target = stage / entry.filename; target.parent.mkdir(parents=True, exist_ok=True)
                h = hashlib.sha256()
                with z.open(entry) as source, target.open('xb') as output:
                    for block in iter(lambda: source.read(1024 * 1024), b''): output.write(block); h.update(block)
                if h.hexdigest() != record['sha256']: raise ValueError('graphics file integrity check failed')
            atomic_json(stage / 'manifest.json', manifest)
            atomic_json(stage / '.archive.json', archive_stat)
            if destination.exists(): shutil.rmtree(destination)
            stage.rename(destination)
        finally:
            if stage.exists(): shutil.rmtree(stage)
        return destination, manifest


def compatible(manifest, required):
    if not isinstance(manifest, dict): return 'unsupported graphics package format'
    if manifest.get('schema') != SCHEMA or manifest.get('kind') != 'graphics': return 'unsupported graphics package format'
    if manifest.get('series') != required['series'] or manifest.get('compatibility') != required['compatibility']:
        return 'graphics compatibility series changed'
    version = manifest.get('version')
    if type(version) is not int or version < required['minimum_version']:
        return f'graphics package version {version} is below required {required["minimum_version"]}'
    return None


def package_id(manifest):
    text = f'nxnative-graphics-v1\n{manifest["series"]}\n{manifest["version"]}\n{manifest["compiler_id"]}\n'
    text += ''.join(f'{e["path"]}\t{e["size"]}\t{e["sha256"]}\n' for e in manifest['files'])
    return hashlib.sha256(text.encode()).hexdigest()


def sources(shaders, tables, pso, library):
    out = {}
    for p in sorted(Path(shaders).iterdir()):
        if p.is_file() and (p.suffix in ('.metallib', '.json') or p.name == 'inputs.tsv'):
            out[f'msl/{library}/{p.name}'] = p
    if not any(name.endswith('.metallib') for name in out): raise ValueError('no compiled shader libraries')
    for name in TABLES:
        p = Path(tables) / name
        if p.is_file(): out['tables/' + name] = p
    if 'tables/shader_map.tsv' not in out: raise ValueError('no shader_map.tsv')
    if pso:
        for p in sorted(Path(pso).iterdir()):
            if p.is_file() and p.suffix in ('.mtl4a', '.tsv'): out['pso/' + p.name] = p
    for name, p in out.items():
        if p.is_symlink() or not re.fullmatch(r'[A-Za-z0-9_./-]+', name) or '..' in name.split('/'):
            raise ValueError(f'unsafe graphics input: {name}')
    return dict(sorted(out.items()))


def compiler_records(files):
    records = {}
    for name, p in files.items():
        if not name.startswith('msl/') or p.suffix != '.json': continue
        try: metadata = json.loads(p.read_text())
        except (ValueError, UnicodeError): continue
        if not isinstance(metadata, dict): continue
        identity, flags = metadata.get('chain_compiler'), metadata.get('chain_metal')
        if identity:
            records[str(identity)] = dict(identity=str(identity), flags=str(flags or 'unrecorded'))
    # Report what the binaries themselves record, rather than claiming that the
    # machine packaging a previously built library also compiled that library.
    versions, targets = set(), set()
    for name, p in files.items():
        if not name.startswith('msl/') or p.suffix != '.metallib': continue
        with p.open('rb') as f:
            head = f.read(256 * 1024)
            if p.stat().st_size > 256 * 1024:
                f.seek(max(256 * 1024, p.stat().st_size - 256 * 1024)); head += f.read()
        versions.update(m.decode('ascii') for m in re.findall(rb'Apple metal version [0-9.]+ \(metalfe-[0-9.]+\)', head))
        targets.update(m.decode('ascii') for m in re.findall(rb'air64(?:_v[0-9]+)?-apple-(?:ios|macosx|macos)[0-9.]+', head))
    if any('apple-macos' in t for t in targets) or any('-sdk macosx' in r['flags'] for r in records.values()):
        raise ValueError('macOS shader binaries cannot be packed as iOS graphics')
    minima = [(26, 0)]
    for target in targets:
        m = re.search(r'-ios([0-9]+)\.([0-9]+)', target)
        if m: minima.append((int(m[1]), int(m[2])))
    minimum = max(minima)
    return dict(records=[records[k] for k in sorted(records)], metal_versions=sorted(versions),
                targets=sorted(targets), minimum_os=f'{minimum[0]}.{minimum[1]}')


def archive_path(output, manifest):
    output = Path(output)
    return output.with_name(f'{output.stem}.v{manifest["version"]}{output.suffix}')


def published_packages(output, series=None):
    output = Path(output)
    if not output.parent.is_dir(): return []
    pattern = re.compile(re.escape(output.stem) + r'\.v([1-9][0-9]*)' + re.escape(output.suffix))
    found = []
    for path in output.parent.iterdir():
        match = pattern.fullmatch(path.name)
        if match and path.is_file():
            if series is not None:
                with zipfile.ZipFile(path) as archive: manifest = json.loads(archive.read('manifest.json'))
                if manifest.get('version') != int(match[1]): raise ValueError('graphics archive filename disagrees with its manifest')
                if manifest.get('series') != series: continue
            found.append((int(match[1]), path))
    return [path for _, path in sorted(found, reverse=True)]


def build(output, required, shaders, tables, pso=None, version=VERSION):
    if type(version) is not int or not 1 <= version <= 1_000_000:
        raise ValueError('graphics version must meet the app minimum')
    floor = max(version, required['minimum_version'])
    base = Path(output); base.parent.mkdir(parents=True, exist_ok=True)
    releases = published_packages(base)
    previous = published_packages(base, required['series'])
    output = previous[0] if previous else archive_path(base, dict(series=required['series'], version=floor))
    files = sources(shaders, tables, pso, required['compatibility']['library'])
    snapshot = [[name, str(p.resolve()), p.stat().st_size, p.stat().st_mtime_ns] for name, p in files.items()]
    state = dict(schema=SCHEMA, producer=digest(__file__), required=required,
                 version=floor, sources=snapshot)
    stamp = output.with_suffix(output.suffix + '.inputs.json')
    old = None
    if previous:
        with zipfile.ZipFile(output) as z: old = json.loads(z.read('manifest.json'))
        if output != archive_path(base, old): raise ValueError('graphics archive filename disagrees with its manifest')
        why = compatible(old, required)
        print(f'graphics: {"UPDATE REQUIRED: " + why if why else "previous package is compatible"}', flush=True)
        cached = json.loads(stamp.read_text()) if stamp.is_file() else {}
        if cached.get('state') == state and cached.get('archive') == [output.stat().st_size, output.stat().st_mtime_ns]:
            print(f'graphics: REUSE v{old["version"]}, series {old["series"]} ({output})', flush=True)
            return old
    else: print('graphics: NEW package (no previous package)', flush=True)
    compilers = compiler_records(files)
    entries = [dict(path=name, size=p.stat().st_size, sha256=digest(p)) for name, p in files.items()]
    if old and compatible(old, required) is None and old.get('files') == entries and old.get('compilers') == compilers and old.get('version', 0) >= floor:
        atomic_json(stamp, dict(state=state, archive=[output.stat().st_size, output.stat().st_mtime_ns]))
        print(f'graphics: REUSE v{old["version"]} (identical contents)', flush=True)
        return old
    # File versions share one sequence across series so short names never replace another release.
    latest_version = int(releases[0].stem.rsplit('.v', 1)[1]) if releases else 0
    version = max(floor, latest_version + 1)
    manifest = dict(schema=SCHEMA, kind='graphics', series=required['series'], version=version,
                    compatibility=required['compatibility'], compilers=compilers,
                    compiler_id=hashlib.sha256(json.dumps(compilers, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(), files=entries)
    manifest['id'] = package_id(manifest)
    output = archive_path(base, manifest)
    stamp = output.with_suffix(output.suffix + '.inputs.json')
    descriptor, temporary = tempfile.mkstemp(prefix=output.name + '.', suffix='.part', dir=output.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_STORED, allowZip64=True) as z:
            # The importer can validate the requirements before writing payloads.
            z.writestr('manifest.json', json.dumps(manifest, sort_keys=True, separators=(',', ':')))
            for name, p in files.items(): z.write(p, name)
        after = [[name, str(p.resolve()), p.stat().st_size, p.stat().st_mtime_ns] for name, p in files.items()]
        if after != snapshot: raise ValueError('graphics inputs changed while packaging; retry after the shader build finishes')
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    atomic_json(stamp, dict(state=state, archive=[output.stat().st_size, output.stat().st_mtime_ns]))
    print(f'graphics: READY v{version}, series {required["series"]}, {len(entries)} files, {output.stat().st_size:,} bytes ({output})', flush=True)
    return manifest


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game', required=True); p.add_argument('--build', required=True)
    p.add_argument('--api', choices=('nvn', 'vulkan', 'gl'), required=True)
    p.add_argument('--library', required=True); p.add_argument('--shaders', required=True, type=Path)
    p.add_argument('--tables', required=True, type=Path); p.add_argument('--pso', type=Path)
    p.add_argument('--requirements', type=Path)
    p.add_argument('--out', type=Path, help='base ZIP name; .v<version> is added before its extension')
    p.add_argument('--result', type=Path, help='write the actual versioned ZIP path and release metadata as JSON')
    p.add_argument('--check', type=Path, help='verify a prepared app still has current compatibility requirements')
    p.add_argument('--reuse', type=Path, help='keep a previously validated compatible graphics ZIP')
    p.add_argument('--version', type=int, default=VERSION); p.add_argument('--minimum-version', type=int, default=MINIMUM_VERSION)
    p.add_argument('--bundle', action='store_true')
    a = p.parse_args(argv)
    required = requirements(a.game, a.build, a.api, a.library, a.tables, not a.bundle, a.minimum_version)
    if a.check:
        old = json.loads(a.check.read_text())
        if any(old.get(k) != required[k] for k in ('schema', 'series', 'compatibility')) or old.get('minimum_version', 0) < required['minimum_version']:
            raise ValueError('prepared graphics requirements changed; run build_ipa_from_nsp.py --prepare-xcode again')
        print('graphics: prepared compatibility requirements are current', flush=True)
        return
    if not a.requirements: p.error('--requirements is required')
    if a.bundle and (a.reuse or a.result): p.error('--bundle cannot be combined with --reuse or --result')
    if not a.bundle:
        if a.reuse:
            with zipfile.ZipFile(a.reuse) as z: old = json.loads(z.read('manifest.json'))
            why = compatible(old, required)
            if why: raise ValueError(why)
            archive = a.reuse
            print(f'graphics: REUSE v{old["version"]}, series {old["series"]} ({a.reuse})', flush=True)
        else:
            if not a.out: p.error('--out is required for separate graphics')
            old = build(a.out, required, a.shaders, a.tables, a.pso, a.version)
            archive = archive_path(a.out, old)
        if a.result:
            atomic_json(a.result, dict(path=str(archive.resolve()), series=old['series'], version=old['version']))
    atomic_json(a.requirements, required)


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, zipfile.BadZipFile) as e: sys.exit('[RED] graphics package: ' + str(e))
