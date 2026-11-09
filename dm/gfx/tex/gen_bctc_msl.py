#!/usr/bin/env python3
"""Wrap nvn_bctc.metal into nvn_bctc_msl.h (a C string the runtime compiles with newLibraryWithSource).
usage: python3 gen_bctc_msl.py   (run after editing nvn_bctc.metal; the Makefile does not run it)"""
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true', help='fail if the generated header is stale')
args = parser.parse_args()
here = Path(__file__).resolve().parent
src = (here / 'nvn_bctc.metal').read_text()
lines = [l.replace('\\', '\\\\').replace('"', '\\"') for l in src.splitlines()]
out = ['// Generated from nvn_bctc.metal by gen_bctc_msl.py -- edit the .metal file, then rerun the script.', '#pragma once',
       'static const char k_bctc_msl[] =']
out += [f'"{l}\\n"' for l in lines]
out[-1] += ';'
header = here / 'nvn_bctc_msl.h'
text = '\n'.join(out) + '\n'
if args.check:
    if not header.is_file() or header.read_text() != text:
        parser.exit(1, 'nvn_bctc_msl.h is stale; run gen_bctc_msl.py\n')
else:
    header.write_text(text)
