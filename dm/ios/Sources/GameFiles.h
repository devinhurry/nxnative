// Missing-game-data screen and image import. Existing unpacked folders need no conversion.
#import <Foundation/Foundation.h>

NSString *front_ios_game_image_error(NSString *path);   // nil only for a complete image accepted by this app
BOOL dm_import_game_image(NSURL *source, NSURL *documents, NSError **error);
void dm_show_game_files(void *view_controller, void (*done)(void));
