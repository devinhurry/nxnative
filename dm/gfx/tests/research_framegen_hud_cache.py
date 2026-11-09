"""Check a profile's cached UI shader variants without changing the cache.

A cache containing the older Mac .metal, .json and _bf.metallib files is
needed. Game shader source stays in memory, not in the temporary compiler
helper. This tests specialization, not a draw or Metal 4 pipeline.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'dm/gfx/tools'))
import dmsh_fetch
import dmsh_side


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cache', type=Path, help='Read-only b-<chain> shader cache')
    parser.add_argument('--shader-map', type=Path,
                        default=ROOT / 'dm/games/01007EF00011E000/shader_map.tsv')
    args = parser.parse_args()
    keys = []
    for line in args.shader_map.read_text().splitlines():
        cols = line.split('\t')
        if len(cols) >= 4 and cols[0] == 'ps_layout.bin' and cols[2] == 'pixel':
            keys.append(cols[3])
    if not keys or len(keys) != len(set(keys)):
        raise SystemExit('The shader map has no unique ps_layout.bin keys')
    items = []
    for key in keys:
        base = args.cache / (key + '_b')
        source = base.with_suffix('.metal').read_text()
        reflection = json.loads(base.with_suffix('.json').read_text())
        src, _ = dmsh_side.unit(source)
        folded, info = dmsh_fetch.fold(src or source, reflection['bindings'])
        if folded is None:
            raise SystemExit(f'{key}: current fold unavailable: {info}')
        outputs = [out['color'] for out in info['outputs']]
        old = reflection.get('fetch') or {}
        old_outputs = [out['color'] for out in old.get('outputs', [])]
        if 0 not in outputs or 0 not in old_outputs:
            raise SystemExit(f'{key}: cached or current variant has no color 0')
        items.append({'mode': 'current', 'key': key, 'source': folded,
                      'calls': len(info['calls']), 'outputs': outputs})
        items.append({'mode': 'cached', 'key': key,
                      'path': str(args.cache / (key + '_bf.metallib')),
                      'calls': len(old['calls']), 'outputs': old_outputs})
    print(f'profile layout shaders: {len(keys)}', flush=True)
    with tempfile.TemporaryDirectory(prefix='framegen-hud-cache-') as folder:
        helper = Path(folder) / 'probe'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                        '-framework', 'Metal', str(Path(__file__).with_suffix('.m')),
                        '-o', str(helper)], check=True)
        subprocess.run([str(helper)], input=json.dumps(items), text=True, check=True)


if __name__ == '__main__':
    main()
