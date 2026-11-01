#!/usr/bin/env python3
"""Summarize DM_FRAMEGEN_PROFILE JSONL; stage intervals include their GPU dependencies.

Agent tool: python3 dm/tools/framegen_report.py trace.jsonl --out report.json
Counters are diagnostic and split encoders; compare a separate uninstrumented run.
"""
import argparse
import collections
import json
import math
import statistics
from pathlib import Path


GPU_FIELDS = ('submit_to_gpu_ms', 'gpu_span_ms', 'gpu_pre_copy_ms',
              'ui_copy_and_dependency_ms', 'motion_ms', 'previous_depth_copy_ms',
              'metalfx_ms', 'feedback_lag_ms', 'cpu_drain_ms', 'cpu_encode_ms',
              'cpu_submit_lock_ms')
SEGMENTS = GPU_FIELDS[2:7]
CONFIG_FIELDS = ('lookup_ms', 'compiler_ms', 'interpolator_ms',
                 'motion_depth_allocation_ms', 'total_cpu_ms')


def distribution(values):
    values = sorted(x for x in values if isinstance(x, (int, float)) and math.isfinite(x))
    if not values:
        return {'count': 0}
    def percentile(p):
        index = (len(values) - 1) * p
        lo = int(index)
        return values[lo] + (values[min(lo + 1, len(values) - 1)] - values[lo]) * (index - lo)
    return {'count': len(values), 'min': values[0], 'p50': statistics.median(values),
            'p95': percentile(.95), 'max': values[-1], 'sum': sum(values)}


def metrics(rows, fields):
    return {field: distribution([row[field] for row in rows if field in row]) for field in fields}


def summarize(rows, steady_after=8):
    scene_times = [r['host_s'] for r in rows if r['event'] == 'scene_capture']
    origin = min(scene_times or [r['host_s'] for r in rows] or [0])
    steady = [r for r in rows if r['host_s'] >= origin + steady_after]
    gpu = [r for r in steady if r['event'] == 'gpu_frame']
    valid = [r for r in gpu if r.get('counters_valid')]
    config = [r for r in steady if r['event'] == 'configuration']
    waits = [r for r in steady if r['event'] == 'resize_wait']
    selected = [r for r in steady if r['event'] == 'candidate_draw' and r.get('selected')]
    camera = [r for r in steady if r['event'] == 'camera_capture']
    grouped = collections.defaultdict(list)
    for row in valid:
        grouped[(row['input_w'], row['input_h'], bool(row['history_reset']))].append(row)
    residual = [r['gpu_span_ms'] - sum(r[k] for k in SEGMENTS)
                for r in valid if all(k in r for k in SEGMENTS)]
    signatures = collections.Counter((r['w'], r['h'], r['ubo_bytes'], r['vs'], r['fs']) for r in selected)
    dimensions = collections.Counter(f"{r['w']}x{r['h']}" for r in selected)
    return {
        'scope': {'steady_after_scene_seconds': steady_after, 'origin_host_s': origin,
                  'all_events': len(rows), 'steady_events': len(steady),
                  'gpu_samples': len(gpu), 'valid_counter_samples': len(valid),
                  'invalid_counter_samples': len(gpu) - len(valid)},
        'gpu_and_cpu_intervals_ms': metrics(gpu, GPU_FIELDS),
        'gpu_span_minus_bracket_ms': distribution(residual),
        'gpu_envelope_mismatch_samples': sum(x < -.1 for x in residual),
        'gpu_by_configuration': [
            {'input_w': k[0], 'input_h': k[1], 'history_reset': k[2],
             'intervals_ms': metrics(v, GPU_FIELDS)} for k, v in sorted(grouped.items())],
        'configuration': {'events': len(config),
                          'cache_hits': sum(bool(r['cache_hit']) for r in config),
                          'new_interpolators': sum(not r['cache_hit'] for r in config),
                          'cpu_ms': metrics(config, CONFIG_FIELDS),
                          'cache_hit_cpu_ms': metrics([r for r in config if r['cache_hit']], CONFIG_FIELDS),
                          'new_interpolator_cpu_ms': metrics([r for r in config if not r['cache_hit']], CONFIG_FIELDS),
                          'process_gpu_bytes': distribution([r['process_gpu_allocated_bytes'] for r in config])},
        'resize_wait_cpu_ms': metrics(waits, ('display_drain_ms', 'generation_drain_ms')),
        'history_clear_cpu_ms': metrics([r for r in steady if r['event'] == 'history_clear'], ('cpu_ms',)),
        'selected_dimensions': dict(dimensions),
        'selected_draw_signatures': [dict(w=k[0], h=k[1], ubo_bytes=k[2], vs=k[3], fs=k[4], count=v)
                                     for k, v in signatures.most_common(20)],
        'camera_ubo_sizes': dict(collections.Counter(str(r['ubo_bytes']) for r in camera)),
        'camera_depth_aspect_mismatch': sum(r.get('finite') and 'aspect' in r and
                                           abs(r['w'] / r['h'] - r['aspect']) > .03 for r in camera),
        'scene_output_sizes': dict(collections.Counter(f"{r['w']}x{r['h']}" for r in steady
                                                       if r['event'] == 'scene_capture')),
        'notes': ['Intervals are GPU command boundaries, not isolated ALU time.',
                  'UI-copy interval includes outstanding dependencies.',
                  'CPU submit-to-GPU start is separate from GPU command-buffer span.',
                  'Configuration cache hits never imply continuous temporal history.',
                  'Use matching uninstrumented runs to assess measurement overhead.'],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('trace', type=Path)
    parser.add_argument('--steady-after', type=float, default=8)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    rows = [json.loads(line) for line in args.trace.read_text().splitlines() if line.strip()]
    result = summarize(rows, args.steady_after)
    text = json.dumps(result, indent=2) + '\n'
    if args.out:
        args.out.write_text(text)
    else:
        print(text, end='')


if __name__ == '__main__':
    main()
