#!/usr/bin/env python3
"""List candidate performance changes from the fixed source snapshot.

This is a review aid, not a proof of semantic completeness.  Merge commits are
compared with each parent so their conflict resolutions cannot hide in --cc.
"""
import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path

BASE = '028a26319eae744d9c1ad90406624ae384a4c857'
SOURCE = '88e2a60562a5e6e7359ed93aa1a8b845e8ba7c18'
PATTERN = re.compile(
    r'(?i)fps|frame.?rate|frame.?gen|frame.?pacing|'
    r'performance|speed.?up|latency|thermal|upscal|render.?scale|'
    r'resolution|pipeline.{0,16}cache|file.backed|transcod|'
    r'bc.?texture|render.?pass|attachment.{0,8}store|snapshot|'
    r'\b(?:cpu|gpu|shader|texture|memory|buffer|upload|residency|pool|cache)\b|'
    r'DM_(?:FPS|FRAME|LOW_MEMORY|GUEST_FILE|PSO|THERMAL|RENDER_SCALE|'
    r'PRESENT_UPSCALE|DYNAMIC_RESOLUTION|NVN_(?:FB|PASS|UNWRITTEN|TBDR|BC|DRV))')


def run(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], check=True,
                          stdout=subprocess.PIPE, text=True, errors='replace').stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--output', type=Path, help='TSV file; default is stdout')
    args = parser.parse_args()
    commits = run(args.repo, 'log', '--format=%H%x00%P%x00%s', f'{BASE}..{SOURCE}').splitlines()
    rows = []
    for row in commits:
        sha, parents_text, subject = row.split('\0', 2)
        parents = parents_text.split()
        touched, paths, hits = set(), set(), []
        for parent in parents:
            diff = run(args.repo, 'diff', '--no-ext-diff', '--no-renames', '--unified=0', parent, sha, '--')
            path = ''
            for line in diff.splitlines():
                if line.startswith('diff --git '):
                    path = line.split(' b/', 1)[-1]
                    touched.add(path)
                elif line.startswith('+++ b/'):
                    path = line[6:]
                elif line.startswith(('+', '-')) and not line.startswith(('+++', '---')):
                    if path.startswith(('docs/', 'dm/tools/tests/', 'dm/gfx/tests/', 'dm/ios/tests/', 'dm/mac/tests/')) or path.endswith('.md'):
                        continue
                    if PATTERN.search(line):
                        paths.add(path)
                        snippet = line[:180].replace('\t', ' ')
                        if len(hits) < 4 and snippet not in hits:
                            hits.append(snippet)
        rows.append((sha, len(parents), subject, ', '.join(sorted(touched)),
                     'yes' if PATTERN.search(subject) or paths else '',
                     ', '.join(sorted(paths)), ' | '.join(hits)))
    def write(out):
        w = csv.writer(out, delimiter='\t', lineterminator='\n')
        w.writerow(('source', 'parent count', 'subject', 'changed paths',
                    'keyword candidate', 'matching paths', 'sample matching changed lines'))
        w.writerows(rows)
    if args.output:
        with args.output.open('w', encoding='utf-8', newline='') as out:
            write(out)
    else:
        write(sys.stdout)
    print(f'{len(rows)} commits, {sum(r[1] > 1 for r in rows)} merges, '
          f'{sum(bool(r[4]) for r in rows)} keyword candidates', file=sys.stderr)


if __name__ == '__main__':
    main()
