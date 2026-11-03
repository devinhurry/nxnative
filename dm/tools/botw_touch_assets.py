#!/usr/bin/env python3
"""Prepare original BOTW category glyphs beside a build, never in the checkout.

Uses the game's Bootup/Common BNTX and its BC4 alpha masks. Container fields
follow the public BNTX-Extractor format; Tegra addressing matches our
gfx/tex/nvn_deswizzle.c. No downloaded art or image-library dependency.
"""
import argparse
from pathlib import Path
import struct
import zlib

import botw_ui_audit as ui
import romfs

ICONS = {'weapon': 'Nt_PauseIconL_00^s', 'shield': 'Nt_PauseIconL_02^s',
         'food': 'Nt_PauseIconL_05^s', 'whistle': 'Ds_ShortCutHorseIcon_00^s',
         'bow': 'Nt_PauseIconL_01^s', 'arrow': 'Nt_PauseIcon_08^s'}


def member(data, wanted):
    if data[:4] == b'Yaz0': data = ui.yaz0(data)
    if data[:4] != b'SARC': raise ValueError('expected a SARC archive')
    endian = '<' if data[6:8] == b'\xff\xfe' else '>'
    head, _, total, start = struct.unpack_from(endian + 'HHII', data, 4)
    count = struct.unpack_from(endian + 'H', data, head + 6)[0]
    names = head + 12 + count * 16 + 8
    if total != len(data) or not names <= start <= total: raise ValueError('invalid SARC range')
    for i in range(count):
        _, attr, lo, hi = struct.unpack_from(endian + 'IIII', data, head + 12 + i * 16)
        if not 0 <= lo <= hi <= total - start: raise ValueError('invalid SARC member range')
        if ui.string(data, names + (attr & 0xffffff) * 4) == wanted: return data[start + lo:start + hi]
    raise ValueError(f'missing game resource: {wanted}')


def masks(data):
    if data[:8] != b'BNTX\0\0\0\0' or data[12:14] != b'\xff\xfe': raise ValueError('unsupported BNTX')
    count, table = struct.unpack_from('<Iq', data, 0x24)
    if not 0 < count <= 4096: raise ValueError('invalid BNTX texture count')
    found = {}
    for i in range(count):
        info = struct.unpack_from('<q', data, table + i * 8)[0]
        if data[info:info + 4] != b'BRTI': raise ValueError('invalid texture descriptor')
        name_at = struct.unpack_from('<q', data, info + 0x60)[0]
        length = struct.unpack_from('<H', data, name_at)[0]
        name = data[name_at + 2:name_at + 2 + length].decode()
        if name not in ICONS.values(): continue
        fmt, = struct.unpack_from('<I', data, info + 0x1c)
        width, height = struct.unpack_from('<II', data, info + 0x24)
        block_log, = struct.unpack_from('<I', data, info + 0x34)
        pointers, = struct.unpack_from('<q', data, info + 0x70)
        start, = struct.unpack_from('<q', data, pointers)
        if fmt != 0x1d01 or data[info + 0x10] != 1 or not 0 < width <= 256 or not 0 < height <= 256 or block_log > 5:
            raise ValueError(f'unsupported category mask: {name}')
        bw, bh, gob_height = (width + 3) // 4, (height + 3) // 4, 1 << block_log
        alpha = bytearray(width * height)
        for by in range(bh):
            for bx in range(bw):
                x = bx * 8
                # A GOB is 64 bytes by eight rows; blocks contain 2^tileH GOBs.
                at = start + by // (8 * gob_height) * ((bw * 8 + 63) // 64) * 512 * gob_height
                at += x // 64 * 512 * gob_height + by % (8 * gob_height) // 8 * 512
                at += x % 64 // 32 * 256 + by % 8 // 2 * 64 + x % 32 // 16 * 32 + by % 2 * 16 + x % 16
                a, b = struct.unpack_from('BB', data, at)
                values = [a, b] + ([( (7 - j) * a + j * b) // 7 for j in range(1, 7)] if a > b else
                                   [((5 - j) * a + j * b) // 5 for j in range(1, 5)] + [0, 255])
                selectors = int.from_bytes(data[at + 2:at + 8], 'little')
                for py in range(4):
                    for px in range(4):
                        if bx * 4 + px < width and by * 4 + py < height:
                            alpha[(by * 4 + py) * width + bx * 4 + px] = values[(selectors >> ((py * 4 + px) * 3)) & 7]
        found[name] = width, height, alpha
    if found.keys() != set(ICONS.values()): raise ValueError('missing BOTW category glyphs')
    return found


def png(width, height, alpha):
    def chunk(tag, data): return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data))
    rows = b''.join(b'\0' + b''.join(bytes((226, 222, 211, a * 4 // 5)) for a in alpha[y * width:(y + 1) * width]) for y in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def prepare(root, output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    source = romfs.Path(root) / 'Pack/Bootup.pack'
    # Include source identity in the stamp: another version must be extracted.
    stat = source.stat()
    stamp = f'{Path(__file__).stat().st_mtime_ns}:{root}:{stat.st_size}:{stat.st_mtime_ns}\n'
    marker = output / 'touch-icons.stamp'
    if marker.exists() and marker.read_text() == stamp and all((output / f'touch_{key}.png').is_file() for key in ICONS): return
    common = member(source.read_bytes(), 'Layout/Common.sblarc')
    textures = masks(member(common, 'timg/__Combined.bntx'))
    for key, name in ICONS.items(): (output / f'touch_{key}.png').write_bytes(png(*textures[name]))
    marker.write_text(stamp)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('romfs'); parser.add_argument('output')
    args = parser.parse_args()
    prepare(args.romfs, args.output)
