"""Separate UI variants keep original outputs and alpha-test semantics."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import dmsh_ui

FIXTURE = '''#include <metal_stdlib>
using namespace metal;
struct main0_out
{
    float4 colour [[color(0)]];
};
fragment main0_out main0()
{
    main0_out out = {};
    out.colour = float4(.8, .1, .2, .5);
    return out;
}
'''


class UICapture(unittest.TestCase):
    def test_game_outputs_and_alpha_test_survive(self):
        source, entries = dmsh_ui.variant(FIXTURE)
        self.assertIsNotNone(source)
        self.assertEqual(entries, ['main0', 'main0_alpha'])
        self.assertIn('float4 colour [[color(0)]];', source)
        self.assertIn('float4 dm_framegen_ui [[color(7)]];', source)
        self.assertIn('discard_fragment()', source)
        self.assertIn('out.dm_framegen_ui = float4(out.colour)', source)

    def test_reserved_output_and_integer_colours_are_rejected(self):
        for source in (FIXTURE.replace('[[color(0)]]', '[[color(7)]]'),
                       FIXTURE.replace('float4 colour', 'uint4 colour')):
            self.assertIsNone(dmsh_ui.variant(source)[0])

    def test_early_returns_copy_ui_without_repeating_shader(self):
        source, _ = dmsh_ui.variant(FIXTURE.replace('return out;', 'if (out.colour.a < .1) return out;\nreturn out;'))
        self.assertEqual(source.count('out.dm_framegen_ui = '), 4)  # two returns, normal and alpha-test entries
        self.assertNotIn('main0();', source)

    def test_integer_sibling_types_do_not_duplicate(self):
        sibling = '\nstruct main0_out_u { uint4 c [[color(0)]]; };\nfragment main0_out_u main0_u() { return {}; }\n'
        source, _ = dmsh_ui.variant(FIXTURE + sibling)
        self.assertNotIn('main0_out_u', source)


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fixture':
        source, _ = dmsh_ui.variant(FIXTURE)
        Path(sys.argv[2]).write_text(source)
    else:
        unittest.main()
