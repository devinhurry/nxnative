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
BOOL dm_startup_prepare(void) {
    NSURL *doc=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    return !dm_startup_rom_error() && dm_graphics_configure(doc,NSBundle.mainBundle.resourceURL,nil);
}
