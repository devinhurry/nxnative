#!/usr/bin/env python3
"""Stage a profile's save preview rules and original location labels beside a build.

No game data is stored in the checkout. MSBT's LBL1/TXT2 sections follow
https://github.com/leoetlino/botw/wiki/Message-Format. SARC/Yaz0 use our asset reader.
"""
import argparse
import json
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'games'))

from botw_touch_assets import member
import game
import romfs


def messages(data):
    if data[:8] != b'MsgStdBn' or len(data) < 32 or data[12] != 1:
        raise ValueError('unsupported MSBT header')
    endian = '<' if data[8:10] == b'\xff\xfe' else '>'
    sections = {}
    at = 32
    while at + 16 <= len(data):
        size, = struct.unpack_from(endian + 'I', data, at + 4)
        if size > len(data) - at - 16: raise ValueError('invalid MSBT section')
        sections[data[at:at + 4]] = data[at + 16:at + 16 + size]
        at = (at + 16 + size + 15) & ~15
    labels, text = sections[b'LBL1'], sections[b'TXT2']
    count, = struct.unpack_from(endian + 'I', labels)
    entries, = struct.unpack_from(endian + 'I', text)
    result = {}
    if count > (len(labels) - 4) // 8 or entries > (len(text) - 4) // 4: raise ValueError('invalid MSBT table')
    for group in range(count):
        number, off = struct.unpack_from(endian + 'II', labels, 4 + group * 8)
        if number > len(labels) // 5: raise ValueError('invalid MSBT labels')
        for _ in range(number):
            length = labels[off]
            key = labels[off + 1:off + 1 + length].decode('utf-8')
            index, = struct.unpack_from(endian + 'I', labels, off + 1 + length)
            off += length + 5
            if index >= entries: raise ValueError('invalid MSBT text index')
            start, = struct.unpack_from(endian + 'I', text, 4 + index * 4)
            end = start
            while end + 2 <= len(text) and text[end:end + 2] != b'\0\0': end += 2
            value = text[start:end].decode('utf-16-le' if endian == '<' else 'utf-16-be')
            # Location names are plain strings; skip any label with format commands.
            if value and not any(ord(c) < 32 for c in value): result[key] = value
    return result


def rules_path(gid):
    return game.find_dir(gid) / 'save_preview.json'


def prepare(gid, root, output):
    rules = rules_path(gid)
    if not rules.is_file(): return
    preview = json.loads(rules.read_text())
    labels = {}
    source = romfs.Path(root)
    if (source / 'romfs/Pack').is_dir(): source = source / 'romfs'
    packs = (source / 'Pack').glob('Bootup_*.pack') if (source / 'Pack').is_dir() else ()
    for pack in packs:
        lang = pack.name[len('Bootup_'):-len('.pack')]
        if len(lang) != 4: continue
        archive = member(pack.read_bytes(), preview['location_archive'].format(lang=lang))
        labels[lang] = messages(member(archive, preview['location_member']))
    preview['labels'] = labels
    dest = Path(output) / 'save-preview.json'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(preview, ensure_ascii=True, separators=(',', ':')) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game')
    parser.add_argument('romfs')
    parser.add_argument('output')
    args = parser.parse_args()
    prepare(args.game, args.romfs, args.output)
