import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('framegen_report', Path(__file__).parents[1] / 'framegen_report.py')
assert spec is not None and spec.loader is not None
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class FramegenReportTests(unittest.TestCase):
    def test_distribution_and_invalid_values(self):
        d = report.distribution([1, 2, 3, 4, float('nan')])
        self.assertEqual(d['count'], 4)
        self.assertEqual(d['p50'], 2.5)
        self.assertAlmostEqual(d['p95'], 3.85)

    def test_measurement_scope_excludes_warmup_and_keeps_invalid_count(self):
        rows = [{'event': 'scene_capture', 'host_s': 10, 'w': 1920, 'h': 1080},
                {'event': 'gpu_frame', 'host_s': 11, 'counters_valid': False},
                {'event': 'gpu_frame', 'host_s': 20, 'counters_valid': False, 'gpu_span_ms': 7}]
        result = report.summarize(rows)
        self.assertEqual(result['scope']['gpu_samples'], 1)
        self.assertEqual(result['scope']['invalid_counter_samples'], 1)
        self.assertEqual(result['gpu_and_cpu_intervals_ms']['gpu_span_ms']['p50'], 7)

    def test_cache_hit_is_reported_separately_from_history(self):
        row = {'event': 'configuration', 'host_s': 1, 'cache_hit': True,
               'process_gpu_allocated_bytes': 100}
        result = report.summarize([row], 0)
        self.assertEqual(result['configuration']['cache_hits'], 1)
        self.assertEqual(result['configuration']['new_interpolators'], 0)
        self.assertEqual(result['scope']['valid_counter_samples'], 0)

    def test_cache_hits_and_new_allocations_have_separate_costs(self):
        rows = [{'event': 'configuration', 'host_s': 1, 'cache_hit': hit,
                 'motion_depth_allocation_ms': cost, 'process_gpu_allocated_bytes': 100}
                for hit, cost in [(True, 1), (True, 3), (False, 20)]]
        c = report.summarize(rows, 0)['configuration']
        self.assertEqual(c['cache_hit_cpu_ms']['motion_depth_allocation_ms']['p50'], 2)
        self.assertEqual(c['new_interpolator_cpu_ms']['motion_depth_allocation_ms']['p50'], 20)


if __name__ == '__main__':
    unittest.main()
