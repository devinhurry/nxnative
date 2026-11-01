#!/usr/bin/env python3
"""Run the production Mac launcher/settings UI against synthetic resources."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[3]
if len(sys.argv) != 2: sys.exit('usage: run_launcher_check.py <new external scratch directory>')
work = Path(sys.argv[1]).resolve(); work.mkdir(parents=True)
app = work / 'LauncherCheck.app/Contents'
binary = app / 'MacOS/LauncherCheck'; binary.parent.mkdir(parents=True)
resources = app / 'Resources'; (resources / 'dm').mkdir(parents=True)
for name in ('romfs', 'msl', 'patched'): (work / name).mkdir()
(work / 'patched/main.fixups.tsv').write_text('# RENDER_SCALE\t1\n')
env = dict(os.environ, SETTINGS_PLATFORM='mac', GFXAPI='nvn')
subprocess.run([sys.executable, str(REPO / 'dm/games/settings.py'), '01007EF00011E000', str(work / 'patched'),
                str(work / 'control.nacp'), str(resources / 'dm/launcher.json')], env=env, check=True)
for source in (REPO / 'dm/ios/Sources').glob('*.lproj'): shutil.copytree(source, resources / source.name)
info = dict(CFBundleIdentifier='org.nxnative.maclaunchercomponentcheck', CFBundleExecutable='LauncherCheck',
            CFBundleName='Mac Launcher Component Check', CFBundlePackageType='APPL', CFBundleDevelopmentRegion='en')
(app / 'Info.plist').write_bytes(plistlib.dumps(info))
subprocess.run(['make', '-s', '-C', str(REPO / 'dm/host'), 'GAME=01007EF00011E000', 'gen/mac-ui.o'], check=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=26.0', str(Path(__file__).with_name('launcher_host_check.m')),
                str(REPO / 'dm/host/gen/mac-ui.o'), '-L' + sdk + '/usr/lib/swift', '-Wl,-rpath,/usr/lib/swift',
                '-framework', 'AppKit', '-framework', 'SwiftUI', '-o', str(binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app.parent)], check=True)
env.update(DM_ROMFS=str(work / 'romfs'), DM_MSL_DIR=str(work / 'msl'))
subprocess.run([str(binary), '-AppleLanguages', '(en)'], env=env, check=True, timeout=35)
