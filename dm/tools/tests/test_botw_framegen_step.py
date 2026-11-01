"""Execute optional fractional BOTW timing stubs; no game assets required."""
import importlib
import importlib.util
from pathlib import Path
import struct
import sys
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    uc = importlib.import_module('unicorn')
    arm = importlib.import_module('unicorn.arm64_const')
except ImportError:
    uc = arm = None

spec = importlib.util.spec_from_file_location('botw_framegen_patches',
    Path(__file__).resolve().parents[2] / 'games/01007EF00011E000/patches.py')
assert spec is not None and spec.loader is not None
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


@unittest.skipIf(uc is None, 'optional ARM64 execution dependency: unicorn')
class FrameStep(unittest.TestCase):
    def setUp(self):
        assert uc is not None and arm is not None
        self.base, self.state, self.stack = 0x4000000, 0x8000000, 0x9008000
        self.u = u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        for address, size in ((self.base, 0x2000000), (0x7000000, 0x20000),
                              (self.state, 0x4000), (0x9000000, 0x10000)):
            u.mem_map(address, size)
        cursor = 0x7000000 - self.base

        def emit(word):
            nonlocal cursor
            u.mem_write(self.base + cursor, struct.pack('<I', word)); cursor += 4

        def put(offset, words, _why):
            u.mem_write(self.base + offset, struct.pack('<' + 'I' * len(words), *words))

        patch.frame_step(types.SimpleNamespace(here=lambda: cursor, emit=emit,
            site=lambda _offset, _original: None, put=put, state=self.state-self.base))

    def test_fractional_and_disabled_paths_preserve_registers(self):
        assert arm is not None
        for ratio in (0, 1, .75, .6, .5, .25):
            for offset, output, original in ((0x151d484, arm.UC_ARM64_REG_S1, .8),
                                             (0x125f128, arm.UC_ARM64_REG_S0, 1),
                                             (0x1280ee4, arm.UC_ARM64_REG_S0, 1),
                                             (0x128106c, arm.UC_ARM64_REG_S9, 2)):
                with self.subTest(ratio=ratio, offset=hex(offset)):
                    u = self.u
                    u.mem_write(self.state+0x44, struct.pack('<f', ratio))
                    for register, value in ((arm.UC_ARM64_REG_S0, 2), (arm.UC_ARM64_REG_S1, .8 if offset==0x151d484 else .5)):
                        u.reg_write(register, struct.unpack('<I', struct.pack('<f', value))[0])
                    u.reg_write(arm.UC_ARM64_REG_X9, 0x123456789abcdef)
                    u.reg_write(arm.UC_ARM64_REG_X10, 0xfedcba987654321)
                    u.reg_write(arm.UC_ARM64_REG_SP, self.stack)
                    u.emu_start(self.base+offset, self.base+offset+4, count=30)
                    result = struct.unpack('<f', struct.pack('<I', u.reg_read(output)))[0]
                    self.assertAlmostEqual(result, (1 if offset==0x128106c else ratio) if ratio else original, places=6)
                    self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X9), 0x123456789abcdef)
                    self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X10), 0xfedcba987654321)
                    self.assertEqual(u.reg_read(arm.UC_ARM64_REG_SP), self.stack)

    def test_framework_latches_once_for_both_vfr_calls(self):
        assert arm is not None
        u = self.u
        u.mem_write(self.state+0x40, struct.pack('<f', .6))
        u.reg_write(arm.UC_ARM64_REG_SP, self.stack)
        u.emu_start(self.base+0x11269b8, self.base+0x11269bc, count=40)
        self.assertAlmostEqual(struct.unpack('<f', u.mem_read(self.state+0x44, 4))[0], .6, places=6)
        u.mem_write(self.state+0x40, struct.pack('<f', .75))
        u.emu_start(self.base+0x151d484, self.base+0x151d488, count=30)
        self.assertAlmostEqual(struct.unpack('<f', struct.pack('<I', u.reg_read(arm.UC_ARM64_REG_S1)))[0], .6, places=6)


if __name__ == '__main__':
    unittest.main()
