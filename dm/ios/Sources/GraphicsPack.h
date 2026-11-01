// Runtime graphics packages: stored ZIP imports, compatibility and selection.
#import <Foundation/Foundation.h>

NSString *dm_graphics_manifest_error(NSDictionary *manifest, NSDictionary *required);
BOOL dm_import_graphics_package(NSURL *source, NSURL *documents, NSDictionary *required,
                                void (^progress)(long long, long long), NSError **error);
NSString *dm_graphics_status(NSURL *documents, NSURL *bundle);
// When graphics are missing, find the sole valid, compatible graphics ZIP in Documents.
NSURL *dm_graphics_pending_package(NSURL *documents, NSURL *bundle, NSError **error);
BOOL dm_graphics_configure(NSURL *documents, NSURL *bundle, NSError **error);
NSDictionary *dm_graphics_requirements(NSURL *bundle);
NSDictionary *dm_graphics_current_info(NSURL *documents, NSURL *bundle, NSError **error);
