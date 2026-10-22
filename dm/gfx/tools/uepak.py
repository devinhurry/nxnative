#!/usr/bin/env python3
# Unreal Engine game files for the shader tools: pak files (version 11, UE 4.26 and later; Octopath Traveler 0 is UE5), shader code archives (.ushaderbytecode version 2) and the job files the Mac host decodes Oodle with
# (DM_OODLE_JOB, dm/host/hle_oodle.c). Octopath Traveler 0 keeps everything in one pak, Octopath_Traveler0/Content/Paks/pakchunk0-Switch.pak (1.5 GB, 159,757 files): its index is AES-256 encrypted,
# its files are stored or Oodle-compressed in blocks. Its two shader code archives are stored, but every shader inside is Oodle-compressed (Mermaid, block header 8C 0A), which no decoder in this
# repository can undo, so the game's own OodleLZ_Decompress decodes them in the Mac host (the NSP script's decode_ue_shaders, for any game with Unreal paks).
# Unreal Engine 4.27 (DRAGON QUEST VII Reimagined) keeps its packages in IoStore containers (.utoc / .ucas) and the rest in pakchunk0-Switch.pak (3,972 files, index not encrypted), among them
#   two stored shader code archives (ShaderArchive-Global-SF_GLSL_SWITCH, 1,764 shaders, and ShaderArchive-DOLL_Chunk0-SF_GLSL_SWITCH, 63,185): every shader in them is an LZ4 block, the
#   engine's default shader compression since 4.26, decoded here (lz4_shaders) without the host.
# The AES key is in main (Unreal embeds it): the 32-byte window of main's read-only or data segment that decrypts the index start to its mount point ("../../../"; Octopath Traveler 0: one window of
#   116,287 tried). It is only kept in memory, never printed or written.
# Pak footer (version 11, the last 0xdd bytes): encryption key GUID (16), encrypted index flag (u8), magic 0x5A6F12E1, version (u32), index offset (u64), index size (u64), index SHA-1 (20),
#   5 compression method names (32 bytes each).
# Index: mount point (FString), entry count (i32), path hash seed (u64), path hash index (i32 flag, then u64 offset, u64 size, SHA-1), full directory index (the same, encrypted like the index),
#   encoded entries (i32 size + bytes), the count of unencoded entries (0 here). Directory index: i32 count, then per directory its name (FString) and its files (i32 count, then name + i32 offset into
#   the encoded entries). FString: i32 length with the NUL, UTF-8; a negative length is UTF-16.
# Encoded entry: u32 bits (0-5 compression block size >> 11, 0x3f = a u32 follows; 6-21 block count; 22 encrypted; 23-28 compression method, 1-based; 29 stored size fits 32 bits; 30 raw size fits
#   32 bits; 31 offset fits 32 bits), then offset, raw size, stored size (compressed entries only) and, for several blocks or an encrypted one, each block's u32 stored size. The data starts after
#   the FPakEntry the pak repeats in front of it (53 bytes, + 4 + 16 per block when compressed); blocks follow each other, 16-aligned when encrypted.
# Older paks (version 4, UE 4.18: DRAGON QUEST XI S, pakchunk0-Switch.pak 6.6 GB / 264,844 files and pakchunk1-Switch.pak 7.2 GB / 147,824 files, the update's *_0_P.pak beside them) keep the
#   legacy layout. Footer (the last 0x2d bytes): encrypted index flag (u8), magic, version, index offset, index size, SHA-1. Index: mount point, entry count, then per file its name (relative to the
#   mount point) and its FPakEntry: offset, stored size, raw size (i64 each), compression flags (i32), SHA-1 (20), for a compressed file the block count (i32) and each block's start and end
#   (i64, from the file start before version 5, from the entry after), the encrypted flag (u8) and the compression block size (u32). The FPakEntry is repeated in front of the data.
#   The compression flags are no names: 1 zlib, 2 gzip, 4 custom; DRAGON QUEST XI S's engine uses 3, which is LZ5 2.0 (main exports LZ5_*; every block starts with its level, 0x2d = 45), and only the
#   game's own decoder reads it (hle_oodle.c, through a decode function given to Pak.read).
# Shader code archive (version 2): shader map hashes (20 bytes each), shader hashes (20 each), shader map entries {u32 first index, u32 shader count, u32 first preload, u32 preload count}, shader
#   entries {u64 offset, u32 size, u32 raw size, u8 frequency} (17 bytes, packed), preload entries (16 each), shader indices (u32): each array is a u32 count and its elements; the code follows,
#   offsets relative to its start. A shader whose size differs from its raw size is compressed.
# Usage: uepak.py list <pak> <main NSO> <out tsv>                       every file in the pak: path, raw size, stored size, compression, encrypted, blocks
#        uepak.py job <RomFS> <main NSO> <work dir>                     the shader code archives of every pak, and an Oodle job of their Oodle-compressed shaders (LZ4 ones decoded at once)
#        uepak.py finish <work dir> <out dir>                           after the host has run the job: the archives with every shader decoded
import ctypes, json, os, struct, sys

PAK_MAGIC, ARCHIVE_VERSION = 0x5A6F12E1, 2
JOB_MAGIC, OUT_MAGIC = 0x4a4f4d44, 0x524f4d44   # "DMOJ", "DMOR" (hle_oodle.c)
FREQ = {0: 'vs', 1: 'hs', 2: 'ds', 3: 'ps', 4: 'gs', 5: 'cs'}   # EShaderFrequency (the archive's frequency census: 0 vertex, 3 pixel, 5 compute)

_cc = None
def aes_decrypt(key, data):
    """AES-256 ECB decryption through CommonCrypto (every Mac has it; no Python package needed)"""
    global _cc
    if _cc is None:
        _cc = ctypes.CDLL('/usr/lib/libSystem.B.dylib').CCCrypt
        _cc.restype = ctypes.c_int32
        _cc.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
    out = ctypes.create_string_buffer(len(data)); moved = ctypes.c_size_t()
    if _cc(1, 0, 2, key, len(key), None, data, len(data), out, len(data), ctypes.byref(moved)): raise ValueError('CCCrypt failed')   # decrypt, AES, ECB
    return out.raw[:moved.value]

def nso_image(path):
    """A decompressed NSO image and its (read-only start, data end)"""
    import lz4.block
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xc)[0]; segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img), segs[1][1], segs[2][1] + segs[2][2]

class R:
    def __init__(self, b, o=0): self.b, self.o = b, o
    def take(self, fmt):
        v = struct.unpack_from(fmt, self.b, self.o); self.o += struct.calcsize(fmt); return v if len(v) > 1 else v[0]
    def raw(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def fstr(self):
        n = self.take('<i')
        if n < 0: return self.raw(-2 * n).decode('utf-16-le')[:-1]
        return self.raw(n)[:-1].decode('utf-8', 'replace') if n else ''

LEGACY = (4,)   # legacy pak versions read (the per-file index); 11 has the encoded one
LEGACY_METHODS = {1: 'Zlib', 2: 'Gzip', 3: 'LZ5', 4: 'Custom'}   # compression flags of a legacy pak (3: DRAGON QUEST XI S's engine, see the header)

def magic_back(f):
    """(how far from the end the footer's magic is, the pak version): a legacy footer is the last 0x2d bytes (magic 0x2c from the end); version 11's magic is 0xc8 from the end in
    Octopath Traveler 0 (UE5) and 0xcc in Unreal Engine 4.27 (DRAGON QUEST VII Reimagined: five whole 32-byte compression method names after the SHA-1)"""
    for back in (0x2c, 0xc8, 0xcc):
        f.seek(-back, 2); m, ver = struct.unpack('<II', f.read(8))
        if m == PAK_MAGIC: return back, ver
    raise ValueError('no pak footer')

def pak_version(f):
    return magic_back(f)[1]

def footer(f):
    """(encrypted index, index offset, index size, compression method names by number from 1, version)"""
    back, ver = magic_back(f)
    if ver in LEGACY:
        f.seek(-0x2d, 2); ft = f.read(0x2d); ioff, isz = struct.unpack_from('<QQ', ft, 9)
        return ft[0], ioff, isz, [LEGACY_METHODS.get(i, f'flags {i}') for i in range(1, 8)], ver
    if ver != 11: raise ValueError(f'pak version {ver}, only {", ".join(map(str, LEGACY))} and 11 are read')
    f.seek(-(back + 21), 2); ft = f.read(back + 21); k = 21
    ioff, isz = struct.unpack_from('<QQ', ft, k + 8)
    methods = [ft[k + 44 + 32 * i:k + 76 + 32 * i].rstrip(b'\0').decode('latin1') for i in range(5)]
    return ft[k - 1], ioff, isz, methods, ver

def find_key(img, lo, hi, pak):
    """The AES key among main's 32-byte windows (read-only and data segments, 4-aligned, at least 20 distinct bytes): the one that decrypts the index start to a short mount point"""
    with open(pak, 'rb') as f:
        _, ioff, _, _, _ = footer(f); f.seek(ioff); blk = f.read(16)
    for a in range(lo, hi - 32, 4):
        w = img[a:a + 32]
        if len(set(w)) < 20: continue
        d = aes_decrypt(w, blk)
        if 0 < struct.unpack_from('<i', d)[0] < 512 and d[4:7] == b'../': return w
    return None

class Pak:
    def __init__(self, path, key=None):
        self.path, self.key = path, key; self.f = open(path, 'rb')
        enc, ioff, isz, self.methods, self.version = footer(self.f)
        if enc and not key: raise ValueError(f'{path}: the index is encrypted and no key was given')
        r = R(self.read_at(ioff, isz, enc))
        self.mount = r.fstr(); self.count = r.take('<i')
        if self.version in LEGACY:   # one FPakEntry per file, kept as parsed
            self.files = {}
            for _ in range(self.count):
                name = r.fstr(); off, size, raw, meth = r.take('<qqqi'); r.raw(20)
                blocks = [r.take('<qq') for _ in range(r.take('<i'))] if meth else []
                e, bsz = r.take('<BI'); head = 53 + (4 + 16 * len(blocks) if meth else 0)
                if self.version < 5: blocks = [(s - off, t - s) for s, t in blocks]
                else: blocks = [(s, t - s) for s, t in blocks]
                self.files[name] = dict(off=off, raw=raw, size=size, method=self.methods[meth - 1] if meth else '', encrypted=e, block_size=bsz, blocks=blocks or [(head, size)])
            return
        r.take('<Q')
        if r.take('<i'): r.take('<QQ'); r.raw(20)   # path hash index (not needed with the full directory index)
        if not r.take('<i'): raise ValueError(f'{path}: no full directory index')
        doff, dsz = r.take('<QQ'); r.raw(20)
        self.enc = r.raw(r.take('<i'))
        if r.take('<i'): raise ValueError(f'{path}: unencoded entries are not read')
        d = R(self.read_at(doff, dsz, enc)); self.files = {}
        for _ in range(d.take('<i')):
            dn = d.fstr()
            for _ in range(d.take('<i')): fn = d.fstr(); self.files[(dn + fn).lstrip('/')] = d.take('<i')
    def read_at(self, off, n, enc):
        self.f.seek(off); b = self.f.read((n + 15) & ~15 if enc else n)
        return aes_decrypt(self.key, b)[:n] if enc else b
    def entry(self, path):
        if self.version in LEGACY: return self.files[path]
        r = R(self.enc, self.files[path]); v = r.take('<I')
        bsz = (v & 0x3f) << 11
        if v & 0x3f == 0x3f: bsz = r.take('<I')
        nblk, enc, meth = v >> 6 & 0xffff, v >> 22 & 1, v >> 23 & 0x3f
        off = r.take('<I' if v >> 31 & 1 else '<Q'); raw = r.take('<I' if v >> 30 & 1 else '<Q')
        size = r.take('<I' if v >> 29 & 1 else '<Q') if meth else raw
        cur, blocks = 53 + (4 + 16 * nblk if meth else 0), []
        if nblk == 1 and not enc: blocks = [(cur, size)]
        else:
            for _ in range(nblk): s = r.take('<I'); blocks.append((cur, s)); cur += (s + 15) & ~15 if enc else s
        return dict(off=off, raw=raw, size=size, method=self.methods[meth - 1] if meth else '', encrypted=enc, block_size=bsz, blocks=blocks)
    def read(self, path, decode=None):
        """A file's bytes. A compressed one needs decode(block bytes, raw length) → bytes, block by block (each block holds block_size raw bytes, the last one the rest):
        the game's own decoder in the Mac host (shader_split.py oodle); Octopath Traveler 0's archives go through the Oodle job instead"""
        e = self.entry(path)
        if not e['method']: return self.read_at(e['off'] + 53, e['size'], e['encrypted'])
        if not decode: raise ValueError(f'{path} is {e["method"]}-compressed in the pak')
        out, left = [], e['raw']
        for s, n in e['blocks']:
            k = min(left, e['block_size']); out.append(decode(self.read_at(e['off'] + s, n, e['encrypted']), k)); left -= k
        return b''.join(out)

def archive(b):
    """A shader code archive's tables: {'maps': [(first index, count)], 'shaders': [(offset, size, raw size, frequency)], 'indices': [...], 'code': start of the code}"""
    r = R(b)
    if r.take('<I') != ARCHIVE_VERSION: raise ValueError('not a version 2 shader code archive')
    nmap = r.take('<I'); r.raw(20 * nmap); nsh = r.take('<I'); r.raw(20 * nsh)
    maps = [r.take('<IIII')[:2] for _ in range(r.take('<I'))]
    shaders = [r.take('<QIIB') for _ in range(r.take('<I'))]
    r.raw(16 * r.take('<I'))
    n = r.take('<I'); indices = list(struct.unpack_from(f'<{n}I', b, r.o)); r.o += 4 * n
    return dict(maps=maps, shaders=shaders, indices=indices, code=r.o)

def decoded_archive(b, raws):
    """The archive with every shader replaced by its decoded bytes (raws, in entry order): the same tables, each entry's size = its raw size, the code laid out again
    (the preload entries keep their old file ranges; only the shader tools read these copies)"""
    a = archive(b); r = R(b); r.take('<I')
    for elem in (20, 20, 16): r.raw(elem * r.take('<I'))
    head, ents_at = b[:r.o + 4], r.o + 4; n = len(a['shaders']); tail_at = ents_at + 17 * n
    ents, off = bytearray(), 0
    for (_, _, raw, fr), d in zip(a['shaders'], raws):
        if len(d) != raw: raise ValueError(f'decoded shader of {len(d)} bytes, the archive says {raw}')
        ents += struct.pack('<QIIB', off, raw, raw, fr); off += raw
    return head + bytes(ents) + b[tail_at:a['code']] + b''.join(raws)

def lz4_shaders(b, a):
    """Every shader of an archive decoded as an LZ4 block (Unreal Engine 4.26 and later compress shaders with LZ4 unless the project picks another format: DRAGON QUEST VII Reimagined's
    64,949), or None when one of the compressed ones is no LZ4 block that decodes to its raw size as an LSLG record (Octopath Traveler 0's Oodle: the game's own decoder is needed)"""
    import lz4.block
    out = []
    for off, size, raw, _ in a['shaders']:
        c = b[a['code'] + off:a['code'] + off + size]
        if size == raw: out.append(c); continue
        try: d = lz4.block.decompress(c, uncompressed_size=raw)
        except Exception: return None
        if len(d) != raw or d[:4] != b'LSLG': return None
        out.append(d)
    return out

def paks(romfs):
    """Every pak under the RomFS"""
    return sorted(os.path.join(dp, f) for dp, _, fs in os.walk(romfs) for f in fs if f.endswith('.pak'))

def unreal_paks(romfs, legacy=None):
    """The paks under the RomFS that Unreal wrote (its magic in the footer; legacy None = any version, True = the legacy versions, False = the others): with version 11 the NSP script decodes
    the shader code archives (decode_ue_shaders); legacy paks keep the shaders inline in the cooked packages, which shader_split.py reads through the game's decoder (ue_legacy_jobs)"""
    out = []
    for p in paks(romfs):
        try:
            with open(p, 'rb') as f: ver = pak_version(f)
        except (OSError, ValueError, struct.error): continue   # shorter than a footer, or no Unreal pak
        if legacy is None or (ver in LEGACY) == legacy: out.append(p)
    return out

def job(romfs, main_nso, work):
    """The shader code archives of every pak under the RomFS into <work>/archives, and one Oodle job (<work>/oodle.job) of every compressed shader in them; <work>/job.json lists them"""
    os.makedirs(os.path.join(work, 'archives'), exist_ok=True)
    img, lo, hi = nso_image(main_nso); key = None; listing, recs = [], []
    for pak in unreal_paks(romfs, legacy=False):
        with open(pak, 'rb') as f: enc = footer(f)[0]
        if enc and key is None:
            key = find_key(img, lo, hi, pak)
            if key is None: raise ValueError(f'{pak}: the index is encrypted and no window of main decrypts it')
        p = Pak(pak, key)
        for path in sorted(x for x in p.files if x.endswith('.ushaderbytecode')):
            b = p.read(path); a = archive(b); name = os.path.basename(path)
            comp = [i for i, (_, size, raw, _) in enumerate(a['shaders']) if size != raw]
            raws = lz4_shaders(b, a)
            if comp and raws: b = decoded_archive(b, raws); comp, how = [], 'LZ4'   # decoded here: the Oodle job gets none of them
            else: how = 'Oodle' if comp else ''
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            for i in comp:
                off, size, raw, _ = a['shaders'][i]; recs.append((name, i, b[a['code'] + off:a['code'] + off + size], raw))
            listing.append(dict(name=name, pak=os.path.relpath(pak, romfs), path=path, shaders=len(a['shaders']), compressed=len(comp), compression=how))
    with open(os.path.join(work, 'oodle.job'), 'wb') as f:
        f.write(struct.pack('<II', JOB_MAGIC, len(recs)))
        for _, _, c, raw in recs: f.write(struct.pack('<II', len(c), raw)); f.write(c)
    json.dump(dict(archives=listing, records=[(n, i) for n, i, _, _ in recs]), open(os.path.join(work, 'job.json'), 'w'), indent=1)
    return listing, len(recs)

def finish(work, out):
    """The decoded archives into out, from <work>/oodle.job.out (the host's results, in job order)"""
    meta = json.load(open(os.path.join(work, 'job.json')))
    b = open(os.path.join(work, 'oodle.job.out'), 'rb').read() if meta['records'] else struct.pack('<II', OUT_MAGIC, 0)   # no Oodle shader: no host run
    magic, n = struct.unpack_from('<II', b)
    if magic != OUT_MAGIC or n != len(meta['records']): raise ValueError('the job output does not match the job')
    o, dec = 8, {}
    for name, i in meta['records']:
        l = struct.unpack_from('<I', b, o)[0]; o += 4
        if not l: raise ValueError(f'{name}: shader {i} was not decoded')
        dec[(name, i)] = b[o:o + l]; o += l
    os.makedirs(out, exist_ok=True)
    for x in meta['archives']:
        src = open(os.path.join(work, 'archives', x['name']), 'rb').read(); a = archive(src)
        raws = [dec.get((x['name'], i)) or src[a['code'] + off:a['code'] + off + size] for i, (off, size, _, _) in enumerate(a['shaders'])]
        tmp = os.path.join(out, x['name'] + '.partial'); open(tmp, 'wb').write(decoded_archive(src, raws)); os.replace(tmp, os.path.join(out, x['name']))
    return [x['name'] for x in meta['archives']]

def lslg(s):
    """A decoded Switch shader (LSLG): 'LSLG', a stage tag (SV vertex, SP pixel, SC compute, ...), a header with the shader's source name, then u32 code length, the code area,
    u32 control length and the control section (0x880 bytes), and a short tail (24 or 29 bytes). → (tag, control section, code area), or None if the layout differs"""
    if s[:4] != b'LSLG': return None
    k = s.find(b'\x34\x12\x76\x98')
    if k < 8: return None
    nctl, ncode = struct.unpack_from('<I', s, k - 4)[0], struct.unpack_from('<I', s, k + 0x704)[0]
    c = k - 4 - ncode
    if c < 4 or struct.unpack_from('<I', s, c - 4)[0] != ncode or k + nctl > len(s): return None
    return s[4:6].decode('latin1'), s[k:k + nctl], s[c:c + ncode]

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'list':
        img, lo, hi = nso_image(sys.argv[3])
        with open(sys.argv[2], 'rb') as f: enc = footer(f)[0]
        p = Pak(sys.argv[2], find_key(img, lo, hi, sys.argv[2]) if enc else None)
        with open(sys.argv[4], 'w') as f:
            f.write('path\traw\tstored\tmethod\tencrypted\tblocks\n')
            for path in sorted(p.files):
                e = p.entry(path); f.write(f"{path}\t{e['raw']}\t{e['size']}\t{e['method'] or 'none'}\t{e['encrypted']}\t{len(e['blocks'])}\n")
        used = sorted({p.entry(x)['method'] for x in p.files} - {''})
        print(f'pak version {p.version}, mount {p.mount}, {len(p.files)} files, compression {used}')
    elif cmd == 'job':
        listing, n = job(*sys.argv[2:5])
        for x in listing: print(f"{x['name']}: {x['shaders']} shaders, {x['compressed']} compressed")
        print(f'{n} records in {os.path.join(sys.argv[4], "oodle.job")}')
    elif cmd == 'finish':
        print('decoded:', ', '.join(finish(*sys.argv[2:4])))
    else: sys.exit(__doc__ or 'usage: uepak.py list | job | finish (see the header)')
