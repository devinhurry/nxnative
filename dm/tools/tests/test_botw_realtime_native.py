"""Run the emitted real-time stubs on an Apple ARM64 host, without game assets."""
import ctypes
import importlib.util
import platform
from pathlib import Path
import struct
import sys
import types
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'dm/tools'))
from nso_asm import B


@unittest.skipUnless(sys.platform == 'darwin' and platform.machine() == 'arm64', 'Apple ARM64 execution only')
class NativeFrameStep(unittest.TestCase):
    def test_latch_and_fractional_stubs(self):
        spec = importlib.util.spec_from_file_location('botw_native_patches', ROOT / 'dm/games/01007EF00011E000/patches.py')
        patch = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(patch)
        words, sites = [], {}
        patch.frame_step(types.SimpleNamespace(here=lambda: 0x1000 + 4 * len(words), emit=words.append,
            site=lambda *_: None, put=lambda off, code, _why: sites.update({off: code}), state=0x1f00000))

        lib = ctypes.CDLL(None, use_errno=True)
        lib.mmap.restype = ctypes.c_void_p
        lib.mmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_longlong)
        size = 0x2004000
        base = lib.mmap(None, size, 7, 0x1000 | 0x02 | 0x800, -1, 0)  # anonymous private MAP_JIT
        if base in (None, ctypes.c_void_p(-1).value): self.skipTest('executable JIT memory is unavailable')
        lib.munmap.argtypes = (ctypes.c_void_p, ctypes.c_size_t)
        self.addCleanup(lib.munmap, ctypes.c_void_p(base), size)
        # Guest code writes its state while executing: replace only that page with an ordinary writable map.
        state = lib.mmap(ctypes.c_void_p(base + 0x1f00000), 0x4000, 3, 0x1000 | 0x02 | 0x10, -1, 0)
        if state != base + 0x1f00000: self.skipTest('could not allocate the temporary state page')
        protect = lib.pthread_jit_write_protect_np
        protect.argtypes = [ctypes.c_int]

        def put(off, code):
            ctypes.memmove(base + off, struct.pack('<' + 'I' * len(code), *code), len(code) * 4)

        # The wrapper preserves the host's return address and callee-saved s9.
        save_lr, save_d, load_d, load_lr, ret = 0xa9bf7bfd, 0x6dbf27e8, 0x6cc127e8, 0xa8c17bfd, 0xd65f03c0
        move_s1, move_s9, nop = 0x1e204020, 0x1e204120, 0xd503201f
        protect(0)
        put(0x1000, words)
        for i, off in enumerate((0x151d484, 0x125f128, 0x1280ee4, 0x128106c)):
            put(off, sites[off] + [ret])
            wrapper = 0x1d00000 + i * 0x100
            put(wrapper, [save_lr, save_d, B(wrapper + 8, off) | 0x80000000,
                          move_s1 if i == 0 else move_s9 if i == 3 else nop, load_d, load_lr, ret])
        setter = 0x11269b8
        put(setter, sites[setter] + [0xa8c27bfd, ret])  # undo the original entry's stack push
        lib.sys_icache_invalidate(ctypes.c_void_p(base), ctypes.c_size_t(size))
        protect(1)

        latch = ctypes.CFUNCTYPE(None)(base + setter)
        funcs = [ctypes.CFUNCTYPE(ctypes.c_float, ctypes.c_float, ctypes.c_float)(base + 0x1d00000 + i * 0x100) for i in range(4)]
        # No VFR object exists early in startup: it must still latch safely.
        ctypes.c_float.from_address(state + 0xa0).value = .6
        latch()
        self.assertAlmostEqual(ctypes.c_float.from_address(state + 0xa4).value, .6, places=6)
        # Exercise the real emitted setter with a mock VFR object. The game
        # and movies must retain their own step even if a host ratio is ready.
        protect(0)
        ctypes.c_uint64.from_address(base + 0x1e93890).value = state + 0x1000
        protect(1)
        ctypes.c_float.from_address(state).value = 60
        ctypes.c_float.from_address(state + 0xa0).value = .6
        for movie, override, expected in ((0,0,.6), (0,1,0), (1,0,0), (1,1,0), (0,0,.6)):
            ctypes.c_uint32.from_address(state + 4).value = movie
            ctypes.c_uint8.from_address(state + 0x1000 + 0x29).value = override
            latch()
            latched = ctypes.c_float.from_address(state + 0xa4).value
            with self.subTest(movie=movie, override=override):
                self.assertAlmostEqual(latched, expected, places=6)
                for i, fn in enumerate(funcs):
                    actual = fn(2.0, .8 if i == 0 else .5)
                    wanted = (2.0 if i == 3 else expected) if expected else (.8 if i == 0 else 2.0 if i == 3 else 1.0)
                    self.assertAlmostEqual(actual, wanted, places=6)
        ctypes.c_float.from_address(state).value = 0
        for ratio in (0.0, 1.0, .75, .6, .5, .25):
            ctypes.c_float.from_address(state + 0xa0).value = ratio
            ctypes.c_float.from_address(state + 0xa4).value = -1
            latch()
            self.assertAlmostEqual(ctypes.c_float.from_address(state + 0xa4).value, ratio, places=6)
            for i, fn in enumerate(funcs):
                actual = fn(2.0, .8 if i == 0 else .5)
                wanted = (2.0 if i == 3 else ratio) if ratio else (.8 if i == 0 else 2.0 if i == 3 else 1.0)
                with self.subTest(ratio=ratio, site=i): self.assertAlmostEqual(actual, wanted, places=6)

        # The game's physics ratio is s0, not the host's latch. Test the actual
        # emitted instructions at 120/60/40/30/20 fps, a shorter frame, and
        # while the fractional override is off. 0.5 corresponds to 3 substeps.
        for gate, game_ratio, wanted in ((0, .25, .25), (.25, .25, .5), (.5, .5, .5),
                                         (.75, .75, .75), (1, 1, 1), (1.5, 1.5, 1.5),
                                         (.25, .125, .5), (.25, 2, 2)):
            ctypes.c_float.from_address(state + 0xa4).value = gate
            with self.subTest(gate=gate, game_ratio=game_ratio):
                self.assertAlmostEqual(funcs[3](game_ratio, .5), wanted, places=6)


if __name__ == '__main__':
    unittest.main()
