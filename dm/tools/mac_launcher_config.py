"""Prepare the shared launcher beside a direct Mac runtime, without game copies."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import build_info
import nacp


def prepare(repo, output, host, patched, environment, game, graphics, source):
    repo, output, host = Path(repo), Path(output), Path(host)
    output.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env.update({k: str(v) for k, v in environment.items()})
    env.update(SETTINGS_PLATFORM='mac', GFXAPI=graphics)
    if game.dir.resolve() != (repo / 'dm/games' / game.id).resolve():
        env.update(DM_GAMES_DIR=str(game.dir.parent), DM_GAMES_FIRST='1')
    control = Path(environment['DM_ROMFS']).parent / 'control.nacp'
    result = subprocess.run([sys.executable, str(repo / 'dm/games/settings.py'), game.id,
                             str(patched), str(control), str(output)],
                            env=env, capture_output=True, text=True)
    if result.returncode:
        raise ValueError('cannot prepare Mac launcher settings: ' + (result.stderr or result.stdout).strip())
    data = json.loads(output.read_text())
    identity = build_info.source_info()
    identity['DMCommit'] = source['commit'][:12] + ('+dirty' if source.get('dirty') else '')
    identity.update(CFBundleName=game.get('name', game.id),
                    CFBundleShortVersionString=nacp.version(control) or game.get('package', ''),
                    DMBuildTime=datetime.fromtimestamp(host.stat().st_mtime, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
    data['metadata'] = identity
    output.write_text(json.dumps(data, indent=2) + '\n')
    files = [output]
    for strings in sorted((repo / 'dm/ios/Sources').glob('*.lproj/Localizable.strings')):
        target = host.parent / strings.parent.name / strings.name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(strings, target)
        files.append(target)
    return files
