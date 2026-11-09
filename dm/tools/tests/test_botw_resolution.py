"""Execute BOTW's emitted resolution-budget stub, without game files."""
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

spec = importlib.util.spec_from_file_location('botw_resolution_patches',
    Path(__file__).resolve().parents[2] / 'games/01007EF00011E000/patches.py')
assert spec is not None and spec.loader is not None
patch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patch)


@unittest.skipIf(uc is None, 'optional ARM64 execution dependency: unicorn')
class Resolution(unittest.TestCase):
    def test_native_budget_and_live_inputs(self):
        assert uc is not None and arm is not None
        base, area, state = 0x4000000, 0x7000000, 0x8000000
        u = uc.Uc(uc.UC_ARCH_ARM64, uc.UC_MODE_ARM)
        for address, size in ((base, 0x2000000), (area, 0x20000), (state, 0x4000)):
            u.mem_map(address, size)
        cursor = area - base

        def emit(word):
            nonlocal cursor
            u.mem_write(base + cursor, struct.pack('<I', word))
            cursor += 4

        def put(offset, words, _why):
            u.mem_write(base + offset, struct.pack('<' + 'I' * len(words), *words))

        patch.frame_step(types.SimpleNamespace(here=lambda: cursor, emit=emit,
            site=lambda _offset, _original: None, put=put, state=state-base))
        for normalization in (0, 100, 200):
            with self.subTest(normalization=normalization):
                u.mem_write(state + 0x38, struct.pack('<f', normalization))
                u.reg_write(arm.UC_ARM64_REG_W8, 0x42c80000)  # native normalization 100
                u.reg_write(arm.UC_ARM64_REG_S0, 0x3f000000)
                u.reg_write(arm.UC_ARM64_REG_S3, 0x3f800000)
                u.reg_write(arm.UC_ARM64_REG_X20, 0x12345678)
                u.ctl_remove_cache(base + 0x12670ac, base + 0x12670b4)
                u.emu_start(base + 0x12670ac, base + 0x12670b0, count=20)
                result = struct.unpack('<f', struct.pack('<I', u.reg_read(arm.UC_ARM64_REG_S1)))[0]
                self.assertEqual(result, normalization or 100)
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_S0), 0x3f000000)
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_S3), 0x3f800000)
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_X20), 0x12345678)
                self.assertEqual(u.reg_read(arm.UC_ARM64_REG_PC), base + 0x12670b0)


if __name__ == '__main__':
    unittest.main()
