"""Execute BOTW's rewritten physics path with Unicorn; requires game files.

Usage: python3 research_botw_physics.py <main.patched.bin>
The sibling main.fixups.tsv and main.cuts.tsv must come from the same rewrite.
This exercises the solver's step count, not real gameplay or its performance.
"""
from pathlib import Path
import re
import struct
import sys

from unicorn import UC_ARCH_ARM64, UC_MODE_ARM, Uc
from unicorn import arm64_const as arm


def bits(value):
    return struct.unpack('<I', struct.pack('<f', value))[0]


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: research_botw_physics.py <main.patched.bin>')
    path = Path(sys.argv[1])
    fixups = (path.parent / 'main.fixups.tsv').read_text()
    cuts = (path.parent / 'main.cuts.tsv').read_text()
    state_match = re.search(r'^# FPS_STATE_OFF\s+(0x[0-9a-fA-F]+)$', fixups, re.M)
    build = re.search(r'^# BUILD_ID\s+cd57b23fa4bbad65803d9788c01821ee$', fixups, re.M)
    if not state_match or not build or not re.search(r'^0x128106c\s+0940201e\s+', cuts, re.M):
        raise SystemExit('Expected a rewritten BOTW 1.9.0 main with the frame-step patch')
    base = 0x4000000
    binary = path.read_bytes()
    u = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    u.mem_map(base, (len(binary) + 0xffff) & ~0xffff)
    u.mem_write(base, binary)
    u.mem_map(0x8000000, 0x10000)
    u.mem_map(0x9000000, 0x10000)
    obj, ptr1, ptr2, solver = 0x8000000, 0x8001000, 0x8002000, 0x8003000
    u.mem_write(obj + 0x30, struct.pack('<Q', ptr1))
    u.mem_write(ptr1, struct.pack('<Q', ptr2))
    u.mem_write(ptr2 + 8, struct.pack('<Q', solver))
    state = base + int(state_match.group(1), 16)
    cases = (('120 fps', .25, .25, 3), ('60 fps', .5, .5, 3),
             ('40 fps', .75, .75, 5), ('30 fps', 1, 1, 6),
             ('20 fps', 1.5, 1.5, 9), ('game override', 0, .25, 2))
    for name, gate, ratio, expected in cases:
        u.mem_write(state + 0xa4, struct.pack('<f', gate))
        u.reg_write(arm.UC_ARM64_REG_SP, 0x900f000)
        u.reg_write(arm.UC_ARM64_REG_S0, bits(ratio))
        u.emu_start(base + 0x128106c, base + 0x1281070, count=100)
        u.reg_write(arm.UC_ARM64_REG_S1, u.reg_read(arm.UC_ARM64_REG_S9))
        u.reg_write(arm.UC_ARM64_REG_S0, bits(1 / 60))
        u.reg_write(arm.UC_ARM64_REG_S2, 0)
        u.reg_write(arm.UC_ARM64_REG_X0, obj)
        u.emu_start(base + 0x156f8e8, base + 0x156f958, count=100)
        actual = struct.unpack('<I', u.mem_read(solver + 0x3dc, 4))[0]
        print(f'{name}: {actual} substeps (expected {expected})')
        if actual != expected:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
