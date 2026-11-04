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
        policy = source[source.index('UIInterfaceOrientationMask front_ios_scene_orientations('):
                        source.index('static CGFloat g_picture_aspect')]
        fixture = r'''
#import <Foundation/Foundation.h>
#include <assert.h>
#include "botw_touch_layout.h"
static const char *test_game_id="01007EF00011E000";
#define DM_GAME_ID test_game_id
typedef NSUInteger UIInterfaceOrientationMask;
enum { UIInterfaceOrientationMaskPortrait=2, UIInterfaceOrientationMaskLandscape=24, UIInterfaceOrientationMaskAll=30 };
enum { UIUserInterfaceSizeClassUnspecified, UIUserInterfaceSizeClassCompact, UIUserInterfaceSizeClassRegular };
static NSUInteger editor;
NSUInteger dm_touch_editor_orientations(void) { return editor; }
static NSUserDefaults *preferences;
@interface FixtureDefaults : NSObject
+ (NSUserDefaults *)standardUserDefaults;
@end
@implementation FixtureDefaults
+ (NSUserDefaults *)standardUserDefaults { return preferences; }
@end
@interface FixtureTraits : NSObject
@property NSUInteger horizontalSizeClass, verticalSizeClass;
@end
@implementation FixtureTraits
@end
@interface FixtureScene : NSObject
@property FixtureTraits *traitCollection;
@end
@implementation FixtureScene
@end
#define UIWindowScene FixtureScene
#define UITraitCollection FixtureTraits
#define NSUserDefaults FixtureDefaults
'''
        checks = r'''
#undef NSUserDefaults
int main(void) { @autoreleasepool {
    preferences=[[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    unsetenv("DM_BOTW_PORTRAIT"); unsetenv("DM_SAVED_CHOICES");
    FixtureScene *scene=[FixtureScene new]; scene.traitCollection=[FixtureTraits new];
    const NSUInteger traits[][2]={{1,2},{1,1},{2,2},{2,1},{0,0}};
    for (int i=0;i<5;i++) {
        scene.traitCollection.horizontalSizeClass=traits[i][0];
        scene.traitCollection.verticalSizeClass=traits[i][1];
        assert(front_ios_scene_orientations(scene)==(i==2 ? 30 : 24));
    }
    // A regular scene needs neither a window nor an outer-screen lookup.
    scene.traitCollection.horizontalSizeClass=scene.traitCollection.verticalSizeClass=2;
    assert(front_ios_scene_orientations(scene)==30);
    assert(front_ios_scene_orientations(nil)==24);
    editor=2; assert(front_ios_scene_orientations(scene)==30); editor=0;
    setenv("DM_BOTW_PORTRAIT","0",1);
    assert(front_ios_scene_orientations(scene)==30); unsetenv("DM_BOTW_PORTRAIT");
    scene.traitCollection.horizontalSizeClass=1;
    [preferences setVolatileDomain:@{@"launcher.DM_BOTW_PORTRAIT": @"1"} forName:NSArgumentDomain];
    assert(front_ios_scene_orientations(scene)==26);
    setenv("DM_BOTW_PORTRAIT","0",1); assert(front_ios_scene_orientations(scene)==24);
    setenv("DM_BOTW_PORTRAIT","1",1); assert(front_ios_scene_orientations(scene)==26);
    unsetenv("DM_BOTW_PORTRAIT"); setenv("DM_SAVED_CHOICES","0",1);
    assert(front_ios_scene_orientations(scene)==24);
    editor=2; assert(front_ios_scene_orientations(scene)==2); editor=0;
    unsetenv("DM_SAVED_CHOICES");
    [preferences setVolatileDomain:@{@"launcher.DM_BOTW_PORTRAIT": @1} forName:NSArgumentDomain];
    assert(front_ios_scene_orientations(scene)==24);
    test_game_id="other"; assert(front_ios_scene_orientations(scene)==30);
    puts("startup orientation: scene traits, saved portrait permission and editor overrides passed");
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
