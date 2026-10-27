"""Reject a shader package whose records do not match the profile indices."""
import ast
import hashlib
import os
from pathlib import Path
import re
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1] / 'tools'


class ShaderPackage(unittest.TestCase):
    def test_wrong_package_is_rejected_before_translation(self):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        nodes = [n for n in tree.body if isinstance(n, ast.FunctionDef)
                 and n.name in {'records', 'record_key', 'rec_of'}]
        with tempfile.TemporaryDirectory() as folder:
            ctl = bytearray(0x880)
            code = b'original shader code'
            rec = bytearray(b'BTCDBTCD' + bytes(0x30))
            struct.pack_into('<2I', rec, 0x28, len(ctl), len(code))
            rec += code + ctl
            key = hashlib.sha256(ctl + code).hexdigest()[:16]
            (Path(folder) / 'vs_test.bin').write_bytes(rec)
            ns = dict(re=re, struct=struct, hashlib=hashlib, os=os, sys=sys,
                      dm_dir=folder, loc={key: ('vs_test.bin', 0)}, packs={})
            exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
            self.assertEqual(ns['rec_of'](key), ('vs_test.bin', rec))
            short_ctl = bytearray(ctl)
            struct.pack_into('<I', short_ctl, 0x20, 0x848)
            short_rec = rec[:0x38 + len(code)] + short_ctl
            self.assertEqual(ns['record_key'](short_rec),
                             hashlib.sha256(short_ctl[:0x848] + code).hexdigest()[:16])
            self.assertIsNone(ns['record_key'](rec[:-1]))
            wrong_key = '0' * 16
            ns['loc'][wrong_key] = ('vs_test.bin', 0)
            with self.assertRaisesRegex(SystemExit, f'holds {key}, expected {wrong_key}'):
                ns['rec_of'](wrong_key)
            ns['loc'][wrong_key] = ('vs_test.bin', 1)
            with self.assertRaisesRegex(SystemExit, 'invalid record'):
                ns['rec_of'](wrong_key)


if __name__ == '__main__':
    unittest.main()
