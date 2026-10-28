#!/usr/bin/env python3
"""Pack deterministic, uncompressed .nxrom data for the iOS importer.

NXROM001 + u64 little-endian JSON length + JSON directory/file table + file bytes.
The IPA carries the SHA-256 of the entire package, not the (potentially huge) table.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))
import romfs as rfs

MAGIC = b'NXROM001'
MAX_INDEX = 64 << 20


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True).encode('utf-8')


def inventory(romfs, aoc=None):
    directories, files, sources, stamps = [], [], [], []
    for mount, root in [('romfs', rfs.Path(romfs))] + ([('aoc', Path(aoc))] if aoc else []):
        if not root.is_dir() or root.is_symlink():
            raise ValueError(f'not a regular directory: {root}')
        def walk(folder, name):
            directories.append(name)
            for child in sorted(folder.iterdir()):
                s = child.stat(follow_symlinks=False)
                path = name + '/' + child.name
                if '\\' in path or any(ord(c) < 32 for c in path):
                    raise ValueError(f'unsupported game-data path: {child}')
                if stat.S_ISDIR(s.st_mode):
                    walk(child, path)
                elif stat.S_ISREG(s.st_mode):
                    files.append({'path': path, 'size': s.st_size})
                    sources.append(child)
                    stamps.append((str(child.resolve()), s.st_size, s.st_mtime_ns, s.st_ctime_ns))
                else:
                    raise ValueError(f'game data must contain only regular files/directories: {child}')
        walk(root, mount)
    return {'directories': directories, 'files': files}, sources, stamps


def pack(out, romfs, aoc, title_id, version, marker, metadata, stamp=None):
    out, metadata = Path(out), Path(metadata)
    if not (rfs.Path(romfs) / marker).exists():
        raise ValueError(f'RomFS marker missing: {marker}')
    for root in [Path(romfs)] + ([Path(aoc)] if aoc else []):
        if out.resolve().is_relative_to(root.resolve()):
            raise ValueError('the .nxrom output must be outside the game-data sources')
    table, sources, stamps = inventory(romfs, aoc)
    index = json_bytes(table)
    if len(index) > MAX_INDEX:
        raise ValueError('game-data index exceeds 64 MiB')
    key = hashlib.sha256(json_bytes([table, stamps, hashlib.sha256(Path(__file__).read_bytes()).hexdigest()])).hexdigest()
    identity = dict(format=1, title_id=title_id, version=version, marker=marker)
    if stamp and Path(stamp).exists() and out.is_file():
        saved = json.loads(Path(stamp).read_bytes())
        s = out.stat()
        if saved['key'] == key and saved['output'] == [s.st_size, s.st_mtime_ns, s.st_ctime_ns]:
            descriptor = dict(saved['descriptor'], **identity)
            metadata.write_bytes(json_bytes(descriptor))
            print(f'game data reused: {out}', flush=True)
            return descriptor
    size = 16 + len(index) + sum(f['size'] for f in table['files'])
    out.parent.mkdir(parents=True, exist_ok=True)
    part = out.with_name(out.name + '.partial')
    part.unlink(missing_ok=True)
    if shutil.disk_usage(out.parent).free < size + (512 << 20):
        raise ValueError(f'not enough space to write {out}: need {size + (512 << 20):,} bytes free')
    digest = hashlib.sha256()
    print(f'game data: {len(sources):,} files, {size:,} bytes → {out}', flush=True)
    try:
        with part.open('wb') as target:
            def write(data):
                target.write(data)
                digest.update(data)
            write(MAGIC + struct.pack('<Q', len(index)))
            write(index)
            for source, entry, before in zip(sources, table['files'], stamps):
                count = 0
                with source.open('rb') as handle:
                    while data := handle.read(1 << 20):
                        write(data)
                        count += len(data)
                s = source.stat()
                if count != entry['size'] or list(before[1:]) != [s.st_size, s.st_mtime_ns, s.st_ctime_ns]:
                    raise ValueError(f'game data changed while packing: {source}')
            target.flush()
            os.fsync(target.fileno())
        # A source tree changing during packing must never acquire a successful stamp.
        after_table, _, after_stamps = inventory(romfs, aoc)
        if (after_table, after_stamps) != (table, stamps):
            raise ValueError('game-data sources changed while packing')
        os.replace(part, out)
    finally:
        part.unlink(missing_ok=True)
    descriptor = dict(identity, sha256=digest.hexdigest(), size=size)
    metadata.write_bytes(json_bytes(descriptor))
    if stamp:
        s = out.stat()
        Path(stamp).write_bytes(json_bytes(dict(key=key, output=[s.st_size, s.st_mtime_ns, s.st_ctime_ns], descriptor=descriptor)))
    return descriptor


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('out')
    for name in ('romfs', 'title-id', 'version', 'marker', 'metadata', 'stamp'):
        ap.add_argument('--' + name, required=True)
    ap.add_argument('--aoc')
    a = ap.parse_args()
    pack(a.out, a.romfs, a.aoc, a.title_id, a.version, a.marker, a.metadata, a.stamp)


if __name__ == '__main__':
    main()
