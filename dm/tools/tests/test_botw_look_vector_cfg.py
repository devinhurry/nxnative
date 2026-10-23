#!/usr/bin/env python3
"""Check BOTW 1.9.0's shared stick-vector getter and OBS32 all-exit site."""
import re
import struct
import sys
from pathlib import Path

image = Path(sys.argv[1]).read_bytes()


def word(offset):
    return struct.unpack_from("<I", image, offset)[0]


def branch_target(offset):
    ins = word(offset)
    if ins & 0x7C000000 == 0x14000000:
        imm = ins & 0x3FFFFFF
        if imm & 0x2000000:
            imm -= 0x4000000
    elif ins & 0xFF000010 == 0x54000000 or ins & 0x7E000000 in (0x34000000, 0x36000000):
        imm = (ins >> 5) & 0x7FFFF
        if imm & 0x40000:
            imm -= 0x80000
        if ins & 0x7E000000 == 0x36000000:
            imm = (ins >> 5) & 0x3FFF
            if imm & 0x2000:
                imm -= 0x4000
    else:
        raise AssertionError(f"{offset:#x} is not a supported branch: {ins:08x}")
    return offset + imm * 4


def call_target(offset):
    ins = word(offset)
    assert ins & 0xFC000000 == 0x94000000, f"{offset:#x} is not BL: {ins:08x}"
    imm = ins & 0x3FFFFFF
    if imm & 0x2000000:
        imm -= 0x4000000
    return offset + imm * 4


# The getter zeros the pair, then every path reaches d5801c. The early paths return that zero;
# the success path stores the processed pair before branching to the same epilogue.
assert word(0xD57FF4) == 0xAA0003F3  # x19 retains the caller's output-pair pointer
assert word(0xD57FF8) == 0xF900001F  # initialize both output floats to zero
assert word(0xD58004) == 0xB40000C0 and branch_target(0xD58004) == 0xD5801C  # no native source
assert word(0xD58018) == 0x360000C0 and branch_target(0xD58018) == 0xD58030  # zero bit enters the normal path
assert word(0xD580EC) == 0x2D000660  # normalized native pair written to [x19]
assert word(0xD580E4) == 0x3707F9C0 and branch_target(0xD580E4) == 0xD5801C  # rejected result → common return
assert word(0xD580F0) == 0x17FFFFCB and branch_target(0xD580F0) == 0xD5801C  # successful result → common return
assert [word(o) for o in range(0xD5801C, 0xD58030, 4)] == [
    0xFD400BE8, 0xF94017F3, 0xA941FBFD, 0x9100C3FF, 0xD65F03C0
], "the shared getter epilogue changed; recheck OBS32 scratch-register liveness"

# Confirm the native consumers under test still call this exact getter. These include ordinary
# camera, camera tail, bow/aiming, and all three MagneForce update branches.
consumer_calls = {
    0xBF4F94: "CameraChase",
    0xC1D048: "CameraTail",
    0xBF0A40: "CameraAiming",
    0xBF2AF4: "CameraAiming2",
    0x5E7684: "MagneForce primary update",
    0x5E7C48: "MagneForce update branch 2",
    0x5E7D14: "MagneForce update branch 3",
}
for site, name in consumer_calls.items():
    assert call_target(site) == 0xD57FE0, f"{name} at {site:#x} no longer calls d57fe0"

patch_nso = (Path(__file__).parents[1] / "patch_nso.py").read_text()
assert re.search(r"\(0xd5801c,\s*32,\s*'fd400be8'", patch_nso), "OBS32 is not installed at the shared getter epilogue"
dm_h = (Path(__file__).parents[2] / "host" / "dm.h").read_text()
assert re.search(r"OBS_BOTW_LOOK_VECTOR\s*=\s*32", dm_h), "host observer ID does not match OBS32"
game_tsv = (Path(__file__).parents[2] / "games" / "01007EF00011E000" / "game.tsv").read_text()
profile = re.search(r"^camera_look\t([^\n]+)$", game_tsv, re.M)
assert profile, "BOTW relative look profile is missing"
parts = profile.group(1).split(":")
assert len(parts) == 5 and parts[:4] == ["cd57b23fa4bbad65803d9788c01821ee", "0xd5801c", "0x1e93890", "0x3c"], "BOTW profile is not build/VFR guarded at the shared hook"
assert float(parts[4]) > 0, "BOTW relative look gain must be positive"

print("BOTW shared vector getter: zero, invalid, and success routes converge on the OBS32 epilogue")
