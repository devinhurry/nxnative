"""Cache scheduling for shader builds, independent of the shader transforms.

The caller supplies records, jobs, analysis and materialization explicitly.
Canonical pixel analysis must exist before a paired vertex can use its cache.
"""
import collections
import concurrent.futures as cf
import hashlib
import os
import re
import subprocess
import time


BuildResult = collections.namedtuple('BuildResult', 'rows stats translate_wall finish_wall')


def pair_keyed(digest, pixel_digests):
    return hashlib.sha256((digest + '\0' + ','.join(pixel_digests)).encode()).hexdigest()


def valid_analysis(stage, payload):
    if not isinstance(payload, dict) or payload.get('stage') != stage: return False
    if payload.get('kind') == 'shader':
        flags = payload.get('candidate_flags'); fallback = payload.get('fallback'); refl = payload.get('base_refl')
        return (bool(payload.get('analysis_source')) and bool(payload.get('candidate')) and
                (fallback is None or bool(fallback)) and isinstance(refl, dict) and refl.get('stage') == stage and
                isinstance(flags, dict) and all(k in flags for k in ('layer', 'layer_from', 'discard', 'tf', 'uint', 'uint_mask', 'dual')))
    if payload.get('kind') == 'slice': return isinstance(payload.get('reflection'), dict)
    if payload.get('kind') == 'geometry':
        outputs = payload.get('outputs')
        required = {'_b', '_bg0', '_bg1', '_bg2', '_bg3', '_bg4', '_bgv'}
        return (isinstance(payload.get('analysis_source'), str) and isinstance(outputs, dict) and required <= outputs.keys() and
                all(isinstance(v, dict) and isinstance(v.get('msl'), str) and isinstance(v.get('reflection'), dict) for v in outputs.values()))
    return False


def cached_analysis(cache, stats, stage, digest, analyze=None):
    payload = cache.load(digest)
    if valid_analysis(stage, payload):
        stats['hit'] += 1
        return payload, digest, True
    if analyze is None: return None, digest, False
    payload = analyze()
    if not valid_analysis(stage, payload): raise ValueError(f'{stage} analysis produced an incomplete bundle')
    cache.store(digest, payload)
    stats['miss'] += 1
    return payload, digest, False


def paired_vertex_dependency_error(key, stage, pairs, known_keys, analysis_sources):
    if stage != 'vs': return ''
    missing = sorted(ps for ps in pairs.get(key, ()) if ps in known_keys and not analysis_sources.get(ps))
    return ('paired pixel shader analysis unavailable: ' + ', '.join(missing)) if missing else ''


def run(keys, *, pairs, known_keys, work, workers, codegen, translator,
        analysis_sources, read_record, make_job, digest_for, analyzers, materialize):
    """Return requested output rows, cache counters and wall times.

    make_job and analyzers use the builder's existing (key, work, ...) interfaces.
    Extra paired pixels are analyzed without emitting unrequested libraries.
    """
    if workers < 1: raise ValueError('shader workers must be positive')
    keys = list(keys)
    analysis_sources.clear()
    stats = collections.Counter()
    analysis_only = {ps for vertex in keys for ps in pairs.get(vertex, ()) if ps in known_keys and ps not in keys}
    analysis_keys = sorted(set(keys) | analysis_only)
    jobs, c1s, recs, digests, bundles = {}, {}, {}, {}, {}
    for key in analysis_keys:
        name, rec = recs[key] = read_record(key)
        jobs[key], c1s[key] = make_job(key, name, rec, work)
        digests[key] = digest_for(key, name, rec, jobs[key])
    for key in analysis_keys:
        if pairs.get(key): digests[key] = pair_keyed(digests[key], [digests.get(p, 'missing') for p in sorted(pairs[key])])
    misses = []
    for key in analysis_keys:
        payload, _, _ = cached_analysis(codegen, stats, jobs[key]['stage'], digests[key])
        if payload is not None:
            bundles[key] = payload
            if payload.get('analysis_source'): analysis_sources[key] = payload['analysis_source']
        else: misses.append(key)
    chunks = [misses[i::workers] for i in range(workers)]
    def translate(chunk): return translator.translate([jobs[k] for k in chunk], work, phase='initial')
    started = time.perf_counter()
    with cf.ThreadPoolExecutor(workers) as executor:
        translated = list(executor.map(translate, [chunk for chunk in chunks if chunk]))
    translate_wall = time.perf_counter() - started
    errors = {}
    for result in translated:
        for line in result.stderr.splitlines():
            match = re.match(r'\[RED\] (\w+): (.*)', line)
            if match: errors[match.group(1)] = match.group(2)[:160]

    def finish(key):
        job = jobs[key]
        dependency_error = paired_vertex_dependency_error(key, job['stage'], pairs, known_keys, analysis_sources)
        if dependency_error: return key, 'dependency failed', dependency_error, None
        if bundles.get(key) is None:
            if key in errors or not os.path.exists(os.path.join(work, key + '.spv')):
                return key, 'translation failed', errors.get(key, 'no spv'), None
            analyze = analyzers.get(job['stage'])
            if analyze is None: return key, 'analysis failed', f"unsupported stage {job['stage']}", None
            try:
                bundle, _, _ = cached_analysis(codegen, stats, job['stage'], digests[key],
                    lambda: analyze(key, work, job, c1s[key]))
            except (ValueError, subprocess.CalledProcessError) as exc:
                return key, 'analysis failed', str(exc)[:160], None
            bundles[key] = bundle
        bundle = bundles[key]
        if bundle.get('analysis_source'): analysis_sources[key] = bundle['analysis_source']
        if key in analysis_only: return key, 'analysis only', '', {}
        try: status, error, reflection = materialize(key, bundle)
        except (ValueError, subprocess.CalledProcessError) as exc:
            return key, 'analysis failed', str(exc)[:160], None
        return key, status, error, reflection

    if analysis_only:
        with cf.ThreadPoolExecutor(workers) as executor: list(executor.map(finish, sorted(analysis_only)))
    started = time.perf_counter()
    with cf.ThreadPoolExecutor(workers) as executor:
        rows = list(executor.map(finish, [key for key in keys if key not in pairs]))
        rows += list(executor.map(finish, [key for key in keys if key in pairs]))
    return BuildResult(rows, stats, translate_wall, time.perf_counter() - started)
