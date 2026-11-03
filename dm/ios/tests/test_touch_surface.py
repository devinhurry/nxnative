"""New UIKit region declarations must not become required launch-time symbols."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs Apple Objective-C tools')
class TouchSurfaceTests(unittest.TestCase):
    def test_new_region_api_is_optional_at_link_and_runtime(self):
        # Exercise the newer-SDK branch even on builders whose real UIKit lacks it.
        # Deliberately omit class availability annotations to expose strong imports.
        header = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#undef __IPHONE_27_1
#undef __IPHONE_OS_VERSION_MAX_ALLOWED
#define __IPHONE_27_1 270100
#define __IPHONE_OS_VERSION_MAX_ALLOWED 270200
@interface UIViewReservedRegionKind : NSObject
+ (instancetype)divisionRegionKind;
@end
@interface UIViewReservedRegion : NSObject
@property CGRect frame;
@end
@interface UIView : NSObject
@property CGRect bounds;
- (NSArray<UIViewReservedRegion *> *)reservedRegionsOfKind:(UIViewReservedRegionKind *)kind;
@end
'''
        fixture = r'''
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <assert.h>
CGRect probe(UIView *view);
static id kind;
static NSArray *regions;
static int calls;
static id division_kind(id receiver, SEL selector) { return kind; }
@implementation UIViewReservedRegion
@end
@implementation UIView
- (NSArray *)reservedRegionsOfKind:(id)value {
    assert(value == kind); calls++; return regions;
}
@end
int main(void) { @autoreleasepool {
    UIView *view = [UIView new]; view.bounds = CGRectMake(0, 0, 900, 700);
    assert(CGRectIsNull(probe(view)) && calls == 0);
    Class cls = objc_allocateClassPair(NSObject.class, "UIViewReservedRegionKind", 0);
    assert(cls); objc_registerClassPair(cls);
    assert(CGRectIsNull(probe(view)) && calls == 0);
    assert(class_addMethod(object_getClass(cls), @selector(divisionRegionKind), (IMP)division_kind, "@@:"));
    assert(CGRectIsNull(probe(view)) && calls == 0);
    kind = [NSObject new];
    UIViewReservedRegion *region = [UIViewReservedRegion new];
    region.frame = CGRectMake(0, 300, 900, 20); regions = @[region];
    assert(CGRectEqualToRect(probe(view), region.frame) && calls == 1);
    regions = @[];
    assert(CGRectIsNull(probe(view)) && calls == 2);
    puts("touch surface: absent APIs are optional; available Seated regions still work");
} return 0; }
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'UIKit').mkdir()
            (root / 'UIKit/UIKit.h').write_text(header)
            probe = root / 'probe.m'
            probe.write_text('#import "BotwTouchSurface.h"\nCGRect probe(UIView *v) { return dm_botw_touch_division(v); }\n')
            source, obj, binary = root / 'fixture.m', root / 'probe.o', root / 'check'
            source.write_text(fixture)
            clang = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-O2', '-Werror',
                     '-I', str(root), '-I', str(REPO / 'dm/ios/Sources'), '-I', str(REPO / 'dm/host')]
            compiled = subprocess.run([*clang, '-c', str(probe), '-o', str(obj)], capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            symbols = subprocess.run(['xcrun', 'nm', '-u', str(obj)], capture_output=True, text=True, check=True, timeout=15).stdout
            for name in ('UIViewReservedRegionKind', 'UIViewReservedRegion'):
                self.assertNotIn('_OBJC_CLASS_$_' + name, symbols)
            linked = subprocess.run([*clang, str(source), str(obj), '-framework', 'Foundation',
                                     '-framework', 'CoreGraphics', '-o', str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(linked.returncode, 0, linked.stdout + linked.stderr)
            ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            self.assertIn('available Seated regions still work', ran.stdout)


if __name__ == '__main__':
    unittest.main()
