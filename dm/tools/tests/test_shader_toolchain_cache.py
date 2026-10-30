"""Compiler isolation and target-selection behavior for the shader builder."""
import ast
import concurrent.futures
import collections
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import tempfile
import types
from typing import Any
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / 'dm/gfx/tools'
sys.path.insert(0, str(TOOLS))
import dmsh_mtlcache  # noqa: E402

spec = importlib.util.spec_from_file_location('nsp_toolchain_cache', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec and spec.loader
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class TargetSelection(unittest.TestCase):
    def test_mesh_compiles_only_requested_targets(self):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        functions: list[ast.stmt] = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name in {'active_targets', 'mesh_finish'}]
        with tempfile.TemporaryDirectory() as td:
            root = Path(td); ios = root / 'ios'; ios.mkdir()
            (root / 'vertex_b.metal').write_text('vertex source')
            (root / 'geometry_bl3.metal').write_text('geometry source')
            (root / 'geometry_bl3.json').write_text(json.dumps({'geometry': {'capture_reads': [36]}}))
            (ios / 'vertex_b.metal').write_text('vertex source')
            (ios / 'geometry_bl3.metal').write_text('geometry source')
            (ios / 'geometry_bl3.json').write_text(json.dumps({'geometry': {'capture_reads': [36]}}))
            for targets in ({'mac'}, {'ios'}, {'mac', 'ios'}):
                with self.subTest(targets=targets):
                    compile_target = mock.Mock()
                    compose = mock.Mock(return_value='mesh source')
                    ns: dict[str, Any] = dict(os=os, json=json, subprocess=subprocess, out=td, w=td, TARGETS=targets,
                              IOSOUT=str(ios) if 'ios' in targets else None, MESH_STATS=collections.Counter(),
                              MTL=types.SimpleNamespace(compile=compile_target), dmsh_mesh=types.SimpleNamespace(compose=compose),
                              memo_variant=lambda label, module, *args: module.compose(*args))
                    def compile_candidates(target, candidates, lib, compiler=compile_target):
                        compiler(target, candidates[0], lib)
                        return 0
                    ns['MTL'].compile_candidates = compile_candidates
                    exec(compile(ast.Module(body=functions, type_ignores=[]), '<mesh targets>', 'exec'), ns)
                    ns['mesh_finish'](('vertex', 'geometry'))
                    self.assertEqual(compose.call_args_list, [mock.call('vertex source', 'geometry source', [36]) for _ in targets])
                    self.assertEqual([call.args[0] for call in compile_target.call_args_list], [t for t in ('mac', 'ios') if t in targets])
                    self.assertEqual(ns['MESH_STATS']['built'], 1)

    @staticmethod
    def selection(env):
        tree = ast.parse((TOOLS / 'dmsh_build.py').read_text())
        start = next(i for i, n in enumerate(tree.body) if isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'IOSOUT' for t in n.targets))
        end = next(i for i, n in enumerate(tree.body) if i > start and isinstance(n, ast.If) and isinstance(n.test, ast.Name) and n.test.id == 'IOSOUT')
        ns = dict(os=os, sys=sys)
        with mock.patch.dict(os.environ, env, clear=True):
            exec(compile(ast.Module(body=tree.body[start:end], type_ignores=[]), '<target selection>', 'exec'), ns)
        return ns['TARGETS'], ns['IOSOUT']

    def test_defaults_and_explicit_targets(self):
        for env, targets, ios in (({}, {'mac'}, None), ({'IOSOUT': 'phone'}, {'mac', 'ios'}, 'phone'),
                                  ({'DMSH_TARGETS': 'mac', 'IOSOUT': 'phone'}, {'mac'}, None),
                                  ({'DMSH_TARGETS': 'ios', 'IOSOUT': 'phone'}, {'ios'}, 'phone')):
            with self.subTest(env=env): self.assertEqual(self.selection(env), (targets, ios))

    def test_invalid_targets(self):
        for env in ({'DMSH_TARGETS': 'ios'}, {'DMSH_TARGETS': 'other'}, {'DMSH_TARGETS': ', '}):
            with self.subTest(env=env), self.assertRaises(SystemExit): self.selection(env)


class StageCache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def key(self, env, version='tested Metal', sdk='SDK build'):
        def run(cmd, **kwargs):
            text = version if 'metal' in cmd else sdk if '--show-sdk-build-version' in cmd else 'unchanged tool'
            return subprocess.CompletedProcess(cmd, 0, text, '')
        with mock.patch.object(nsp.subprocess, 'run', side_effect=run), mock.patch.dict(os.environ, env, clear=True):
            return nsp.fingerprint(*nsp.toolchain(REPO), env=env)

    def test_selected_converter_content_invalidates_reuse(self):
        converter = self.root / 'spirv-cross'; converter.write_bytes(b'converter A'); converter.chmod(0o755)
        env = dict(os.environ, SPIRV_CROSS=str(converter))
        before = self.key(env)
        converter.write_bytes(b'converter B')
        self.assertNotEqual(before, self.key(env))

    def test_actual_metal_or_sdk_change_invalidates_reuse(self):
        env = dict(os.environ)
        before = self.key(env)
        self.assertNotEqual(before, self.key(env, version='override Metal'))
        self.assertNotEqual(before, self.key(env, sdk='different SDK build'))


class MetalPrefill(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.old = self.root / 'b-old'; self.old.mkdir()
        def compile_current(msl, air, lib): Path(lib).write_bytes(b'TESTED ' + Path(msl).read_bytes())
        with mock.patch.object(dmsh_mtlcache, 'compiler_id', return_value='tested compiler and SDK'):
            self.cache = dmsh_mtlcache.Cache(str(self.root / 'cas'), {'mac': ('macosx', 'flags', compile_current)}, str(self.root))

    def earlier_libraries(self, third_identity):
        for i in range(3):
            stem = f'{i:016x}_b'; src = f'MSL {i}'.encode()
            (self.old / (stem + '.metal')).write_bytes(src)
            (self.old / ('._' + stem + '.metal')).write_bytes(b'\0\x05\x16\x07' + b'\xa0' * 4092)   # an exFAT drive's AppleDouble: no shader of its own
            (self.old / (stem + '.metallib')).write_bytes(b'TESTED ' + src if i < 2 else b'WRONG OVERRIDE LIBRARY')
            meta = {'chain_metal': 'flags', 'stage': 'ps', 'chain_compiler': self.cache.ident['mac'].hex()}
            if i == 2:
                if third_identity is None: meta.pop('chain_compiler')
                else: meta['chain_compiler'] = third_identity
            (self.old / (stem + '.json')).write_text(json.dumps(meta))

    def test_every_prefilled_library_requires_matching_compiler_identity(self):
        for identity in (None, 'other compiler'):
            with self.subTest(identity=identity):
                if (self.root / 'cas').exists(): shutil.rmtree(self.root / 'cas')
                self.earlier_libraries(identity)
                self.cache.fill(str(self.old))
                result = self.root / 'result.metallib'
                self.cache.compile('mac', str(self.old / f'{2:016x}_b.metal'), str(result))
                self.assertEqual(result.read_bytes(), b'TESTED MSL 2')

    def test_matching_compiler_libraries_still_prefill(self):
        self.earlier_libraries(self.cache.ident['mac'].hex())
        (self.old / f'{2:016x}_b.metallib').write_bytes(b'TESTED MSL 2')
        self.cache.fill(str(self.old))
        self.assertEqual(self.cache.stats['mac', 'filled'], 3)

    def test_unrequested_target_is_not_sample_compiled(self):
        self.earlier_libraries(self.cache.ident['mac'].hex())
        with mock.patch.object(self.cache, '_compile') as compile_sample:
            self.cache.fill(str(self.old), targets={'ios'})
        compile_sample.assert_not_called()
        self.assertEqual(self.cache.stats['mac', 'filled'], 0)

    def test_legacy_cache_entries_cannot_restore_misclassified_libraries(self):
        src = b'MSL'; msl = self.root / 'shader.metal'; msl.write_bytes(src)
        old_ident = hashlib.sha256(b'dmsh_mtlcache 1\0flags\0tested compiler and SDK').digest()
        digest = hashlib.sha256(old_ident + b'\0' + src).hexdigest()
        old_path = self.root / 'cas/mac' / digest[:2] / (digest + '.metallib')
        old_path.parent.mkdir(parents=True); old_path.write_bytes(b'WRONG OVERRIDE LIBRARY')
        result = self.root / 'result.metallib'; self.cache.compile('mac', str(msl), str(result))
        self.assertEqual(result.read_bytes(), b'TESTED MSL')


class CandidateSelection(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name); self.work = self.root / 'work'; self.work.mkdir()
        self.calls = []
        def compile_target(target):
            def compile_msl(msl, air, lib):
                source = Path(msl).read_bytes(); self.calls.append((target, source))
                if target=='mac' and b'optional-entry' in source: raise subprocess.CalledProcessError(1, ['metal'], '', 'optional entry rejected')
                Path(lib).write_bytes(target.encode() + b'\0' + source)
            return compile_msl
        self.compilers = {'mac': compile_target('mac'), 'ios': compile_target('ios')}
        self.compiler_versions = {'macosx':'compiler-A','iphoneos':'compiler-A'}
        self.cache = self.make_cache()

    def make_cache(self):
        targets={'mac':('macosx','mac flags',self.compilers['mac']), 'ios':('iphoneos','ios flags',self.compilers['ios'])}
        with mock.patch.object(dmsh_mtlcache,'compiler_id',side_effect=lambda sdk:self.compiler_versions[sdk]):
            return dmsh_mtlcache.Cache(str(self.root/'cas'),targets,str(self.work))

    def source(self,name,data):
        p=self.root/name; p.write_bytes(data); return p

    def test_fallback_choice_is_saved_and_warm_run_does_not_retry_rejected_candidate(self):
        candidate=self.source('candidate.metal',b'optional-entry full source')
        fallback=self.source('fallback.metal',b'plain source')
        first=self.root/'first.metallib'; second=self.root/'second.metallib'
        self.assertEqual(self.cache.compile_candidates('mac',[candidate,fallback],str(first)),1)
        self.assertEqual(self.cache.compile_candidates('mac',[candidate,fallback],str(second)),1)
        self.assertEqual(first.read_bytes(),second.read_bytes())
        self.assertEqual(self.calls,[('mac',b'optional-entry full source'),('mac',b'plain source')])
        self.assertEqual(self.cache.stats['mac','candidate selected'],1)
        self.assertEqual(self.cache.stats['mac','candidate reused'],1)

    def test_target_compiler_candidate_bytes_and_order_have_separate_selection(self):
        candidate=self.source('candidate.metal',b'optional-entry source')
        fallback=self.source('fallback.metal',b'plain source')
        self.assertEqual(self.cache.compile_candidates('ios',[candidate,fallback],str(self.root/'ios.metallib')),0)
        changed=self.source('candidate-edited.metal',b'plain alternate source')
        self.assertEqual(self.cache.compile_candidates('mac',[changed,fallback],str(self.root/'mac-edited.metallib')),0)
        self.assertEqual(self.cache.compile_candidates('mac',[fallback,changed],str(self.root/'mac-reordered.metallib')),0)
        self.compiler_versions['macosx']='compiler-B'
        new_compiler=self.make_cache()
        self.assertEqual(new_compiler.compile_candidates('mac',[candidate,fallback],str(self.root/'mac-new-compiler.metallib')),1)

    def test_all_failed_candidates_are_not_remembered(self):
        a=self.source('a.metal',b'optional-entry A'); b=self.source('b.metal',b'optional-entry B')
        for n in range(2):
            with self.assertRaises(subprocess.CalledProcessError):
                self.cache.compile_candidates('mac',[a,b],str(self.root/f'failed-{n}.metallib'))
        self.assertEqual(self.calls.count(('mac',b'optional-entry A')),2)
        self.assertEqual(self.calls.count(('mac',b'optional-entry B')),2)
        self.assertEqual(self.cache.stats['mac','candidate failed'],2)

    def test_concurrent_duplicate_source_builds_share_one_compiled_result(self):
        calls=[]
        def compile_once(target,msl,lib):
            calls.append(Path(msl).read_bytes())
            time.sleep(0.05)
            Path(lib).write_bytes(b'compiler output '+str(len(calls)).encode())
        with mock.patch.object(self.cache,'_compile',side_effect=compile_once):
            paths=[self.root/'parallel-a.metallib',self.root/'parallel-b.metallib']
            source=self.source('parallel.metal',b'same source')
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                list(pool.map(lambda lib:self.cache.compile('mac',str(source),str(lib)),paths))
        self.assertEqual(calls,[b'same source'])
        self.assertEqual(paths[0].read_bytes(),paths[1].read_bytes())
        self.assertEqual(self.cache.stats['mac','compiled'],1)
        self.assertEqual(self.cache.stats['mac','reused'],1)

    def test_source_basename_is_canonicalized_for_compiler_and_cache_key(self):
        calls=[]
        def compile_name(msl,air,lib):
            calls.append(Path(msl).name)
            Path(lib).write_bytes(Path(msl).name.encode())
        first=self.source('first.metal',b'same bytes'); second=self.source('second.metal',b'same bytes')
        sdk,record,_=self.cache.targets['mac']; self.cache.targets['mac']=(sdk,record,compile_name)
        a=self.root/'first.metallib'; b=self.root/'second.metallib'
        self.cache.compile('mac',str(first),str(a)); self.cache.compile('mac',str(second),str(b))
        self.assertEqual(calls,['shader.metal'])
        self.assertEqual(a.read_bytes(),b'shader.metal'); self.assertEqual(b.read_bytes(),b'shader.metal')

    def test_prefill_uses_each_targets_own_msl_and_refuses_unverifiable_ios_legacy(self):
        mac=self.root/'old-mac'; ios=self.root/'old-ios'; mac.mkdir(); ios.mkdir(); stem='a'*16+'_b'
        mac_source=b'mac full candidate'; ios_source=b'ios plain fallback'
        (mac/(stem+'.metal')).write_bytes(mac_source); (ios/(stem+'.metal')).write_bytes(ios_source)
        (mac/(stem+'.metallib')).write_bytes(b'mac\0'+mac_source); (ios/(stem+'.metallib')).write_bytes(b'ios\0'+ios_source)
        for target,d in (('mac',mac),('ios',ios)):
            record={'stage':'ps','chain_metal':self.cache.targets[target][1], 'chain_compiler':self.cache.ident[target].hex()}
            (d/(stem+'.json')).write_text(json.dumps(record))
        notes=self.cache.fill(str(mac),str(ios))
        self.assertFalse(any('not filled' in n for n in notes))
        self.assertTrue(Path(self.cache.path('mac',mac_source)).is_file())
        self.assertTrue(Path(self.cache.path('ios',ios_source)).is_file())
        self.assertFalse(Path(self.cache.path('ios',mac_source)).exists())

        legacy=self.root/'legacy-ios'; legacy.mkdir()
        (legacy/(stem+'.metallib')).write_bytes(b'ios\0'+ios_source)
        (legacy/(stem+'.json')).write_text(json.dumps({'stage':'ps','chain_metal':self.cache.targets['ios'][1],
            'chain_compiler':self.cache.ident['ios'].hex()}))
        other_mac=self.root/'legacy-mac'; shutil.copytree(mac,other_mac,dirs_exist_ok=True)
        notes=self.cache.fill(str(other_mac),str(legacy))
        self.assertTrue(any('no verifiable ios MSL source' in n for n in notes))


if __name__ == '__main__':
    unittest.main()
