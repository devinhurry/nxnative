#!/usr/bin/env python3
"""Check BOTW 1.9.0's mode-0 and mode-1 pitch gate routes in main.orig.bin."""
import struct
import sys
from pathlib import Path
import re

image = open(sys.argv[1], "rb").read()


def word(offset):
    return struct.unpack_from("<I", image, offset)[0]


def branch_target(offset):
    ins = word(offset)
    if ins & 0x7C000000 == 0x14000000:
        imm = ins & 0x3FFFFFF
        if imm & 0x2000000:
            imm -= 0x4000000
    else:
        assert ins & 0xFF000010 == 0x54000000, f"{offset:#x} is not a branch: {ins:08x}"
        imm = (ins >> 5) & 0x7FFFF
        if imm & 0x40000:
            imm -= 0x80000
    return offset + imm * 4


assert word(0xBF0B8C) == 0x540002A1, f"unexpected mode selector: {word(0xBF0B8C):08x}"
assert branch_target(0xBF0B8C) == 0xBF0BE0  # mode 0 bypasses the mode-1 block
assert word(0xBF0BD8) == 0xBD022E60  # mode-1 result store receives OBS31
assert word(0xBF0BDC) == 0x1400001C and branch_target(0xBF0BDC) == 0xBF0C4C
assert word(0xBF0C38) == 0xBD423661  # mode 0 receives OBS26
assert word(0xBF0C48) == 0x1E204109  # mode 0 falls through to the shared native clamp
assert word(0xBF0C58) == 0x1E212000  # shared native clamp follows both routes
rewriter = (Path(__file__).parents[1] / "patch_nso.py").read_text()
assert re.search(r"\(0xbf0bd8,\s*31,\s*'bd022e60'", rewriter), "OBS31 mode-1 pitch gate is missing"
print("BOTW CameraAiming mode-0 and mode-1 pitch routes reach their gates before native clamp/smoothing")
