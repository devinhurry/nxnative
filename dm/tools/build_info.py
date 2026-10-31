"""Build metadata shared by the iOS build phase and the Mac app packer.

Only generated plists are written; tracked sources never change during a build.
"""
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit

REPO = Path(__file__).resolve().parents[2]


def source_info():
    def git(*args):
        try:
            return subprocess.check_output(['git', '--no-optional-locks', '-C', str(REPO), *args],
                                           text=True, stderr=subprocess.DEVNULL).strip()
        except (OSError, subprocess.CalledProcessError):
            return ''

    commit = git('rev-parse', '--short=12', 'HEAD') or 'unknown'
    if commit != 'unknown' and git('status', '--porcelain', '--untracked-files=no'):
        commit += '+dirty'
    # Normalize SCP-style SSH URLs, then take only a GitHub path, never URL credentials.
    remote = git('remote', 'get-url', 'origin')
    if '://' not in remote: remote = 'ssh://' + remote.replace(':', '/', 1)
    try:
        url = urlsplit(remote)
        path = url.path.strip('/').removesuffix('.git') if url.hostname == 'github.com' else ''
    except ValueError:
        path = ''
    repository = os.environ.get('DM_REPOSITORY') or os.environ.get('GITHUB_REPOSITORY') or (path if re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', path) else 'unknown')
    return {'DMCommit': commit, 'DMRepository': repository}


def build_time():
    return datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def stamp(source, output):
    info = plistlib.loads(Path(source).read_bytes())
    info.update(source_info(), DMBuildTime=build_time())
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(info))


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: build_info.py <input Info.plist> <generated Info.plist>')
    stamp(*sys.argv[1:])


if __name__ == '__main__':
    main()
