// Copy a picked image directly, validating before publication. No archive extraction or game-file migration.
#import "GameFiles.h"
#include <errno.h>
#include <stdio.h>

static NSError *image_error(NSString *message) {
    return [NSError errorWithDomain:@"nxnative.game-files" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

BOOL dm_import_game_image(NSURL *source, NSURL *documents, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *destination = [documents URLByAppendingPathComponent:@"romfs.img"];
    NSURL *staging = [documents URLByAppendingPathComponent:@".romfs-import.img"];
    if ([source.URLByStandardizingPath isEqual:staging.URLByStandardizingPath]) {
        if (error) *error = image_error(NSLocalizedString(@"Choose the original .img file, not an unfinished import.", nil));
        return NO;
    }
    BOOL scoped = [source startAccessingSecurityScopedResource];
    __block NSError *failure = nil;
    __block BOOL imported = NO;
    NSError *coordination_error = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&coordination_error byAccessor:^(NSURL *readable) {
        NSString *invalid = front_ios_game_image_error(readable.path);
        if (invalid) { failure = image_error(invalid); return; }
        if ([readable.URLByStandardizingPath isEqual:destination.URLByStandardizingPath]) { imported = YES; return; }
        if ([fm fileExistsAtPath:staging.path] && ![fm removeItemAtURL:staging error:&failure]) return;
        if (![fm copyItemAtURL:readable toURL:staging error:&failure]) { [fm removeItemAtURL:staging error:nil]; return; }
        invalid = front_ios_game_image_error(staging.path);
        if (invalid) failure = image_error(invalid);
        if (!failure) [staging setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:&failure];
        if (!failure && rename(staging.fileSystemRepresentation, destination.fileSystemRepresentation))
            failure = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        if (failure) [fm removeItemAtURL:staging error:nil];
        else imported = YES;   // rename replaces the old image only after the new copy is complete and accepted
    }];
    if (scoped) [source stopAccessingSecurityScopedResource];
    if (error) *error = failure ?: coordination_error;
    return imported;
}
