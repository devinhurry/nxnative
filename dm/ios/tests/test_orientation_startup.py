"""Run the production orientation policy before settings are applied, without UIKit."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs Foundation')
class StartupOrientation(unittest.TestCase):
    def test_device_policy_and_saved_choices(self):
        source = (REPO / 'dm/ios/Sources/front_ios.m').read_text()
        policy = source[source.index('UIInterfaceOrientationMask front_ios_orientations('):
                        source.index('static CGFloat g_picture_aspect')]
        fixture = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <assert.h>
#include "botw_touch_layout.h"
#define DM_GAME_ID "01007EF00011E000"
typedef NSUInteger UIInterfaceOrientationMask;
enum { UIInterfaceOrientationMaskPortrait=2, UIInterfaceOrientationMaskLandscape=24, UIInterfaceOrientationMaskAll=30 };
static NSUInteger editor;
NSUInteger dm_touch_editor_orientations(void) { return editor; }
static NSUserDefaults *preferences;
@interface FixtureDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
@end
@implementation FixtureDefaults
+ (NSUserDefaults *)standardUserDefaults { return preferences; }
@end
@interface FixtureWindow : NSObject
@property CGRect bounds;
@end
@implementation FixtureWindow
@end
@interface FixtureScreen : NSObject
+ (FixtureWindow *)mainScreen;
@end
@implementation FixtureScreen
+ (FixtureWindow *)mainScreen {
    FixtureWindow *screen=[FixtureWindow new]; screen.bounds=CGRectMake(0,0,430,932); return screen;
}
@end
#define UIWindow FixtureWindow
#define UIScreen FixtureScreen
#define NSUserDefaults FixtureDefaults
'''
        checks = r'''
#undef NSUserDefaults
int main(void) { @autoreleasepool {
    preferences=[[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    unsetenv("DM_BOTW_PORTRAIT"); unsetenv("DM_SAVED_CHOICES");
    FixtureWindow *window=[FixtureWindow new];
    const float sizes[][2]={{430,932},{932,430},{768,1024},{1024,768},{669,951},{951,669}};
    for (int i=0;i<6;i++) {
        window.bounds=CGRectMake(0,0,sizes[i][0],sizes[i][1]);
        assert(front_ios_orientations(window)==(i<2 ? 24 : 26));
    }
    window.bounds=CGRectMake(0,0,430,932);
    assert(front_ios_orientations(nil)==24);
    [preferences setVolatileDomain:@{@"launcher.DM_BOTW_PORTRAIT": @"1"} forName:NSArgumentDomain];
    assert(front_ios_orientations(window)==26);
    setenv("DM_BOTW_PORTRAIT","0",1); assert(front_ios_orientations(window)==24);
    setenv("DM_BOTW_PORTRAIT","1",1); assert(front_ios_orientations(window)==26);
    unsetenv("DM_BOTW_PORTRAIT"); setenv("DM_SAVED_CHOICES","0",1);
    assert(front_ios_orientations(window)==24);
    editor=2; assert(front_ios_orientations(window)==2); editor=0;
    unsetenv("DM_SAVED_CHOICES");
    [preferences setVolatileDomain:@{@"launcher.DM_BOTW_PORTRAIT": @1} forName:NSArgumentDomain];
    assert(front_ios_orientations(window)==24);
    puts("startup orientation: phone, tablet, Duo, saved choices and editor overrides passed");
} return 0; }
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            code, binary = root / 'orientation.m', root / 'orientation-check'
            code.write_text(fixture + policy + checks)
            built = subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc',
                                    '-framework', 'Foundation', '-framework', 'CoreGraphics',
                                    '-I', str(REPO / 'dm/host'), str(code), '-o', str(binary)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
