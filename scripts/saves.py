#!/usr/bin/env python3
"""Manage game saves with the same native backend used by the Mac and iOS apps."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]


def native_tool():
    sources = [REPO / p for p in ('dm/tools/saves.m', 'dm/host/save_manager.m', 'dm/host/save_sync.c')]
    inputs = sources + [REPO / 'dm/host/save_manager.h', REPO / 'dm/host/save_sync.h', Path(__file__)]
    output = REPO / 'dm/host/gen/tools/saves'
    if output.is_file() and output.stat().st_mtime_ns >= max(p.stat().st_mtime_ns for p in inputs):
        return output
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as temp:
        binary = Path(temp) / 'saves'
        subprocess.run(['xcrun', 'clang', '-O2', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                        '-fobjc-arc', '-framework', 'Foundation', *map(str, sources), '-o', str(binary)], check=True)
        binary.replace(output)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game', required=True, help='base game title ID (16 hexadecimal digits)')
    parser.add_argument('--root', type=Path, help='game data root; default: this game in Mac Application Support')
    parser.add_argument('--cloud', type=Path, help='shared cloud folder; otherwise uses DM_SAVE_SYNC')
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('list', 'refresh'):
        commands.add_parser(name)
    commands.add_parser('create').add_argument('name')
    for name in ('select', 'delete', 'restore', 'sync'):
        commands.add_parser(name).add_argument('slot')
    for name in ('copy', 'rename'):
        command = commands.add_parser(name)
        command.add_argument('slot')
        command.add_argument('name')
    command = commands.add_parser('import')
    command.add_argument('source', type=Path)
    command.add_argument('--name', default='')
    command.add_argument('--raw', action='store_true', help='source is the raw contents of one game save')
    command = commands.add_parser('export')
    command.add_argument('slot')
    command.add_argument('destination', type=Path)
    args = parser.parse_args()
    if len(args.game) != 16 or any(c not in '0123456789abcdefABCDEF' for c in args.game):
        parser.error('--game must be a 16-digit hexadecimal title ID')
    root = (args.root or Path.home() / 'Library/Application Support/nxnative' / args.game.upper()).resolve()
    operation = args.command
    values = []
    if operation == 'create':
        values = [args.name]
    elif operation in ('select', 'delete', 'restore', 'sync'):
        values = [args.slot]
    elif operation in ('copy', 'rename'):
        values = [args.slot, args.name]
    elif operation == 'import':
        values = [str(args.source.absolute()), args.name]
        if args.raw:
            operation = 'import-raw'
    elif operation == 'export':
        values = [args.slot, str(args.destination.absolute())]
    env = os.environ.copy()
    if args.cloud:
        env['DM_SAVE_SYNC'] = str(args.cloud.resolve())
    return subprocess.run([str(native_tool()), str(root), args.game, operation, *values], env=env, check=False).returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'[RED] saves: {error}')
