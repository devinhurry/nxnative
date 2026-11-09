"""Run the existing output-mapping variant against two Metal targets on macOS.

This is a narrow research probe, not a game or full frame-generation test.
It compiles in a temporary directory and does not change shader caches.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import dmsh_fetch

SRC = '''#include <metal_stdlib>
using namespace metal;
struct main0_out
{
    float4 m_46 [[color(0)]];
};
fragment main0_out main0(device atomic_uint *count [[buffer(0)]])
{
    main0_out out = {};
    atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    out.m_46 = float4(1.0, 0.5, 0.25, 0.25);
    return out;
}
'''
VERTEX = '''\nvertex float4 vert(uint id [[vertex_id]]) {
    float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return float4(p[id],0,1);
}\n'''


def main():
    shader, meta = dmsh_fetch.fold(SRC, [], om_only_ok=True)
    if shader is None:
        raise SystemExit(f'Cannot create output-mapping fixture: {meta}')
    with tempfile.TemporaryDirectory(prefix='framegen-hud-probe-') as folder:
        folder = Path(folder)
        source = folder / 'shader.metal'
        source.write_text(shader + VERTEX)
        program = folder / 'probe'
        native = Path(__file__).with_suffix('.m')
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        '-framework', 'Metal', str(native), '-o', str(program)], check=True)
        subprocess.run([str(program), str(source)], check=True)


if __name__ == '__main__':
    main()
