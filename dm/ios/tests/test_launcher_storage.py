"""Compile and run the launcher's real settings model on macOS; no simulator or UI required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/games'))
import settings


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class LauncherStorageTests(unittest.TestCase):
    def test_shared_module_supports_c_objc_and_swift(self):
        with tempfile.TemporaryDirectory() as temporary:
            tmp = Path(temporary)
            c = tmp / 'module.c'
            c.write_text('#include "launcher_settings.h"\n#include "memory_mode.h"\n'
                         'int check(void) { return dm_low_memory_default(0); }\n')
            objc = tmp / 'module.m'
            objc.write_text('#include "botw_touch_style.h"\n#include "touchpad_geometry.h"\n'
                            '#include "botw_stick_settings.h"\n#include "botw_touch_layout.h"\nvoid check(void) {\n'
                            'NSString *icon = dm_botw_touch_button_icon_path(0); (void)icon;\n'
                            'dm_touchpad_stick_response response; (void)dm_botw_stick_settings_read(&response);\n'
                            'CGPathRef p = dm_botw_switch_cancel_path(CGPointZero, 52); CGPathRelease(p);\n}\n')
            swift = tmp / 'module.swift'
            swift.write_text('import DmTouchPad\nimport CoreGraphics\nfunc check() {\n'
                             '_ = dm_botw_touch_button_icon_path(0)\n'
                             '_ = dm_botw_layout_defaults()\n}\n')
            for sdk, target in (('macosx', 'arm64-apple-macos26.0'), ('iphoneos', 'arm64-apple-ios26.0')):
                probe = subprocess.run(['xcrun', '--sdk', sdk, '--show-sdk-path'], capture_output=True, text=True)
                if probe.returncode:
                    if sdk == 'iphoneos':
                        continue   # Command Line Tools alone have no device SDK.
                    self.fail(probe.stderr)
                cache = tmp / sdk
                common = ['-target', target, '-I', str(REPO / 'dm/host')]
                clang = ['xcrun', '--sdk', sdk, 'clang', '-isysroot', probe.stdout.strip(), *common,
                         '-fmodules', '-fimplicit-module-maps', f'-fmodules-cache-path={cache}', '-fsyntax-only']
                for language, flags, source in (('C', ['-std=gnu11'], c), ('Objective-C', ['-fobjc-arc'], objc)):
                    with self.subTest(sdk=sdk, language=language):
                        result = subprocess.run([*clang, *flags, str(source)], capture_output=True, text=True, timeout=60)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                with self.subTest(sdk=sdk, language='Swift'):
                    result = subprocess.run(['xcrun', '--sdk', sdk, 'swiftc', '-typecheck', '-swift-version', '5',
                                             '-sdk', probe.stdout.strip(), *common, '-module-cache-path', str(cache), str(swift)],
                                            capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                if sdk == 'iphoneos':
                    profile = tmp / 'profile'
                    profile.mkdir()
                    subprocess.run([sys.executable, str(REPO / 'dm/games/game.py'), 'header', '01007EF00011E000',
                                    str(profile / 'game_profile.h')], check=True, capture_output=True, text=True)
                    for name in ('DmGamepad.m', 'front_ios.m'):
                        with self.subTest(sdk=sdk, source=name):
                            result = subprocess.run([*clang, '-fobjc-arc', '-fblocks', '-I', str(profile),
                                                     '-I', str(REPO / 'dm/gfx/nvn'), str(REPO / 'dm/ios/Sources' / name)],
                                                    capture_output=True, text=True, timeout=60)
                            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_only_changed_choices_are_stored(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / 'patched').mkdir()
            (tmp / 'patched/main.fixups.tsv').write_text('# RENDER_SCALE\t1\n# FPS_STATE_OFF\t0x4000\n')
            with patch.dict(os.environ, {'GFXAPI': 'nvn'}), patch.object(settings.nacp, 'languages', return_value=['en-US', 'ja']):
                (tmp / 'launcher.json').write_text(json.dumps(settings.build('01007EF00011E000', tmp / 'patched', tmp / 'control.nacp')))
                with patch.dict(os.environ, {'SETTINGS_PLATFORM': 'mac'}):   # the Mac window's list: Display mode, the render scale's base size
                    (tmp / 'launcher_mac.json').write_text(json.dumps(settings.build('01007EF00011E000', tmp / 'patched', tmp / 'control.nacp')))
            exe = tmp / 'launcher_storage_check'
            compile_result = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '5', '-D', 'DM_HOST_UI', '-parse-as-library', '-module-cache-path', str(tmp / 'module-cache'),
                            '-I', str(REPO / 'dm/host'), '-o', str(exe), str(REPO / 'dm/ios/Sources/LauncherSettings.swift'), str(REPO / 'dm/ios/Sources/LauncherRow.swift'), str(REPO / 'dm/ios/Sources/BotwTouchSettings.swift'), str(REPO / 'dm/mac/Launcher.swift'),
                            str(Path(__file__).with_name('launcher_layout_check.swift')), str(Path(__file__).with_name('launcher_storage_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            r = subprocess.run([str(exe), str(tmp / 'launcher.json'), str(tmp / 'launcher_mac.json')], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('launcher storage: 0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
