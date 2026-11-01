// Startup resource checks and ROM import. Existing unpacked folders need no conversion.
#import <Foundation/Foundation.h>

NSString *front_ios_game_image_error(NSString *path);   // nil only for a complete image accepted by this app
BOOL dm_import_game_image(NSURL *source, NSURL *documents, NSError **error);
NSString *dm_startup_rom_error(void);
int dm_startup_dlc_count(void);
NSString *dm_startup_graphics_error(void);
BOOL dm_startup_prepare(void);
