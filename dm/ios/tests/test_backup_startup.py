"""Run the real backup-exclusion loop without a device, game data or the app UI."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def probe_source():
    main = (REPO / 'dm/ios/Sources/main.m').read_text()
    images = main[main.index('static NSArray<NSString *> *romfs_document_images'):main.index('static NSString *romfs_locate')]
    exclude = main[main.index('    // Keep game files and scratch data'):main.index('    // Log: the host only writes')]
    return r'''#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdio.h>
static unsigned writes;
static IMP original_set;
static BOOL counted_set(id object, SEL selector, id value, NSURLResourceKey key, NSError **error) {
    if ([key isEqualToString:NSURLIsExcludedFromBackupKey]) writes++;
    return ((BOOL (*)(id, SEL, id, NSURLResourceKey, NSError **))original_set)(object, selector, value, key, error);
}
''' + images + '\nstatic void exclude_backup(NSString *doc) {\n    NSFileManager *fm = NSFileManager.defaultManager;\n' + exclude + r'''
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 2) return 2;
    NSString *doc = @(argv[1]);
    Method method = class_getInstanceMethod(NSURL.class, @selector(setResourceValue:forKey:error:));
    original_set = method_setImplementation(method, (IMP)counted_set);
    exclude_backup(doc);
    for (NSString *name in @[@"romfs", @"aoc", @"temp", @"RomFS.img"]) {
        NSNumber *excluded = nil;
        NSURL *url = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:name]];
        if (![url getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil] || !excluded.boolValue) return 3;
    }
    NSNumber *saveExcluded = nil;
    [[NSURL fileURLWithPath:[doc stringByAppendingPathComponent:@"save"]]
        getResourceValue:&saveExcluded forKey:NSURLIsExcludedFromBackupKey error:nil];
    if (saveExcluded.boolValue) return 4;
    printf("%u\n", writes);
    return 0;
} }
'''


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required')
class BackupStartup(unittest.TestCase):
    def test_restarts_preserve_image_identity_and_leave_saves_backed_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'backup.m'; source.write_text(probe_source())
            binary = root / 'backup'
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Wall', '-Werror',
                            str(source), '-framework', 'Foundation', '-o', str(binary)], check=True)
            doc = root / 'Documents'; doc.mkdir()
            for name in ('romfs', 'aoc', 'temp', 'save'):
                (doc / name).mkdir()
            image = doc / 'RomFS.img'; image.write_bytes(b'unchanged game data')
            def launch():
                return int(subprocess.check_output([str(binary), str(doc)], text=True))
            self.assertEqual(launch(), 4)
            before = image.stat()
            for _ in range(3):
                self.assertEqual(launch(), 0)
                after = image.stat()
                self.assertEqual((after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                                 (before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns))
            self.assertEqual(image.read_bytes(), b'unchanged game data')


if __name__ == '__main__':
    unittest.main()
