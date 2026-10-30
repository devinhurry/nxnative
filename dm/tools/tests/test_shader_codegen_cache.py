import os
import pathlib
import shutil
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = pathlib.Path(__file__).resolve().parents[2] / 'gfx' / 'tools'
sys.path.insert(0, str(TOOLS))
import dmsh_codegen_cache as cache_module


def memo_helper(value):
    return {'items': [value]}


class CodeFingerprint(unittest.TestCase):
    def fingerprint(self, source, roots=('pixel',), modules=None):
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / 'sample.py'
            path.write_text(source)
            return cache_module.code_fingerprint(path, roots, modules=modules)

    def test_tracks_dependency_closure_but_not_unrelated_code_or_logs(self):
        base = '''LIMIT = 4
def helper(x): return x + LIMIT
def pixel(x): return helper(x)
def vertex(x): return x * 2
def progress(message): print(message)
'''
        fp = self.fingerprint(base)
        self.assertEqual(fp, self.fingerprint(base.replace('print(message)', 'print("progress", message)')))
        self.assertEqual(fp, self.fingerprint(base.replace('x * 2', 'x * 3')))
        self.assertNotEqual(fp, self.fingerprint(base.replace('x + LIMIT', 'x - LIMIT')))
        self.assertNotEqual(fp, self.fingerprint(base.replace('LIMIT = 4', 'LIMIT = 5')))

    def test_ignores_docstrings_comments_and_layout(self):
        a = 'VALUE=2\ndef build(x):\n    """doc"""\n    return x+VALUE\n'
        b = '# changed\nVALUE = 2\n\ndef build( x ):\n    """other"""\n    return x + VALUE\n'
        self.assertEqual(self.fingerprint(a, ('build',)), self.fingerprint(b, ('build',)))

    def test_module_source_is_included(self):
        root = 'import transform\ndef make(x): return transform.transform(x)\n'
        with tempfile.TemporaryDirectory() as d:
            src = pathlib.Path(d) / 'module.py'
            src.write_text('def transform(x): return x + 1\n')
            one = self.fingerprint(root, ('make',), {'transform': str(src)})
            src.write_text('def transform(x): return x + 2\n')
            two = self.fingerprint(root, ('make',), {'transform': str(src)})
            self.assertNotEqual(one, two)

    def test_unreferenced_module_source_is_excluded(self):
        root = 'import used, unrelated\ndef make(x): return used.transform(x)\n'
        with tempfile.TemporaryDirectory() as d:
            used = pathlib.Path(d) / 'used.py'
            unrelated = pathlib.Path(d) / 'unrelated.py'
            used.write_text('def transform(x): return x + 1\n')
            unrelated.write_text('def progress(): return 1\n')
            one = self.fingerprint(root, ('make',), {'used': str(used), 'unrelated': str(unrelated)})
            unrelated.write_text('def progress(): return 2\n')
            two = self.fingerprint(root, ('make',), {'used': str(used), 'unrelated': str(unrelated)})
            self.assertEqual(one, two)

    def test_uncovered_dynamic_global_fails_clearly(self):
        with self.assertRaisesRegex(ValueError, 'uncovered'):
            self.fingerprint('def make(x): return dynamic_value + x\n', ('make',))

    def test_unrelated_function_local_does_not_hide_unknown_global(self):
        with self.assertRaisesRegex(ValueError, 'missing_name'):
            self.fingerprint('def unrelated():\n    missing_name = 1\ndef make(): return missing_name\n', ('make',))

    def test_real_analysis_stage_roots_fingerprint_without_importing_build(self):
        tools = pathlib.Path(__file__).resolve().parents[2] / 'gfx' / 'tools'
        build = tools / 'dmsh_build.py'
        runtime = ('CODEGEN', 'XLCACHE', 'SPIRV_CROSS', 'XC', 'TARGETS', 'IOSOUT', 'MTL', 'w', 'out', 'CHAIN',
                   'GAME', 'FACTS', 'PAIRS', 'ANALYSIS_BY_KEY', 'DUAL_WANT', 'loc', 'pc_of', 'BF_WANT')
        roots = {'vs': ('analyze_vs', 'analysis_reflection', 'common_source'),
                 'ps': ('analyze_ps', 'analysis_reflection', 'common_source'),
                 'cs': ('analyze_cs', 'analysis_reflection', 'common_source'),
                 'gs': ('analyze_geometry', 'gs_slice', 'analysis_reflection', 'common_source')}
        for stage, names in roots.items():
            modules = {'dmsh_atomic': tools / 'dmsh_atomic.py', 'abi': tools / 'dmsh_abi.py'}
            if stage in ('vs', 'gs'):
                modules['dmsh_geometry'] = tools / 'dmsh_geometry.py'
            with self.subTest(stage=stage):
                self.assertRegex(cache_module.code_fingerprint(build, names, runtime=runtime, modules=modules), r'^[0-9a-f]{64}$')


class Cache(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = pathlib.Path(self.tmp.name) / 'cache'
        self.cross = pathlib.Path(self.tmp.name) / 'cross'
        self.cross.write_bytes(b'converter-v1')
        self.spv = pathlib.Path(self.tmp.name) / 'shader.spv'
        self.spv.write_bytes(b'spirv-bytes')
        self.cache = cache_module.Cache(self.root, self.cross)

    def test_convert_reuses_identical_spirv_after_move_and_records_only_success(self):
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return cache_module.subprocess.CompletedProcess(argv, 0, 'source', '')
        with mock.patch.object(cache_module.subprocess, 'run', run):
            first = self.cache.convert(self.spv, ['--msl-version', '20300'], phase='vs')
            moved = pathlib.Path(self.tmp.name) / 'moved.spv'
            shutil.copyfile(self.spv, moved)
            again = self.cache.convert(moved, ['--msl-version', '20300'], phase='vs')
        self.assertEqual(first.stdout, again.stdout)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][-1].startswith(tempfile.gettempdir()))
        self.assertEqual(self.cache.metrics()['converter']['hits'], 1)

    def test_failed_conversion_is_not_cached_and_binary_identity_changes_key(self):
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return cache_module.subprocess.CompletedProcess(argv, 1, '', 'failure')
        with mock.patch.object(cache_module.subprocess, 'run', run):
            self.cache.convert(self.spv, ['--msl-version', '20300'])
            self.cache.convert(self.spv, ['--msl-version', '20300'])
        self.assertEqual(len(calls), 2)

    def test_store_load_integrity_and_copy_isolation(self):
        payload = {'code': ['original']}
        digest = 'a' * 64
        self.cache.store(digest, payload)
        payload['code'].append('mutated')
        loaded = self.cache.load(digest)
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded, {'code': ['original']})
        assert loaded is not None
        loaded['code'].append('caller mutation')
        self.assertEqual(self.cache.load(digest), {'code': ['original']})
        path = pathlib.Path(self.cache._artifact_path(digest))
        path.write_text('{truncated')
        self.assertIsNone(self.cache.load(digest))

    def test_memo_handles_none_and_copies_results_without_hiding_errors(self):
        first = self.cache.memo('variant', memo_helper, 3)
        first['items'].append(9)
        self.assertEqual(self.cache.memo('variant', memo_helper, 3), {'items': [3]})
        self.assertEqual(self.cache.memo('tuple', lambda: (1, 2)), [1, 2])
        self.assertIsNone(self.cache.memo('none', lambda: None))
        with self.assertRaisesRegex(RuntimeError, 'visible'):
            self.cache.memo('raises', lambda: (_ for _ in ()).throw(RuntimeError('visible')))

    def test_memo_key_tracks_source_dependencies_and_declared_values(self):
        path = pathlib.Path(self.tmp.name) / 'variant.py'
        source = 'LIMIT = 2\ndef helper(x): return x + LIMIT\ndef build(x): return helper(x)\n'
        path.write_text(source)
        namespace = {}
        exec(compile(source, str(path), 'exec'), namespace)
        self.assertEqual(self.cache.memo('source', namespace['build'], 3), 5)
        changed = source.replace('LIMIT = 2', 'LIMIT = 4')
        path.write_text(changed)
        namespace = {}
        exec(compile(changed, str(path), 'exec'), namespace)
        self.assertEqual(self.cache.memo('source', namespace['build'], 3), 7)

        self.cache.memo('declared', memo_helper, 1, dependencies={'abi': {'slot': 2}})
        before = self.cache.metrics()['memo']['hits']
        self.cache.memo('declared', memo_helper, 1, dependencies={'abi': {'slot': 3}})
        self.assertEqual(self.cache.metrics()['memo']['hits'], before)

    def test_captured_closures_are_never_reused(self):
        def capture(value):
            return lambda: value
        self.assertEqual(self.cache.memo('closure', capture('first')), 'first')
        self.assertEqual(self.cache.memo('closure', capture('second')), 'second')
        self.assertEqual(self.cache.metrics()['memo']['hits'], 0)

    def test_watched_callable_fingerprint_is_computed_once_per_cache(self):
        self.cache.watch_sources([__file__])
        with mock.patch.object(cache_module, 'code_fingerprint', wraps=cache_module.code_fingerprint) as fingerprint:
            self.cache.memo('cached-fingerprint', memo_helper, 2)
            self.cache.memo('cached-fingerprint', memo_helper, 2)
        self.assertEqual(fingerprint.call_count, 1)

    def test_changed_watched_source_blocks_warm_hit(self):
        source = pathlib.Path(self.tmp.name) / 'watched.py'
        source.write_text('stable')
        self.cache.watch_sources([source])
        self.cache.memo('guard', memo_helper, 4)
        source.write_text('changed and longer')
        with self.assertRaisesRegex(RuntimeError, 'restart required'):
            self.cache.memo('guard', memo_helper, 4)

    def test_changed_watched_source_during_generation_blocks_publish(self):
        source = pathlib.Path(self.tmp.name) / 'mutator.py'
        build_source = f"def build():\n    with open({str(source)!r}, 'w') as f:\n        f.write('changed')\n    return 7\n"
        source.write_text(build_source)
        namespace = {}
        exec(compile(build_source, str(source), 'exec'), namespace)
        self.cache.watch_sources([source])
        with self.assertRaisesRegex(RuntimeError, 'restart required'):
            self.cache.memo('mutating', namespace['build'])
        artifacts = self.root / 'artifacts'
        self.assertFalse(artifacts.exists())

    def test_converter_replacement_blocks_analysis_load(self):
        digest = 'b' * 64
        self.cache.store(digest, {'result': 1})
        self.cross.write_bytes(b'converter-replaced')
        with self.assertRaisesRegex(RuntimeError, 'restart required'):
            self.cache.load(digest)

    def test_converter_symlink_repoint_keeps_captured_target(self):
        target1 = pathlib.Path(self.tmp.name) / 'cross-v1'
        target2 = pathlib.Path(self.tmp.name) / 'cross-v2'
        link = pathlib.Path(self.tmp.name) / 'cross-link'
        target1.write_bytes(b'converter-v1')
        target2.write_bytes(b'converter-v2')
        link.symlink_to(target1)
        cache = cache_module.Cache(self.root, link)
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return cache_module.subprocess.CompletedProcess(argv, 0, 'captured', '')
        with mock.patch.object(cache_module.subprocess, 'run', run):
            first = cache.convert(self.spv, ['--msl-version', '20300'])
            link.unlink()
            link.symlink_to(target2)
            second = cache.convert(self.spv, ['--msl-version', '20300'])
        self.assertEqual(len(calls), 1)
        self.assertEqual(pathlib.Path(calls[0][0]), pathlib.Path(os.path.realpath(target1)))
        self.assertEqual(first.stdout, second.stdout)

    def test_uncached_converter_symlink_repoint_keeps_captured_target(self):
        target1 = pathlib.Path(self.tmp.name) / 'cross-v1'
        target2 = pathlib.Path(self.tmp.name) / 'cross-v2'
        link = pathlib.Path(self.tmp.name) / 'cross-link'
        target1.write_bytes(b'converter-v1')
        target2.write_bytes(b'converter-v2')
        link.symlink_to(target1)
        with mock.patch.dict(os.environ, {'DMSH_CODEGEN_CACHE': '0'}):
            cache = cache_module.Cache(self.root, link)
        link.unlink()
        link.symlink_to(target2)
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return cache_module.subprocess.CompletedProcess(argv, 0, 'captured', '')
        with mock.patch.object(cache_module.subprocess, 'run', run):
            cache.convert(self.spv, ['--msl-version', '20300'])
        self.assertEqual(pathlib.Path(calls[0][0]), pathlib.Path(os.path.realpath(target1)))

    def test_source_change_during_validated_read_cannot_return_hit(self):
        source = pathlib.Path(self.tmp.name) / 'read-guard.py'
        source.write_text('stable')
        digest = 'c' * 64
        self.cache.store(digest, {'result': 1})
        self.cache.watch_sources([source])
        original_load = cache_module.json.load
        def load_then_mutate(stream):
            value = original_load(stream)
            source.write_text('changed during cache read')
            return value
        with mock.patch.object(cache_module.json, 'load', load_then_mutate):
            with self.assertRaisesRegex(RuntimeError, 'restart required'):
                self.cache.load(digest)

    def test_disable_cache_forces_converter_calls(self):
        calls = []
        def run(argv, **kw):
            calls.append(argv)
            return cache_module.subprocess.CompletedProcess(argv, 0, 'ok', '')
        with mock.patch.dict(os.environ, {'DMSH_CODEGEN_CACHE': '0'}), mock.patch.object(cache_module.subprocess, 'run', run):
            cache = cache_module.Cache(self.root, self.cross)
            cache.convert(self.spv, [])
            cache.convert(self.spv, [])
        self.assertEqual(len(calls), 2)


if __name__ == '__main__':
    unittest.main()
