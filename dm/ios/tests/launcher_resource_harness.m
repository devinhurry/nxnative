// Resource bridges for the isolated production-launcher simulator fixture.
// It never loads a game; ROM images use the production index validator and
// graphics packages use the complete production importer and selector.
#import <Foundation/Foundation.h>
#import "GameFiles.h"
#import "GraphicsPack.h"
#include "romfs_image.h"

NSString *front_ios_game_image_error(NSString *path) {
    romfs_img *image=romfs_image_open(path.fileSystemRepresentation);
    if (!image) return @"Invalid fixture ROM image.";
    romfs_image_close(image); return nil;
}
NSString *dm_startup_rom_error(void) {
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--require-rom"]) return nil;
    NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES)[0];
    NSString *path=[doc stringByAppendingPathComponent:@"RomFS.img"];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) path=[doc stringByAppendingPathComponent:@"romfs.img"];
    return front_ios_game_image_error(path) ? NSLocalizedString(@"Import RomFS.img to start.",nil) : nil;
}
NSString *dm_startup_graphics_error(void) {
    NSURL *doc=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    return dm_graphics_status(doc,NSBundle.mainBundle.resourceURL);
}
int dm_startup_dlc_count(void) { return 2; }
BOOL dm_startup_prepare(void) {
    NSURL *doc=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    return !dm_startup_rom_error() && dm_graphics_configure(doc,NSBundle.mainBundle.resourceURL,nil);
}

// Component fixture only: native host setters are covered by t_launcher_settings.
int dm_launcher_setting_is_live(const char *key) {
    return !strncmp(key, "DM_BOTW_", 8) || !strcmp(key, "DM_TOUCH_HAPTICS") || !strncmp(key, "DM_RUMBLE", 9);
}
int dm_launcher_setting_apply(const char *key, const char *value) {
    if (!dm_launcher_setting_is_live(key)) return 0;
    setenv(key, value, 1); return 1;
}
