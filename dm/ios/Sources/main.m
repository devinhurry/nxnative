// iOS App entry: set the environment (game files, saves, shader libraries), write the host log to Documents/log.txt, create the window (front_ios.m), then run the host's dm_main on a big-stack thread.
// The game files (RomFS) ship inside the App at <App>/romfs; Documents/romfs.img (plain or combined base + DLC), Documents/romfs and previously imported Documents/game-data/romfs are also accepted.
#import <UIKit/UIKit.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "game_profile.h"   // game profile constants (the RomFS marker path)
#include "front.h"
#include "romfs_image.h"
#include "romfs_identity.h"
#import "GameFiles.h"
#include "player_env.h"
#ifndef DM_PLAYER_BUILD
#define DM_PLAYER_BUILD 0
#endif

extern char **environ;

int dm_main(int argc, char **argv);   // dm/host/main.c compiled in with -Dmain=dm_main
UIViewController *front_ios_root(void);
void front_ios_focus_event(int ev);
void dm_gamepad_geometry_changed(UIInterfaceOrientation orientation);

static char *g_argv[4]; static int g_argc;
static int g_boot_ok;

// Documents/romfs.img, one RomFS image file (dm/tools/romfs_image.py, scripts/push_romfs.sh): only a complete one counts. Its index is written last and ends the file, so a copy cut off partway is skipped
static int romfs_image_complete(NSString *path, romfs_img **out) {
    romfs_img *m = romfs_image_open(path.fileSystemRepresentation);
    if (!m) {
        if (errno != ENOENT) fprintf(stderr, "[RED] boot: invalid RomFS image %s (errno=%d); trying the folders\n", path.fileSystemRepresentation, errno);
        return 0;
    }
    *out = m; return 1;
}
// A build made with DM_COPY_ROMFS=NO carries <App>/romfs.id (dm/host/romfs_identity.h): only a Documents/romfs.img with that identity is used. No romfs.id (the default build): any complete image
static int romfs_identity_accepts(NSString *img) {
    romfs_id want, got;
    int rc = romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation, img.fileSystemRepresentation, &want, &got);
    if (rc == ROMFS_ID_DIFFERENT) {
        romfs_id base, actual;
        if (romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.base.id"].fileSystemRepresentation,
                           img.fileSystemRepresentation, &base, &actual) == ROMFS_ID_OK) return 1;   // the same build's original base-only image
    }
    if (rc != ROMFS_ID_OK && rc != ROMFS_ID_NONE) fprintf(stderr, "[RED] boot: Documents/%s is not the image this build needs (verdict %d); not used\n", img.lastPathComponent.UTF8String, rc);
    return rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE;
}
// The identity above covers the physical image, including all DLC. Only after that check may its romfs directory become the game mount.
static NSString *romfs_image_view(NSString *path, romfs_img *m) {
    uint64_t root;
    if (romfs_image_combined(m, &root, NULL)) {
        m->root = root;
        if (romfs_image_find(m, DM_GAME_ROMFS_MARKER) >= 0) return [path stringByAppendingPathComponent:@"romfs"];
    } else if (romfs_image_find(m, DM_GAME_ROMFS_MARKER) >= 0) return path;
    fprintf(stderr, "[RED] boot: RomFS image %s lacks this game's marker; not used\n", path.fileSystemRepresentation);
    return nil;
}
NSString *front_ios_game_image_error(NSString *path) {
    romfs_img *m = NULL;
    if (!romfs_image_complete(path, &m))
        return NSLocalizedString(@"This is not a complete RomFS image. Choose the .img created with this app.", nil);
    int accepted = romfs_identity_accepts(path);
    NSString *view = accepted ? romfs_image_view(path, m) : nil; romfs_image_close(m);
    if (!accepted) return NSLocalizedString(@"This image does not match this app's game, update or DLC. Choose the .img produced with this build.", nil);
    if (!view) return NSLocalizedString(@"This image does not contain this game's files.", nil);
    return nil;
}
// The images in Documents: romfs.img in any letter case, romfs.img itself first. The NSP script writes the image as RomFS.img (extract/<version>/RomFS.img) and the Mac's
// file system ignores letter case, but iOS's does not: a copy made through Finder or the Files app keeps the source's name, which an exact lookup of romfs.img never finds
static NSArray<NSString *> *romfs_document_images(NSString *doc) {
    NSMutableArray<NSString *> *imgs = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:doc error:nil])
        if ([n caseInsensitiveCompare:@"romfs.img"] == NSOrderedSame) [imgs addObject:[doc stringByAppendingPathComponent:n]];
    [imgs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL ea = [a.lastPathComponent isEqualToString:@"romfs.img"], eb = [b.lastPathComponent isEqualToString:@"romfs.img"];
        return ea != eb ? (ea ? NSOrderedAscending : NSOrderedDescending) : [a compare:b];
    }];
    return imgs;
}
static NSString *romfs_locate(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    for (NSString *img in romfs_document_images(doc)) {
        romfs_img *m = NULL;
        if (!romfs_image_complete(img, &m)) continue;
        NSString *view = romfs_identity_accepts(img) ? romfs_image_view(img, m) : nil;
        romfs_image_close(m);
        if (!view) continue;
        // A folder copy from before images is now dead weight of up to many GB (often cut off partway). Deleting its 300,000 files here took longer than iOS allows an app to start
        // (Tears of the Kingdom: killed on a black screen), so it is moved aside at once and deleted in the background, leftovers of an interrupted delete included
        NSString *old = [doc stringByAppendingPathComponent:@"romfs"], *tmp = NSTemporaryDirectory();
        if ([fm fileExistsAtPath:old] && [fm moveItemAtPath:old toPath:[tmp stringByAppendingPathComponent:[@"romfs-old-" stringByAppendingString:NSUUID.UUID.UUIDString]] error:nil])
            fprintf(stderr, "boot: Documents/romfs moved aside for deletion (Documents/%s replaces it)\n", img.lastPathComponent.UTF8String);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            NSFileManager *bfm = [NSFileManager new];
            for (NSString *n in [bfm contentsOfDirectoryAtPath:tmp error:nil]) if ([n hasPrefix:@"romfs-old-"]) [bfm removeItemAtPath:[tmp stringByAppendingPathComponent:n] error:nil];
        });
        return view;
    }
    NSString *bundledImage = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.img"];
    for (NSString *d in @[[doc stringByAppendingPathComponent:@"game-data/romfs"], [doc stringByAppendingPathComponent:@"romfs"]])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) return d;
    romfs_img *m = NULL;
    if (romfs_image_complete(bundledImage, &m)) {
        NSString *view = romfs_image_view(bundledImage, m); romfs_image_close(m);
        if (view) return view;
    }
    NSString *bundledFolder = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs"];
    if ([fm fileExistsAtPath:[bundledFolder stringByAppendingPathComponent:@DM_GAME_ROMFS_MARKER]]) return bundledFolder;   // only a directory containing the game profile's romfs_marker path counts
    return nil;
}

static void romfs_identity_report(NSString *doc);
int front_ios_prepare_game(void) {
    if (g_boot_ok) return 1;
    NSString *romfs = romfs_locate();
    if (!romfs) {
        romfs_identity_report(NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]);
        fprintf(stderr, "boot: game files not found; copy a matching RomFS image or unpacked romfs folder to Documents and restart\n"); return 0;
    }
    fprintf(stderr, "boot: game files %s\n", romfs.fileSystemRepresentation);
    setenv("DM_ROMFS", romfs.fileSystemRepresentation, 0);
    char aoc[PATH_MAX]; const char *configured_aoc = getenv("DM_AOC_DIR");
    NSString *bundled_aoc = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"aoc"];
    if (!configured_aoc || !strcmp(configured_aoc, bundled_aoc.fileSystemRepresentation)) {
        if (romfs_image_aoc_path(romfs.fileSystemRepresentation, aoc, sizeof aoc))
            setenv("DM_AOC_DIR", aoc, 1);   // the combined image precedes legacy bundled copies
        else {
            NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
            NSString *folder_aoc = [doc stringByAppendingPathComponent:@"game-data/aoc"]; BOOL directory = NO;
            if ([NSFileManager.defaultManager fileExistsAtPath:folder_aoc isDirectory:&directory] && directory)
                setenv("DM_AOC_DIR", folder_aoc.fileSystemRepresentation, 1);   // combined image, then imported DLC, then bundled DLC
        }
    }   // an explicit different DM_AOC_DIR, including empty, remains authoritative
    dm_host_preload_start(g_argc, g_argv);
    g_boot_ok = 1;
    return 1;
}

// Boot prerequisites (done before UIApplicationMain): directories / environment variables / log -- the host's early load reads these
// Why a slim build found no usable game files: the verdict on Documents/romfs.img (the first of romfs_document_images), in the log and for the screen (front_ios_boot_message). NULL when the build has no romfs.id
static char g_boot_message[640];
const char *front_ios_boot_message(void) { return g_boot_message[0] ? g_boot_message : NULL; }
static void romfs_identity_report(NSString *doc) {
    romfs_id want, got;
    int rc = romfs_id_check([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"romfs.id"].fileSystemRepresentation,
                            (romfs_document_images(doc).firstObject ?: [doc stringByAppendingPathComponent:@"romfs.img"]).fileSystemRepresentation, &want, &got);
    if (rc == ROMFS_ID_OK || rc == ROMFS_ID_NONE) return;
    romfs_id_message(rc, &want, &got, NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "<bundle ID>", g_boot_message, sizeof g_boot_message);
    fprintf(stderr, "[RED] boot: %s\n", g_boot_message);
}

static int boot_env(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    NSString *res = NSBundle.mainBundle.resourcePath;
    for (NSString *d in @[@"save", @"temp"]) [fm createDirectoryAtPath:[doc stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
    // Keep game files and scratch data out of device backups (Documents is backed up by default; a RomFS placed there is many GB). Saves, logs and the pipeline list stay in the backup
    for (NSString *d in [@[@"romfs", @"aoc", @"game-data", @"temp"] arrayByAddingObjectsFromArray:[romfs_document_images(doc) valueForKey:@"lastPathComponent"]]) {
        NSURL *u = [NSURL fileURLWithPath:[doc stringByAppendingPathComponent:d]]; NSError *e = nil;
        if ([fm fileExistsAtPath:u.path] && ![u setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&e]) fprintf(stderr, "boot: %s could not be excluded from backup: %s\n", d.UTF8String, e.localizedDescription.UTF8String);
    }
    // Log: the host only writes to stderr; redirect it to Documents/log.txt (the previous one is kept as log.prev.txt), retrieve it from the Files app when something goes wrong
    NSString *log = [doc stringByAppendingPathComponent:@"log.txt"], *prev = [doc stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil]; [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) setvbuf(stderr, NULL, _IOLBF, 0);
    // Environment switch files (for on-device diagnostics: a sideloaded app cannot be given environment variables from outside): one KEY=VALUE per line, # starts a comment; Documents/env.txt takes precedence over dm/env.txt in the bundle (put there by build_ipa.sh's DM_ENV_FILE)
    NSMutableArray<NSString *> *from_file = [NSMutableArray array], *from_launch = [NSMutableArray array];
    for (char **e = environ; *e; e++) {   // set at launch (Xcode, devicectl): before the env files, and the launcher keeps them
        const char *eq = strchr(*e, '='); NSString *k = eq && !strncmp(*e, "DM_", 3) ? [[NSString alloc] initWithBytes:*e length:(NSUInteger)(eq - *e) encoding:NSUTF8StringEncoding] : nil;
        if (k) [from_launch addObject:k];
    }
#if DM_PLAYER_BUILD
    // Player-facing choices belong to the launcher, including saved choices.
    // Neither old diagnostic files nor bundled defaults may lock those rows.
    NSMutableSet<NSString *> *launcher_keys = [NSMutableSet set];
    NSData *settings_data = [NSData dataWithContentsOfFile:[res stringByAppendingPathComponent:@"dm/launcher.json"]];
    NSDictionary *settings_file = settings_data ? [NSJSONSerialization JSONObjectWithData:settings_data options:0 error:nil] : nil;
    for (NSDictionary *row in settings_file[@"settings"]) if ([row[@"env"] isKindOfClass:NSString.class]) [launcher_keys addObject:row[@"env"]];
#endif
    for (NSString *ef in @[[doc stringByAppendingPathComponent:@"env.txt"], [[res stringByAppendingPathComponent:@"dm"] stringByAppendingPathComponent:@"env.txt"]]) {
        NSString *txt = [NSString stringWithContentsOfFile:ef encoding:NSUTF8StringEncoding error:nil];
        for (NSString *raw in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *ln = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; NSRange eq = [ln rangeOfString:@"="];
            if (!ln.length || [ln hasPrefix:@"#"] || eq.location == NSNotFound || !eq.location) continue;
            NSString *k = [ln substringToIndex:eq.location], *v = [ln substringFromIndex:eq.location + 1];
#if DM_PLAYER_BUILD
            if (dm_player_diagnostic_key(k.UTF8String) || [launcher_keys containsObject:k] ||
                ([launcher_keys containsObject:@"DM_METAL_HUD"] && [k isEqualToString:@"MTL_HUD_ENABLED"])) continue;
#endif
            if (!getenv(k.UTF8String)) { setenv(k.UTF8String, v.UTF8String, 0); [from_file addObject:k]; fprintf(stderr, "boot: env %s=%s (%s)\n", k.UTF8String, v.UTF8String, ef.lastPathComponent.UTF8String); }
        }
    }
    setenv("DM_ENV_FILE_KEYS", [from_file componentsJoinedByString:@" "].UTF8String, 1);   // the launcher keeps what an env file set (LauncherSettings.swift)
    setenv("DM_ENV_LAUNCH_KEYS", [from_launch componentsJoinedByString:@" "].UTF8String, 1);   // and what the launch environment set (docs/frontends.md, Saved choices)
    front_hud_env();   // before the early loading below can make a device
    // Game language (nn::oe::GetDesiredLanguage, hle_oe.c): the one the IPA was packed with (the NSP script's LANGUAGE / --language → DMLanguage in Info.plist), unless an env file sets DM_LANG
    // (or the launcher, which replaces this default before the game starts)
    NSString *lang = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMLanguage"];
    if (!getenv("DM_LANG") && [lang isKindOfClass:NSString.class] && lang.length) setenv("DM_LANG", lang.UTF8String, 0);
    fprintf(stderr, "boot: game language %s\n", getenv("DM_LANG") ?: "en-US");
    setenv("DM_SAVE", [doc stringByAppendingPathComponent:@"save"].fileSystemRepresentation, 0);
    setenv("DM_TEMP", [doc stringByAppendingPathComponent:@"temp"].fileSystemRepresentation, 0);
    NSString *dm = [res stringByAppendingPathComponent:@"dm"];
    setenv("DM_NVN_SHMAP", [dm stringByAppendingPathComponent:@"shader_map.tsv"].fileSystemRepresentation, 0);
    setenv("DM_MSL_DIR", [res stringByAppendingPathComponent:@"msl"].fileSystemRepresentation, 0);
    setenv("DM_FONT_DIR", [dm stringByAppendingPathComponent:@"font"].fileSystemRepresentation, 0);   // Shared-font stand-ins (standard.ttf / nintendo_ext.ttf): iOS lacks the macOS font path
    NSString *aoc = [res stringByAppendingPathComponent:@"aoc"];   // add-on content: build_ipa.sh puts the RomFS extracted from the player's DLC NSPs at <App>/aoc/<index>/
    if ([fm fileExistsAtPath:aoc]) setenv("DM_AOC_DIR", aoc.fileSystemRepresentation, 0);
    NSString *pso = [res stringByAppendingPathComponent:@"pso"];   // the pipeline archive made offline (build_ipa.sh, dm/gfx/tools/pso_offline.py): the shader pairs' bases, which the device then does not build
    if ([fm fileExistsAtPath:pso]) setenv("DM_PSO_BUNDLE", pso.fileSystemRepresentation, 0);
    chdir(doc.fileSystemRepresentation);
    g_argv[0] = strdup("dmhost"); g_argv[1] = strdup(dm.fileSystemRepresentation); g_argc = 2;
    return front_ios_prepare_game();   // Preload early when files are ready; otherwise the game-files screen imports or rechecks them.
}

static void *boot_thread(void *p) {
    (void)p;
    static char alt[65536]; stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);   // crash printing must work on the host thread too
    int rc = dm_main(g_argc, g_argv);
    fprintf(stderr, "boot: dm_main returned %d\n", rc);
    return NULL;
}
void front_ios_boot(void) {   // Called by front_ios.m once the window and Metal view exist
    static int once; if (once++ || !g_boot_ok) return;
    void front_ios_audio_session(void); front_ios_audio_session();   // set a short I/O buffer before the game opens audio output (front_ios.m)
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);   // the Switch main thread stack is set by npdm; the host gives plenty
    pthread_t t; pthread_create(&t, &a, boot_thread, NULL); pthread_detach(t);
}
int front_ios_boot_ok(void) { return g_boot_ok; }

@interface App : UIResponder <UIApplicationDelegate>
@end
@implementation App
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application; (void)window;
    const char *enabled=getenv("DM_BOTW_PORTRAIT");
    return !strcmp(DM_GAME_ID,"01007EF00011E000") && enabled && !strcmp(enabled,"1") ?
        UIInterfaceOrientationMaskLandscape | UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscape;
}
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
}
@end

// Scene lifecycle: create the window + hand focus events to front_ios.m
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = front_ios_root();
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)s { front_ios_focus_event(0); }
- (void)sceneDidEnterBackground:(UIScene *)s { front_ios_focus_event(1); }
- (void)sceneWillEnterForeground:(UIScene *)s { front_ios_focus_event(2); }
- (void)sceneDidBecomeActive:(UIScene *)s { front_ios_focus_event(3); }
- (void)windowScene:(UIWindowScene *)scene didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previous {
    (void)previous;
    dm_gamepad_geometry_changed(scene.effectiveGeometry.interfaceOrientation);
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { g_boot_ok = boot_env(); }
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
