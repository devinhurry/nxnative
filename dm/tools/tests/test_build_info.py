"""Generated build identity, prepared-project refresh and the six-character About display."""
from datetime import datetime, timezone
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import build_info


class BuildInfoTests(unittest.TestCase):
    def git(self, remote='https://github.com/jack/repo.git', dirty=''):
        def output(command, **kwargs):
            if 'rev-parse' in command: return 'abcdef012345\n'
            if 'status' in command: return dirty
            return remote
        return mock.patch.object(build_info.subprocess, 'check_output', side_effect=output)

    def test_github_origins_and_override_priority(self):
        for remote in ('https://github.com/jack/repo', 'https://github.com/jack/repo.git/',
                       'git@github.com:jack/repo.git', 'ssh://git@github.com/jack/repo.git', 'ssh://git@github.com:22/jack/repo.git',
                       'https://user:secret@github.com/jack/repo.git'):
            with self.subTest(remote=remote), self.git(remote), mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(build_info.source_info(), {'DMCommit': 'abcdef012345', 'DMRepository': 'jack/repo'})
                with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY': 'ci/fork'}):
                    self.assertEqual(build_info.source_info()['DMRepository'], 'ci/fork')
                    with mock.patch.dict(os.environ, {'DM_REPOSITORY': 'chosen/repo'}):
                        self.assertEqual(build_info.source_info()['DMRepository'], 'chosen/repo')
        for remote in ('https://gitlab.com/jack/repo', 'https://evilgithub.com/jack/repo.git',
                       'https://github.com:secret@evil.com/jack/repo', 'https://[bad-url/jack/repo', '/local/repo'):
            with self.subTest(remote=remote), self.git(remote), mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(build_info.source_info()['DMRepository'], 'unknown')

    def test_dirty_and_missing_git(self):
        with self.git(dirty=' M source.c\n'):
            self.assertEqual(build_info.source_info()['DMCommit'], 'abcdef012345+dirty')
        for error in (FileNotFoundError(), subprocess.CalledProcessError(128, 'git')):
            with self.subTest(error=error), mock.patch.object(build_info.subprocess, 'check_output', side_effect=error), mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(build_info.source_info(), {'DMCommit': 'unknown', 'DMRepository': 'unknown'})

    def test_stamp_refreshes_generated_copy_and_preserves_template(self):
        with tempfile.TemporaryDirectory() as temporary, self.git(), mock.patch.dict(os.environ, {}, clear=True):
            root = Path(temporary)
            source, output = root / 'Info.plist', root / 'derived/StampedInfo.plist'
            template = plistlib.dumps({'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)', 'DMChain': 'shader-chain', 'DMCommit': 'stale'})
            source.write_bytes(template)
            for now in (datetime(2026, 10, 31, 12, 0, 0, tzinfo=timezone.utc), datetime(2026, 10, 31, 12, 0, 2, tzinfo=timezone.utc)):
                with mock.patch.object(build_info, 'datetime') as clock:
                    clock.now.return_value = now
                    build_info.stamp(source, output)
                stamped = plistlib.loads(output.read_bytes())
                self.assertEqual(stamped['DMBuildTime'], now.strftime('%Y-%m-%dT%H:%M:%SZ'))
                self.assertEqual(stamped['DMCommit'], 'abcdef012345')
                self.assertEqual(stamped['DMRepository'], 'jack/repo')
                self.assertEqual(stamped['DMChain'], 'shader-chain')
                self.assertEqual(stamped['CFBundleVersion'], '$(CURRENT_PROJECT_VERSION)')
                self.assertEqual(source.read_bytes(), template)

    def test_prepared_project_tools_symlink_follows_source_checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'tools').symlink_to(REPO / 'dm/ios/tools', target_is_directory=True)
            source, output = root / 'Info.plist', root / 'derived/StampedInfo.plist'
            source.write_bytes(plistlib.dumps({'CFBundleVersion': '1.0'}))
            subprocess.run([sys.executable, root / 'tools/stamp_build.py', source, output], check=True)
            stamped = plistlib.loads(output.read_bytes())
            self.assertEqual(stamped['DMCommit'], build_info.source_info()['DMCommit'])
            self.assertEqual(stamped['DMRepository'], build_info.source_info()['DMRepository'])
            datetime.strptime(stamped['DMBuildTime'], '%Y-%m-%dT%H:%M:%SZ')


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'About display uses Foundation')
class AboutDisplayTests(unittest.TestCase):
    def test_display_shortens_only_the_hash_and_handles_missing_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, binary = root / 'about.m', root / 'about'
            source.write_text('#import "build_info_apple.h"\n'
                              'int main(int argc, char **argv) { @autoreleasepool {\n'
                              'NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];\n'
                              'puts(dm_build_about_message(bundle).UTF8String);\n'
                              '} return 0; }\n')
            subprocess.run(['clang', '-fobjc-arc', '-I', REPO / 'dm/host', source, '-framework', 'Foundation', '-o', binary], check=True)
            for index, (commit, displayed) in enumerate((('abcdef012345', 'abcdef'), ('abcdef012345+dirty', 'abcdef+dirty'), ('unknown', 'unknown'), (None, 'unknown'))):
                bundle = root / f'Fixture{index}.bundle/Contents'
                bundle.mkdir(parents=True)
                info = {'CFBundleIdentifier': f'org.nxnative.about-test-{index}', 'DMRepository': 'jack/repo', 'DMBuildTime': '2026-10-31T12:00:00Z'}
                if commit is not None: info['DMCommit'] = commit
                (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
                message = subprocess.check_output([binary, bundle.parent], text=True)
                self.assertEqual(message, f'Repository: jack/repo\nCommit: {displayed}\nBuilt (UTC): 2026-10-31T12:00:00Z\n')


if __name__ == '__main__':
    unittest.main()
