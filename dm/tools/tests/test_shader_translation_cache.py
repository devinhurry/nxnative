"""Focused tests for the translator-output cache; uses a deterministic fake translator."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/gfx/tools'))


FAKE_TRANSLATOR = r'''#!/usr/bin/env python3
import hashlib, json, os, struct, sys
from pathlib import Path
jobs = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
with open(os.environ['FAKE_CALLS'], 'a') as f:
    f.write(str(len(jobs)) + '\n')
for j in jobs:
    key = j['key']
    if j.get('fail'):
        print('[RED] ' + key + ': deliberate fake failure', file=sys.stderr)
        continue
    code = Path(j['code']).read_bytes()
    if os.environ.get('FAKE_MUTATE_TOOL'):
        Path(os.environ['FAKE_MUTATE_TOOL']).write_bytes(b'changed-during-translation')
    if os.environ.get('FAKE_MUTATE_SOURCE'):
        Path(os.environ['FAKE_MUTATE_SOURCE']).write_bytes(b'mutated-during-translation')
    semantic_job = dict(j, code={'sha256': hashlib.sha256(code).hexdigest()})
    payload = hashlib.sha256(json.dumps(semantic_job, sort_keys=True).encode() + code).digest()
    # SPIR-V magic/version/generator/bound/schema, followed by deterministic payload words.
    spv = struct.pack('<5I', 0x07230203, 0x00010000, 0, 8, 0) + payload
    (out / (key + '.spv')).write_bytes(spv)
    (out / (key + '.res.json')).write_text(json.dumps({'key': key, 'stage': j['stage'], 'notes': ['fake translator'], 'reflection': {'key': key}}))
    if j.get('geometry_topology') is not None:
        (out / (key + '.reader.spv')).write_bytes(spv + b'reader')
print('translated: %d ok' % sum(not j.get('fail') for j in jobs))
if any(j.get('fail') for j in jobs): sys.exit(1)
'''


class TranslationCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.calls = self.root / 'calls'
        self.env = dict(os.environ, FAKE_CALLS=str(self.calls))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.translator = self.bin / 'fake-xlate'
        self.translator.write_text(FAKE_TRANSLATOR)
        self.translator.chmod(0o755)
        self.code = self.root / 'code.bin'
        self.code.write_bytes(b'code-v1')
        self.out = self.root / 'out'
        from dmsh_xlatecache import Cache
        self.Cache = Cache
        self.cache = self.Cache(self.root / 'cache', self.translator)

    def tearDown(self):
        self.tmp.cleanup()

    def job(self, key='shader', **fields):
        return {'key': key, 'stage': 'vs', 'code': str(self.code), 'attr': {}, 'tex': {}, **fields}

    def run_jobs(self, jobs, cache=None, out=None):
        old = os.environ.get('FAKE_CALLS')
        os.environ['FAKE_CALLS'] = str(self.calls)
        try:
            return (cache or self.cache).translate(jobs, str(out or self.out))
        finally:
            if old is None: os.environ.pop('FAKE_CALLS', None)
            else: os.environ['FAKE_CALLS'] = old

    def call_count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def outputs(self, key='shader', directory=None):
        d = Path(directory or self.out)
        names = [key + '.spv', key + '.res.json']
        if (d / (key + '.reader.spv')).exists(): names.append(key + '.reader.spv')
        return {n: (d / n).read_bytes() for n in names}

    def test_cold_warm_forced_are_byte_identical(self):
        self.run_jobs([self.job()]); cold = self.outputs()
        self.run_jobs([self.job()]); warm = self.outputs()
        self.run_jobs([self.job()], cache=self.Cache(self.root / 'cache', self.translator, enabled=False))
        forced = self.outputs()
        self.assertEqual(cold, warm)
        self.assertEqual(cold, forced)
        self.assertEqual(self.call_count(), 2)
        self.assertEqual(struct.unpack_from('<I', cold['shader.spv'])[0], 0x07230203)

    def test_identity_tracks_job_code_and_tool_dependency_but_not_source_path(self):
        self.run_jobs([self.job()]); self.run_jobs([self.job()])
        expected = self.outputs()
        renamed = self.root / 'renamed.bin'; renamed.write_bytes(self.code.read_bytes())
        self.run_jobs([dict(self.job(), code=str(renamed))])
        self.assertEqual(self.outputs(), expected)
        self.assertEqual(self.call_count(), 1)
        self.run_jobs([self.job(attr={'0': 'uint'})])
        self.code.write_bytes(b'code-v2'); self.run_jobs([self.job()])
        self.assertEqual(self.call_count(), 3)
        for dep_name in ('fake-xlate.runtime.json', 'fake-xlate.dll'):
            dep = self.bin / dep_name
            dep.write_text('v1')
            cache = self.Cache(self.root / 'cache', self.translator)
            self.run_jobs([self.job()], cache)
            dep.write_text('v2')
            cache = self.Cache(self.root / 'cache', self.translator)
            self.run_jobs([self.job()], cache)
        self.assertEqual(self.call_count(), 7)

    def test_restored_output_mutation_is_replaced_from_cache(self):
        self.run_jobs([self.job()]); expected = self.outputs()
        (self.out / 'shader.spv').write_bytes(b'tampered')
        self.run_jobs([self.job()])
        self.assertEqual(self.outputs(), expected)
        self.assertEqual(self.call_count(), 1)

    def test_invalid_spirv_header_is_rejected_even_with_matching_manifest_digest(self):
        self.run_jobs([self.job()])
        cached = next((self.root / 'cache').glob('*/*/shader.spv'))
        invalid = b'not a SPIR-V module'
        cached.write_bytes(invalid)
        manifest_path = cached.parent / 'manifest.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['files']['shader.spv'] = hashlib.sha256(invalid).hexdigest()
        manifest_path.write_text(json.dumps(manifest))
        self.run_jobs([self.job()])
        self.assertEqual(self.call_count(), 2)
        self.assertEqual(struct.unpack_from('<I', self.outputs()['shader.spv'])[0], 0x07230203)

    def test_source_bytes_are_snapshotted_before_translator_runs(self):
        old = os.environ.get('FAKE_MUTATE_SOURCE')
        os.environ['FAKE_MUTATE_SOURCE'] = str(self.code)
        try:
            self.run_jobs([self.job()])
        finally:
            if old is None: os.environ.pop('FAKE_MUTATE_SOURCE', None)
            else: os.environ['FAKE_MUTATE_SOURCE'] = old
        self.assertEqual(self.code.read_bytes(), b'mutated-during-translation')
        self.run_jobs([self.job()])
        self.assertEqual(self.call_count(), 2)

    def test_tool_replacement_after_construction_requires_fresh_cache(self):
        dependency = self.bin / 'fake-xlate.dll'
        dependency.write_bytes(b'version-1')
        stale = self.Cache(self.root / 'cache', self.translator)
        with self.translator.open('a') as f: f.write('\n# replaced after cache construction\n')
        with self.assertRaisesRegex(RuntimeError, 'changed during the build'):
            self.run_jobs([self.job()], stale)
        fresh = self.Cache(self.root / 'cache', self.translator)
        self.run_jobs([self.job()], fresh)
        self.assertEqual(self.call_count(), 1)

    def test_tool_change_during_translation_is_rejected_and_not_reused(self):
        dependency = self.bin / 'fake-xlate.dll'
        dependency.write_bytes(b'version-1')
        cache = self.Cache(self.root / 'cache', self.translator)
        old = os.environ.get('FAKE_MUTATE_TOOL')
        os.environ['FAKE_MUTATE_TOOL'] = str(dependency)
        try:
            with self.assertRaisesRegex(RuntimeError, 'changed during the build'):
                self.run_jobs([self.job()], cache)
        finally:
            if old is None: os.environ.pop('FAKE_MUTATE_TOOL', None)
            else: os.environ['FAKE_MUTATE_TOOL'] = old
        fresh = self.Cache(self.root / 'cache', self.translator)
        self.run_jobs([self.job()], fresh)
        self.assertEqual(self.call_count(), 2)

    def test_missing_output_restores_from_cache_without_translation(self):
        self.run_jobs([self.job()])
        (self.out / 'shader.spv').unlink()
        self.run_jobs([self.job()])
        self.assertEqual(self.call_count(), 1)
        self.assertEqual(struct.unpack_from('<I', self.outputs()['shader.spv'])[0], 0x07230203)

    def test_integer_attribute_and_geometry_topology_zero_have_distinct_entries(self):
        self.run_jobs([self.job('same', attr={'0': 'int'})])
        first = self.outputs('same')
        self.run_jobs([self.job('same', attr={'0': 'uint'})])
        self.assertNotEqual(first, self.outputs('same'))
        self.run_jobs([self.job('geo', geometry_topology=0)])
        self.assertTrue((self.out / 'geo.reader.spv').exists())
        self.run_jobs([self.job('geo-none', geometry_topology=None)])
        self.assertFalse((self.out / 'geo-none.reader.spv').exists())
        self.assertEqual(self.call_count(), 4)

    def test_missing_or_corrupt_cache_entry_retranslates(self):
        self.run_jobs([self.job()])
        cached = next((self.root / 'cache').glob('*/*/shader.res.json'))
        cached.unlink()
        self.run_jobs([self.job()]); self.assertEqual(self.call_count(), 2)
        cached = next((self.root / 'cache').glob('*/*/shader.spv'))
        cached.write_bytes(b'bad')
        self.run_jobs([self.job()]); self.assertEqual(self.call_count(), 3)

    def test_failed_job_is_not_cached_and_diagnostic_is_preserved(self):
        job = self.job('bad', fail=True)
        first = self.run_jobs([job]); second = self.run_jobs([job])
        self.assertNotEqual(first.returncode, 0)
        self.assertIn('deliberate fake failure', first.stderr)
        self.assertIn('deliberate fake failure', second.stderr)
        self.assertEqual(self.call_count(), 2)
        self.assertFalse((self.out / 'bad.spv').exists())

    def test_mixed_batch_does_not_cache_successful_partial_output(self):
        jobs = [self.job('good'), self.job('bad', fail=True)]
        result = self.run_jobs(jobs)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('deliberate fake failure', result.stderr)
        self.run_jobs([jobs[0]])
        self.assertEqual(self.call_count(), 2)

    def test_concurrent_identical_requests_do_not_corrupt_entry(self):
        caches = [self.Cache(self.root / 'cache', self.translator) for _ in range(4)]
        outputs = [self.root / ('out-' + str(i)) for i in range(4)]
        with concurrent.futures.ThreadPoolExecutor(4) as pool:
            results = list(pool.map(lambda pair: self.run_jobs([self.job()], pair[0], pair[1]), zip(caches, outputs)))
        self.assertTrue(all(r.returncode == 0 for r in results))
        expected = self.outputs(directory=outputs[0])
        self.assertEqual(struct.unpack_from('<I', expected['shader.spv'])[0], 0x07230203)
        self.assertTrue(all(self.outputs(directory=d) == expected for d in outputs))
        self.assertGreaterEqual(self.call_count(), 1)
        # Concurrent publishers may duplicate translation, but the shared cache entry must remain complete.
        self.run_jobs([self.job()], out=self.root / 'warm-output')
        self.assertEqual(self.outputs(directory=self.root / 'warm-output'), expected)
        self.assertTrue(json.loads(json.dumps(caches[0].metrics()))['enabled'])

    def test_non_translation_flags_are_not_part_of_key(self):
        job = self.job()
        self.run_jobs([job])
        old = {k: os.environ.get(k) for k in ('IOSOUT', 'DMSH_TARGETS')}
        try:
            os.environ['IOSOUT'] = str(self.root / 'ios-output')
            os.environ['DMSH_TARGETS'] = 'ios'
            self.run_jobs([job], out=self.root / 'other-platform')
        finally:
            for k, v in old.items():
                if v is None: os.environ.pop(k, None)
                else: os.environ[k] = v
        # Platform compile settings belong downstream and do not affect translator job identity.
        self.assertEqual(self.call_count(), 1)

    def test_builder_routes_initial_retry_and_geometry_translation_through_cache(self):
        source = (REPO / 'dm/gfx/tools/dmsh_build.py').read_text()
        self.assertIn('dmsh_xlatecache', source)
        self.assertNotRegex(source, r'subprocess\.run\(\[XLATE,')
        for phase in ('initial', 'integer-input', 'geometry'):
            self.assertIn("phase='" + phase + "'", source)
        self.assertGreaterEqual(source.count('XLCACHE.translate('), 3)


if __name__ == '__main__':
    unittest.main()
