#!/usr/bin/env python3
"""Combine RomFS and DLC into one DMROMFS1 image, without extracting images.

The ordinary image index exposes romfs/ and aoc/<index>/ directly. Image data is
copied once, in bounded chunks; only directory tables are rebuilt in memory.
Usage: game_image.py [--reuse] <RomFS image-or-folder> <DLC dir-or-> <out image>
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import romfs as rfs
import romfs_image as rfi


def _dlc(aoc):
    if not aoc or os.fspath(aoc) == '-': return []
    out = {}
    with os.scandir(aoc) as entries:
        for e in entries:
            if e.name == '.DS_Store' or e.name.startswith('._'): continue
            # Legacy folder packing leaves its reuse stamp beside each image.
            if e.name.lower().endswith('.img.inputs.json') and e.is_file(): continue
            name = e.name[:-4] if e.name.lower().endswith('.img') else e.name
            if not name or any(c not in '0123456789' for c in name):
                raise ValueError(f'non-numeric DLC index: {e.path}')
            index = str(int(name))
            if index in out: raise ValueError(f'duplicate DLC index {index}: {out[index]} and {e.path}')
            out[index] = e.path
    return sorted(out.items())


def _copy(src, out, size):
    while size:
        chunk = src.read(min(size, 8 << 20))
        if not chunk: raise RuntimeError('game data changed while packing: source became incomplete')
        out.write(chunk); size -= len(chunk)


class _Source:
    def __init__(self, name, path):
        self.name, self.path = name, os.fspath(path)
        before = rfi.file_identity(self.path)
        self.image = None
        self.ents = []
        self.shift = 0
        if os.path.isdir(self.path):
            self.ents = rfi.entries(self.path)
            self.signature = rfi.source_digest(self.path, self.ents)
        else:
            self.image = rfs.Image(self.path)
            self.signature = before
        if before != rfi.file_identity(self.path):
            raise RuntimeError(f'game data changed while packing: {self.path}')

    def entry(self, k):
        if self.image is not None:
            a, b, _, _, t, _ = self.image.entry(k)
            return a, b, t
        _, _, isdir, a, b = self.ents[k]
        return a, b, 0 if isdir else 1

    def children(self, k):
        a, b, _ = self.entry(k)
        return [(self.image.name(j) if self.image is not None else self.ents[j][0], self, j) for j in range(a, a + b)]

    def copy(self, out):
        if self.image is not None:
            self.shift = out.tell() - rfi.HEAD.size
            size = self.image.stat.st_size - len(self.image.index) - rfi.HEAD.size
            with open(self.path, 'rb') as src:
                src.seek(rfi.HEAD.size); _copy(src, out, size)
        else:
            for e in self.ents:
                if e[2]: continue
                with open(e[1], 'rb') as src:
                    size = os.fstat(src.fileno()).st_size
                    e[3], e[4] = out.tell(), size
                    _copy(src, out, size)


def _inputs(romfs_path, aoc):
    sources = [_Source('romfs', romfs_path), *(_Source('aoc/' + index, path) for index, path in _dlc(aoc))]
    h = hashlib.sha256()
    for path in (__file__, rfi.__file__, rfs.__file__): h.update(Path(path).read_bytes())
    if aoc and os.fspath(aoc) != '-':
        h.update(json.dumps([os.path.realpath(aoc), rfi.file_identity(aoc)]).encode())
    for src in sources:
        h.update(json.dumps([src.name, os.path.realpath(src.path), src.signature]).encode())
    return sources, h.hexdigest()


def _check_destination(dst, sources, aoc):
    targets = [dst, dst + '.part', dst + '.inputs.json', dst + '.inputs.json.part']
    roots = [src.path for src in sources]
    if aoc and os.fspath(aoc) != '-': roots.append(os.fspath(aoc))
    for target in targets:
        real = os.path.realpath(target)
        for root in roots:
            source = os.path.realpath(root)
            if real == source or (os.path.isdir(root) and os.path.commonpath([source, real]) == source):
                raise ValueError(f'game image output overlaps its source: {target}')
        if os.path.exists(target):
            for src in sources:
                paths = [src.path] if src.image is not None else (e[1] for e in src.ents)
                if any(os.path.samefile(target, path) for path in paths):
                    raise ValueError(f'game image output overlaps its source: {target}')


def _entries(sources):
    # Source-local indices remain valid; this traversal assigns new breadth-first
    # directory ranges while keeping each file's relocated data range.
    ents = [[b'', None, 0, 0, 0]]   # name, source, local entry, a, b
    i = 0
    while i < len(ents):
        _, src, k, _, _ = ents[i]
        if src is None:
            kids = ([(b'aoc', None, 1), (b'romfs', sources[0], 0)] if k == 0 else
                    [(s.name.split('/')[1].encode(), s, 0) for s in sources[1:]])
        else:
            a, b, t = src.entry(k)
            if t:
                ents[i][3:] = [a + src.shift, b]; i += 1; continue
            kids = src.children(k)
        ents[i][3:] = [len(ents), len(kids)]
        ents.extend([name, child, local, 0, 0] for name, child, local in kids)
        i += 1
    return ents


def pack(romfs, aoc, dst, reuse=False):
    """Write one image with romfs/ and aoc/ roots; return its entry count.

    aoc is a directory of numeric DLC folders or <index>.img images, or None/'-'.
    --reuse compares source names/metadata (including ctime), tool versions and
    the previous output's identity; it reads indexes, never unchanged file data.
    """
    dst = os.fspath(dst)
    sources, digest = _inputs(romfs, aoc)
    base_identity = rfi.identity(romfs) if sources[0].image is not None else None
    _check_destination(dst, sources, aoc)
    stamp, part = dst + '.inputs.json', dst + '.part'
    if reuse:
        try:
            if json.loads(Path(stamp).read_text()) == {'source': digest, 'image': rfi.file_identity(dst), 'base_identity': base_identity}:
                return 2 + sum(src.image.count if src.image is not None else len(src.ents) for src in sources)
        except (OSError, ValueError): pass
    try:
        with open(part, 'wb') as out:
            out.write(b'\0' * rfi.HEAD.size)
            for src in sources: src.copy(out)
            index_offset = out.tell()
            ents = _entries(sources)
            pool, idx = bytearray(), bytearray()
            for name, src, k, a, b in ents:
                t = src.entry(k)[2] if src is not None else 0
                idx += rfi.ENT.pack(a, b, len(pool), len(name), t, 0); pool += name
            out.write(idx); out.write(pool)
            out.seek(0); out.write(rfi.HEAD.pack(rfi.MAGIC, index_offset, len(idx) + len(pool), len(ents)))
        # Validate the rebuilt tree, including guest names from legacy folders.
        rfs.Image(part)
        if _inputs(romfs, aoc)[1] != digest:
            raise RuntimeError('game data changed while packing; run the packer again when its files are stable')
        os.replace(part, dst)
        Path(stamp + '.part').write_text(json.dumps({'source': digest, 'image': rfi.file_identity(dst), 'base_identity': base_identity}))
        os.replace(stamp + '.part', stamp)
    finally:
        for path in (part, stamp + '.part'):
            try: os.unlink(path)
            except FileNotFoundError: pass
    return len(ents)


def write_identities(image, directory, title='', version='', build=''):
    """Name the combined image and, when recorded by its packer, its original base-only image."""
    text = rfi.identity(image, title, version, build) + '\n'
    base = None
    try:
        stamp = json.loads(Path(os.fspath(image) + '.inputs.json').read_text())
        if stamp.get('image') == rfi.file_identity(image) and stamp.get('base_identity'):
            rfi.parse_identity(stamp['base_identity'])
            base = stamp['base_identity'] + '\n'
    except (OSError, ValueError, TypeError, AttributeError): pass   # no trusted packer stamp: only the physical image is accepted
    directory = Path(directory); directory.mkdir(parents=True, exist_ok=True)
    (directory / 'romfs.base.id').unlink(missing_ok=True)
    for name, content in (('romfs.id', text), ('romfs.base.id', base)):
        if content is None: continue
        part = directory / (name + '.part'); part.write_text(content); part.replace(directory / name)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == '--identities':
        if len(sys.argv) != 7: sys.exit('usage: game_image.py --identities <image> <output directory> <title> <version> <build>')
        try: write_identities(*sys.argv[2:])
        except (OSError, ValueError) as e: sys.exit(f'[RED] {e}')
        return
    ap = argparse.ArgumentParser(description='Combine RomFS and all DLC into one directly readable DMROMFS1 image')
    ap.add_argument('--reuse', action='store_true', help='keep the image while its sources, tools and output are unchanged')
    ap.add_argument('romfs'); ap.add_argument('aoc', help='DLC directory, or - without DLC'); ap.add_argument('image')
    args = ap.parse_args()
    try:
        count = pack(args.romfs, args.aoc, args.image, args.reuse)
        print(f'{args.image}: {count} entries, {os.path.getsize(args.image)} bytes')
    except (OSError, ValueError, RuntimeError, struct.error) as e:
        sys.exit(f'[RED] {e}')


if __name__ == '__main__': main()
