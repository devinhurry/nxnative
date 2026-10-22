#!/usr/bin/env python3
# Which loaded entry points does a module's code really call? For loaders that fetch functions by name and keep each pointer in a global (glad's GL loader over eglGetProcAddress,
# NVN's C proc loader over nvnDeviceGetProcAddress): the loader is a run of "name → x0 or x1 (adrp + add), call the get-proc function, adrp + ldr of a GOT slot, str x0 through it".
# Every GOT slot stored that way is named after its string; the code outside the loader then reaches a function by loading its slot (adrp + ldr of the same GOT address), so the
# slots loaded elsewhere are the functions the game calls. Digimon Story Cyber Sleuth: Complete Edition: glad asks for 2,956 GL names, the code loads 79 of them; its NVN loader
# fetches 512, the code loads 30 (docs/agents/02-survey.md).
# Usage: loader_census.py <NSO or decompressed image> [--sites name,name...]   (an NSO is decompressed in memory; a .bin is taken as is, text from 0 to the end of the first segment it
# cannot tell, so give an NSO when you can)
import struct, sys, collections

def image(path):
    d = open(path, 'rb').read()
    if d[:4] != b'NSO0': return d, len(d)
    import lz4.block
    flags = struct.unpack_from('<I', d, 0xc)[0]; segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img), segs[0][2]

def adrp(w, pc):
    if (w & 0x9f000000) != 0x90000000: return None
    imm = ((((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)) << 12
    if imm & (1 << 32): imm -= 1 << 33
    return w & 31, (pc & ~0xfff) + imm
def addimm(w): return (w & 31, (w >> 5) & 31, (w >> 10) & 0xfff) if (w & 0xffc00000) == 0x91000000 else None
def ldr64(w): return (w & 31, (w >> 5) & 31, ((w >> 10) & 0xfff) * 8) if (w & 0xffc00000) == 0xf9400000 else None
def is_call(w): return (w & 0xfc000000) == 0x94000000 or (w & 0xfffffc1f) == 0xd63f0000   # bl, blr
def is_str_x0(w, base): return (w & 0xffc003ff) == 0xf9000000 | (base << 5) and ((w >> 10) & 0xfff) == 0   # str x0, [base]

def main():
    a = sys.argv[1:]
    want = []
    if '--sites' in a: i = a.index('--sites'); want = a[i + 1].split(','); del a[i:i + 2]
    if len(a) != 1: sys.exit('usage: loader_census.py <NSO or image> [--sites name,...]')
    img, text = image(a[0])
    n = text // 4; words = struct.unpack_from(f'<{n}I', img, 0)
    def cstr(p):
        e = img.find(b'\0', p, p + 256)
        try: return img[p:e].decode('ascii') if e > p else None
        except UnicodeDecodeError: return None
    slot, loader = {}, set()
    for i in range(4, n - 3):
        if not is_call(words[i]): continue
        name = None
        for k in range(i - 4, i - 1):   # the name: adrp + add into x0 or x1 just before the call
            r = adrp(words[k], k * 4); s = addimm(words[k + 1])
            if r and s and r[0] in (0, 1) and s[1] == r[0] and s[0] == r[0]: name = cstr(r[1] + s[2])
        r = adrp(words[i + 1], (i + 1) * 4); l = ldr64(words[i + 2])
        if not (name and r and l and l[1] == r[0] and is_str_x0(words[i + 3], l[0])): continue
        slot[r[1] + l[2]] = name
        loader.update(range((i - 4) * 4, (i + 4) * 4, 4))
    refs, sites = collections.Counter(), collections.defaultdict(list)
    for i in range(n - 1):
        r = adrp(words[i], i * 4)
        if not r or i * 4 in loader: continue
        for j in range(i + 1, min(i + 6, n)):
            l = ldr64(words[j])
            if l and l[1] == r[0]:
                s = r[1] + l[2]
                if s in slot: refs[slot[s]] += 1; sites[slot[s]].append(i * 4)
                break
    fams = collections.Counter(nm[:2] if nm.startswith('gl') else nm[:3] for nm in slot.values())
    print(f'{len(slot)} slots stored by a loader ({", ".join(f"{k}* {v}" for k, v in fams.most_common(6))}); {len(refs)} loaded by other code:')
    for nm in sorted(refs): print(f'  {refs[nm]:4d}  {nm}')
    for nm in want: print(f'{nm}: ' + ' '.join(hex(x) for x in sites.get(nm, [])))

if __name__ == '__main__': main()
