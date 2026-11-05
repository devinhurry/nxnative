#!/usr/bin/env python3
"""Manage game saves with the same native backend used by the Mac and iOS apps."""
import argparse
import json
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
                        '-fobjc-arc', '-framework', 'Foundation', '-larchive', *map(str, sources), '-o', str(binary)], check=True)
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
    command.add_argument('source', type=Path, nargs='+', help='one or more .dmsync, ZIP, 7z or RAR archives, or save directories')
    command.add_argument('--name', default='')
    command.add_argument('--raw', action='store_true', help='source is the raw contents of one game save')
    command.add_argument('--layout', choices=('auto', 'root', 'inside'), default='auto', help='resolve an ambiguous single-folder archive')
    command = commands.add_parser('export')
    command.add_argument('slot')
    command.add_argument('destination', type=Path, help='a new .zip file, or .dmsync for the legacy portable format')
    command = commands.add_parser('export-many', help='export chosen saves, or all saves if no IDs are supplied')
    command.add_argument('destination', type=Path)
    command.add_argument('slots', nargs='*')
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
        if args.raw and args.layout != 'auto':
            parser.error('--raw already selects the complete source directory; do not combine it with --layout')
        paths = [str(path.absolute()) for path in args.source]
        if len(paths) > 1:
            if args.raw or args.name:
                parser.error('--raw and --name apply to one source at a time')
            operation = 'import-many'
            values = [json.dumps(paths), json.dumps({path: args.layout for path in paths})]
        else:
            values = [paths[0], args.name]
        if args.raw:
            operation = 'import-raw'
        elif len(paths) == 1 and args.layout != 'auto':
            operation = 'import-' + args.layout
    elif operation == 'export':
        values = [args.slot, str(args.destination.absolute())]
    elif operation == 'export-many':
        values = [json.dumps(args.slots), str(args.destination.absolute())]
    env = os.environ.copy()
    if args.cloud:
        env['DM_SAVE_SYNC'] = str(args.cloud.resolve())
    result = subprocess.run([str(native_tool()), str(root), args.game, operation, *values], env=env, check=False, capture_output=True, text=True)
    if result.returncode == 0 and 'needs_layout' in json.loads(result.stdout):
        layout = json.loads(result.stdout)['needs_layout']
        print(f"[RED] saves: choose --layout root to keep {layout['folder']}/, or --layout inside to use its contents.", file=sys.stderr)
        return 1
    if result.stdout:
        print(result.stdout, end='')
    if result.stderr:
        print(result.stderr, end='', file=sys.stderr)
    return result.returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'[RED] saves: {error}')
