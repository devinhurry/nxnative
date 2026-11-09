"""Compare real MetalFX HUD modes using generated host test headers on macOS.

Build the existing t_framegen_motion target once to prepare its test headers.
The probe binary lives in a temporary directory; game files are not needed.
"""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
GAME = '01007EF00011E000'


def main():
    headers = [HERE / '../../host/gen' / GAME / 'game_profile.h',
               HERE / '../../host/gen/msl-macosx/host_msl_gen.h']
    if not all(path.is_file() for path in headers):
        raise SystemExit(f'Prepare test headers first: make -C {HERE} GAME={GAME} t_framegen_motion')
    dry = subprocess.run(['make', '-Bn', f'GAME={GAME}', 't_framegen_motion'],
                         cwd=HERE, check=True, capture_output=True, text=True).stdout
    lines = [line for line in dry.splitlines()
             if line.startswith('clang ') and 't_framegen_motion.m' in line]
    if len(lines) != 1:
        raise SystemExit('Could not find the existing framegen test compile command')
    command = shlex.split(lines[0])
    command[command.index('t_framegen_motion.m')] = 'research_framegen_ui_compare.m'
    with tempfile.TemporaryDirectory(prefix='framegen-ui-compare-') as folder:
        program = Path(folder) / 'probe'
        command[command.index('-o') + 1] = str(program)
        subprocess.run(command, cwd=HERE, check=True)
        env = dict(os.environ, MTL_DEBUG_LAYER='0')
        subprocess.run([str(program)], cwd=HERE, env=env, check=True)


if __name__ == '__main__':
    main()
