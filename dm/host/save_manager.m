// Save collections for both Apple launchers. Foundation supplies JSON and copies;
// save_sync.c supplies the existing portable, checked save archive.
#import <Foundation/Foundation.h>
#include "save_manager.h"
#include "save_sync.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL sm_fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"nxnative.saves" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static NSString *sm_path(NSString *a, NSString *b) { return [a stringByAppendingPathComponent:b]; }
static BOOL sm_exists(NSString *p) { struct stat st; return !lstat(p.fileSystemRepresentation, &st); }
static BOOL sm_dir(NSString *p) { struct stat st; return !lstat(p.fileSystemRepresentation, &st) && S_ISDIR(st.st_mode); }
static BOOL sm_id(NSString *s) {
    return [s isKindOfClass:NSString.class] && s.UTF8String && ss_valid_slot_id(s.UTF8String) &&
        [s rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}
static BOOL sm_mkdir(NSString *p, NSError **error) {
    if (sm_exists(p)) return sm_dir(p) || sm_fail(error, [@"Expected a directory: " stringByAppendingString:p]);
    return [NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:error];
}
// Refuse links and special files before copying an external save. Do not follow
// a link out of a save, even when it looks like a folder to NSFileManager.
static BOOL sm_tree(NSString *p, NSError **error) {
    struct stat st;
    if (lstat(p.fileSystemRepresentation, &st)) return sm_fail(error, [@"Cannot read: " stringByAppendingString:p]);
    if (S_ISREG(st.st_mode)) return YES;
    if (!S_ISDIR(st.st_mode)) return sm_fail(error, [@"Links and special files are not allowed in saves: " stringByAppendingString:p]);
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:p error:error];
    if (!names) return NO;
    for (NSString *name in names) if (!sm_tree(sm_path(p,name),error)) return NO;
    return YES;
}
static NSDictionary *sm_json(NSString *p) {
    struct stat st;
    if (lstat(p.fileSystemRepresentation,&st) || !S_ISREG(st.st_mode) || st.st_size > 65536) return nil;
    NSData *data = [NSData dataWithContentsOfFile:p];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}
// Flush the new contents before publishing them. The temporary file stays on
// the destination volume, and an interrupted write leaves the previous file.
static BOOL sm_write(NSString *p, NSDictionary *obj, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    NSString *tmp = [p stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
    int fd = open(tmp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if (fd < 0) return sm_fail(error,[@"Cannot create metadata beside " stringByAppendingString:p]);
    BOOL ok = YES; size_t left = data.length; const char *bytes = data.bytes;
    while (left) {
        ssize_t n = write(fd,bytes,left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; }
        bytes += n; left -= (size_t)n;
    }
    if (ok && fsync(fd)) ok = NO;
    if (close(fd)) ok = NO;
    if (ok && rename(tmp.fileSystemRepresentation,p.fileSystemRepresentation)) ok = NO;
    if (!ok) { unlink(tmp.fileSystemRepresentation); return sm_fail(error,[@"Cannot save metadata: " stringByAppendingString:p]); }
    return YES;
}
static NSString *sm_base(NSString *root) { return sm_path(root,@"saves"); }
static NSString *sm_slot(NSString *root, NSString *slot) { return sm_path(sm_base(root),slot); }
static NSArray<NSString *> *sm_ids(NSString *folder) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil])
        if (sm_id(name) && sm_dir(sm_path(folder,name))) [ids addObject:name];
    return [ids sortedArrayUsingSelector:@selector(compare:)];
}
static BOOL sm_has_save(NSString *p) { return sm_dir(p) && (sm_dir(sm_path(p,@"save")) || sm_dir(sm_path(p,@"save_device"))); }
static NSArray<NSString *> *sm_slots(NSString *folder) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *slot in sm_ids(folder)) if (sm_has_save(sm_path(folder,slot)) || sm_json(sm_path(sm_path(folder,slot),@"info.json"))) [ids addObject:slot];
    return ids;
}
static NSString *sm_selection(NSString *root, NSString *name) {
    NSDictionary *obj = sm_json(sm_path(sm_base(root),name));
    id version = obj[@"version"], slot = obj[@"slot_id"];
    if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
        ![version isEqual:@1] || !sm_id(slot) || !sm_dir(sm_slot(root,slot))) return nil;
    return slot;
}
static BOOL sm_select(NSString *root, NSString *slot, NSError **error) {
    if (!sm_id(slot) || !sm_has_save(sm_slot(root,slot))) return sm_fail(error,@"The selected save does not exist.");
    NSString *old = sm_selection(root,@"current.json");
    if (old && !sm_write(sm_path(sm_base(root),@"current.json.bak"),@{@"version":@1,@"slot_id":old},error)) return NO;
    return sm_write(sm_path(sm_base(root),@"current.json"),@{@"version":@1,@"slot_id":slot},error);
}
static NSString *sm_current(NSString *root, NSError **error) {
    NSString *slot = sm_selection(root,@"current.json");
    if (slot) return slot;
    slot = sm_selection(root,@"current.json.bak");
    if (!slot) {
        NSArray *ids = sm_slots(sm_base(root));
        if (ids.count == 1) slot = ids[0];
    }
    if (slot) return sm_select(root,slot,error) ? slot : nil;
    sm_fail(error,@"No valid current save selection. List the saves and select one before starting the game.");
    return nil;
}
static NSDictionary *sm_info(NSString *title, NSString *name, NSString *source) {
    return @{@"version":@1,@"title_id":title,@"name":name,@"source":source,@"created_at":@((int64_t)NSDate.date.timeIntervalSince1970)};
}
static BOOL sm_name(NSString *name, NSError **error) {
    return ([name isKindOfClass:NSString.class] && name.length && [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 256 &&
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound) || sm_fail(error,@"Save names must contain 1 to 256 UTF-8 bytes without control characters.");
}
static int sm_lock(NSString *root, NSError **error) {
    if (!sm_mkdir(sm_base(root),error)) return -1;
    NSString *p = sm_path(sm_base(root),@".lock");
    // ponytail: one lock per game; split by slot if concurrent play is needed.
    // Keep it across exec so the Mac child still owns it if its launcher dies.
    int fd = open(p.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
    if (fd < 0 || flock(fd,LOCK_EX|LOCK_NB)) {
        if (fd >= 0) close(fd);
        sm_fail(error,@"This game's saves are in use. Close the game and other save operations first."); return -1;
    }
    return fd;
}
static BOOL sm_publish(NSString *root, NSString *stage, NSString *slot, NSError **error) {
    return renamex_np(stage.fileSystemRepresentation,sm_slot(root,slot).fileSystemRepresentation,RENAME_EXCL) == 0 ||
        sm_fail(error,@"Cannot publish the completed save; the staged data has been kept.");
}
// Move the old components into a persistent staging directory, then publish the
// entire slot. Each move resumes after interruption, including the device save
// and old sync records. A downgrade's recreated save becomes a separate recovery
// slot rather than overwriting a different save in the new collection.
static BOOL sm_migrate(NSString *root, NSString *title, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *stage = sm_path(sm_base(root),@"staging/legacy");
    NSArray *parts = @[@"save",@"save_device",@"save.sync",@"save-backups"];
    BOOL legacy = sm_exists(stage);
    for (NSString *part in parts) legacy |= sm_exists(sm_path(root,part));
    if (!legacy) return YES;
    if (!sm_mkdir(stage,error)) return NO;
    NSString *journal = sm_path(stage,@"migration.json");
    NSDictionary *state = sm_json(journal);
    NSString *slot = state[@"slot_id"];
    if (state && (!sm_id(slot) || ![state[@"title_id"] isEqual:title])) return sm_fail(error,@"The interrupted legacy save migration has invalid metadata; its data has been kept.");
    if (!state) {
        if (sm_exists(journal)) return sm_fail(error,@"The legacy save migration metadata is damaged; its data has been kept.");
        slot = sm_exists(sm_slot(root,@"default")) ? NSUUID.UUID.UUIDString.lowercaseString : @"default";
        if (!slot) return sm_fail(error,@"Cannot allocate a save ID.");
        if (!sm_write(journal,@{@"slot_id":slot,@"title_id":title},error)) return NO;
    }
    for (NSString *part in parts) {
        NSString *from = sm_path(root,part), *to = sm_path(stage,part);
        if (!sm_exists(from) || sm_exists(to)) continue;
        if (!sm_tree(from,error) || ![fm moveItemAtPath:from toPath:to error:error]) return NO;
    }
    // A recovered downgrade save has a new cloud identity. Its old baseline
    // refers to the legacy file and must not suppress its first independent send.
    NSString *sync = sm_path(stage,@"save.sync");
    if (![slot isEqual:@"default"] && sm_exists(sync) &&
        ![fm moveItemAtPath:sync toPath:sm_path(stage,@"legacy.sync") error:error]) return NO;
    if (!sm_mkdir(sm_path(stage,@"save"),error) ||
        !sm_write(sm_path(stage,@"info.json"),sm_info(title,[slot isEqual:@"default"] ? @"Default" : @"Recovered legacy save",@"legacy"),error) ||
        !sm_publish(root,stage,slot,error)) return NO;
    return YES;
}
static BOOL sm_init(NSString *root, NSString *title, NSError **error) {
    NSString *base = sm_base(root);
    for (NSString *name in @[@"staging",@"trash"])
        if (!sm_mkdir(sm_path(base,name),error)) return NO;
    // Rename whole entries from the original layout. Preflight all collisions;
    // interruption can resume without changing IDs or their cloud histories.
    NSString *old = sm_path(base,@"slots");
    if (sm_exists(old) && !sm_dir(old)) return sm_fail(error,@"The old saves/slots path must be a real directory.");
    NSArray *oldIDs = sm_ids(old);
    for (NSString *slot in oldIDs) if (sm_exists(sm_slot(root,slot)))
        return sm_fail(error,[@"A save exists in both saves/ and saves/slots/: rename the custom folder before retrying: " stringByAppendingString:slot]);
    for (NSString *slot in oldIDs)
        if (![NSFileManager.defaultManager moveItemAtPath:sm_path(old,slot) toPath:sm_slot(root,slot) error:error]) return NO;
    BOOL empty = sm_slots(base).count == 0;
    if (!sm_migrate(root,title,error)) return NO;
    // Always retain the fixed compatibility entry, even when custom folders
    // were dropped into saves/ before the first launch.
    BOOL madeDefault = !sm_exists(sm_slot(root,@"default"));
    if (madeDefault) {
        NSString *stage = sm_path(base,[@"staging/" stringByAppendingString:NSUUID.UUID.UUIDString]);
        if (!sm_mkdir(sm_path(stage,@"save"),error) || !sm_write(sm_path(stage,@"info.json"),sm_info(title,@"Default",@"new"),error) ||
            !sm_publish(root,stage,@"default",error)) return NO;
    }
    if ((empty || madeDefault) && !sm_selection(root,@"current.json") && !sm_exists(sm_path(base,@"current.json")) && !sm_exists(sm_path(base,@"current.json.bak")))
        return sm_select(root,@"default",error);
    return YES;
}
// Enumeration uses the provider's local directory listing. Actual save contents
// are fetched, coordinated and checked by save_sync.c on first mount. There is
// no cloud current.json, and a locally deleted slot stays suppressed in trash.
static int sm_discover(NSString *root, NSString *title, NSError **error) {
    char cloud[PATH_MAX]; NSString *save = sm_path(sm_slot(root,@"default"),@"save");
    if (!ss_cloud_file(save.fileSystemRepresentation,title.UTF8String,cloud,sizeof cloud)) return 0;
    NSString *archive = @(cloud);
    NSString *placeholder = sm_path(archive.stringByDeletingLastPathComponent,[@"." stringByAppendingFormat:@"%@.icloud",archive.lastPathComponent]);
    ss_meta local;
    if (ss_scan(save.fileSystemRepresentation,&local)) { sm_fail(error,@"Cannot inspect the default save before cloud discovery."); return -1; }
    if (!local.files && (sm_exists(archive) || sm_exists(placeholder))) {
        NSString *pending = sm_path(sm_slot(root,@"default"),@"cloud-pending");
        if (!sm_exists(pending) && !sm_write(pending,@{@"version":@1},error)) return -1;
    }
    NSString *folder = sm_path(archive.stringByDeletingLastPathComponent,@"slots");
    int added = 0;
    for (NSString *slot in sm_ids(folder)) {
        if ([slot isEqual:@"default"] || sm_exists(sm_slot(root,slot)) || sm_exists(sm_path(sm_path(sm_base(root),@"trash"),slot))) continue;
        NSString *remote = sm_path(folder,slot);
        if (!sm_exists(sm_path(remote,@"save.dmsync")) && !sm_exists(sm_path(remote,@".save.dmsync.icloud"))) continue;
        NSString *stage = sm_path(sm_base(root),[@"staging/" stringByAppendingString:NSUUID.UUID.UUIDString]);
        NSString *name = [[NSUUID alloc] initWithUUIDString:slot] ? [@"Cloud save " stringByAppendingString:[slot substringToIndex:8]] : slot;
        if (!sm_mkdir(sm_path(stage,@"save"),error) || !sm_write(sm_path(stage,@"cloud-pending"),@{@"version":@1},error) ||
            !sm_write(sm_path(stage,@"info.json"),sm_info(title,name,@"cloud"),error) ||
            !sm_publish(root,stage,slot,error)) return -1;
        added++;
    }
    return added;
}
static BOOL sm_ready(NSString *slot, NSString *title, NSError **error) {
    NSDictionary *info = sm_json(sm_path(slot,@"info.json"));
    if (info[@"title_id"] && ![info[@"title_id"] isEqual:title]) return sm_fail(error,@"This save belongs to a different game.");
    for (NSString *part in @[@"save",@"save_device"]) {
        NSString *p = sm_path(slot,part);
        if (sm_exists(p) && !sm_dir(p)) return sm_fail(error,[@"The committed save must be a directory: " stringByAppendingString:p]);
        if (sm_exists(p) && !sm_tree(p,error)) return NO;
    }
    return ss_prepare_pending(sm_path(slot,@"save").fileSystemRepresentation,title.UTF8String) ||
        sm_fail(error,@"This save exists in the cloud but has not downloaded yet. Connect to iCloud and retry; its existing progress has been kept.");
}
static BOOL sm_copy_data(NSString *from, NSString *stage, NSError **error) {
    for (NSString *part in @[@"save",@"save_device"]) {
        NSString *p = sm_path(from,part);
        if (sm_exists(p) && (!sm_tree(p,error) || ![NSFileManager.defaultManager copyItemAtPath:p toPath:sm_path(stage,part) error:error])) return NO;
    }
    return sm_mkdir(sm_path(stage,@"save"),error);
}
static void sm_stats(NSString *path, uint64_t *bytes, uint64_t *files, int64_t *saved) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation,&st)) return;
    if (S_ISREG(st.st_mode)) { *bytes += (uint64_t)st.st_size; (*files)++; if (st.st_mtime > *saved) *saved = st.st_mtime; }
    else if (S_ISDIR(st.st_mode)) for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]) sm_stats(sm_path(path,name),bytes,files,saved);
}
static NSArray *sm_listing(NSString *folder) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *slot in sm_slots(folder)) {
        NSString *p = sm_path(folder,slot); NSDictionary *info = sm_json(sm_path(p,@"info.json"));
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:info ?: @{}];
        item[@"id"] = slot; item[@"path"] = p;
        if (![item[@"name"] isKindOfClass:NSString.class]) item[@"name"] = slot;
        if ([slot isEqual:@"default"] && !info) item[@"name"] = @"Default";
        uint64_t bytes = 0, files = 0; int64_t saved = 0;
        for (NSString *part in @[@"save",@"save_device"]) sm_stats(sm_path(p,part),&bytes,&files,&saved);
        item[@"bytes"] = @(bytes); item[@"files"] = @(files); item[@"saved_at"] = @(saved);
        item[@"cloud_pending"] = @(sm_exists(sm_path(p,@"cloud-pending")));
        [items addObject:item];
    }
    return items;
}
static NSDictionary *sm_operate(NSString *root, NSString *title, NSString *cmd, NSString *a, NSString *b, NSError **error) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = sm_base(root);
    if ([cmd isEqual:@"list"] || [cmd isEqual:@"inspect"]) {
        NSError *selectionError = nil;
        NSString *current = [cmd isEqual:@"inspect"] ? (sm_selection(root,@"current.json") ?: sm_selection(root,@"current.json.bak")) : sm_current(root,&selectionError);
        return @{@"current":current ?: (id)NSNull.null,@"selection_error":selectionError.localizedDescription ?: (id)NSNull.null,
            @"slots":sm_listing(base),@"trash":sm_listing(sm_path(base,@"trash"))};
    }
    if ([cmd isEqual:@"refresh"]) {
        int n = sm_discover(root,title,error);
        return n < 0 ? nil : @{@"discovered":@(n)};
    }
    if ([cmd isEqual:@"create"] || [cmd isEqual:@"copy"] || [cmd isEqual:@"import"] || [cmd isEqual:@"import-raw"]) {
        NSString *slot = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *stage = sm_path(sm_path(base,@"staging"),slot);
        NSString *name = [cmd isEqual:@"create"] ? a : b;
        if (!name.length) name = [cmd hasPrefix:@"import"] ? a.lastPathComponent.stringByDeletingPathExtension : @"Copy";
        if (!sm_name(name,error) || !sm_mkdir(stage,error)) return nil;
        BOOL ok = YES;
        if ([cmd isEqual:@"copy"]) {
            if (!sm_id(a) || !sm_dir(sm_slot(root,a))) ok = sm_fail(error,@"The source save does not exist.");
            else ok = sm_ready(sm_slot(root,a),title,error) && sm_copy_data(sm_slot(root,a),stage,error);
        } else if ([cmd hasPrefix:@"import"]) {
            NSString *source = a.stringByStandardizingPath;
            if (!source.isAbsolutePath || [stage hasPrefix:[source.stringByResolvingSymlinksInPath stringByAppendingString:@"/"]] || !sm_tree(source,error)) ok = sm_fail(error,@"Choose a save archive or directory outside the staging directory.");
            else if (sm_dir(source)) {
                if ([cmd isEqual:@"import-raw"]) ok = [fm copyItemAtPath:source toPath:sm_path(stage,@"save") error:error];
                else if (sm_dir(sm_path(source,@"save")) || sm_dir(sm_path(source,@"save_device"))) {
                    NSDictionary *info = sm_json(sm_path(source,@"info.json"));
                    if (info[@"title_id"] && ![info[@"title_id"] isEqual:title]) ok = sm_fail(error,@"The save folder belongs to a different game.");
                    else if (sm_exists(sm_path(source,@"cloud-pending"))) ok = sm_fail(error,@"Download this cloud save before importing its directory.");
                    else ok = sm_copy_data(source,stage,error);
                }
                else ok = sm_fail(error,@"This folder is not a save collection entry. Use import --raw for a folder of game save files.");
            } else if ([cmd isEqual:@"import-raw"]) ok = sm_fail(error,@"A raw save must be a directory.");
            else {
                ss_meta meta;
                if (ss_read(source.fileSystemRepresentation,stage.fileSystemRepresentation,&meta)) ok = sm_fail(error,@"The save archive is damaged or has invalid paths.");
                else if (strcasecmp(meta.title,title.UTF8String)) ok = sm_fail(error,@"The save archive belongs to a different game.");
            }
        }
        if (ok) ok = sm_mkdir(sm_path(stage,@"save"),error) && sm_write(sm_path(stage,@"info.json"),sm_info(title,name,cmd),error) && sm_publish(root,stage,slot,error);
        if (!ok) { [fm removeItemAtPath:stage error:nil]; return nil; }
        return @{@"id":slot,@"path":sm_slot(root,slot)};
    }
    if (!sm_id(a)) { sm_fail(error,@"Invalid save ID."); return nil; }
    NSString *slot = sm_slot(root,a);
    if ([cmd isEqual:@"restore"]) {
        NSString *from = sm_path(sm_path(base,@"trash"),a);
        if (!sm_dir(from) || sm_exists(slot) || !sm_tree(from,error) || ![fm moveItemAtPath:from toPath:slot error:error]) { if (!error || !*error) sm_fail(error,@"The deleted save cannot be restored to that ID."); return nil; }
        return @{@"id":a};
    }
    if (!sm_dir(slot)) { sm_fail(error,@"The save does not exist."); return nil; }
    if ([cmd isEqual:@"select"]) return sm_select(root,a,error) ? @{@"current":a} : nil;
    if ([cmd isEqual:@"rename"]) {
        if (!sm_name(b,error)) return nil;
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithDictionary:sm_json(sm_path(slot,@"info.json")) ?: sm_info(title,a,@"recovered")];
        info[@"name"] = b;
        return sm_write(sm_path(slot,@"info.json"),info,error) ? @{@"id":a,@"name":b} : nil;
    }
    if ([cmd isEqual:@"delete"]) {
        if ([a isEqual:@"default"]) { sm_fail(error,@"The default save is reserved for compatibility with older apps and cannot be deleted."); return nil; }
        // An unreadable selection is never permission to remove a possibly active save.
        NSString *current = sm_current(root,error);
        if (!current) return nil;
        if ([current isEqual:a]) { sm_fail(error,@"Select another save before deleting the current one."); return nil; }
        return [fm moveItemAtPath:slot toPath:sm_path(sm_path(base,@"trash"),a) error:error] ? @{@"deleted":a} : nil;
    }
    if ([cmd isEqual:@"sync"]) {
        char cloud[PATH_MAX]; NSString *save = sm_path(slot,@"save");
        if (!ss_cloud_file(save.fileSystemRepresentation,title.UTF8String,cloud,sizeof cloud)) { sm_fail(error,@"Cloud saves are off. Choose a cloud folder first."); return nil; }
        if (sm_discover(root,title,error) < 0 || !sm_ready(slot,title,error)) return nil;
        save_sync_mount(save.fileSystemRepresentation,title.UTF8String);
        if (!save_sync_active() || !save_sync_flush(20000)) { sm_fail(error,@"The save has not reached the cloud. Keep the local save and retry when the cloud folder is available."); return nil; }
        return @{@"id":a,@"cloud":@(cloud)};
    }
    if ([cmd isEqual:@"export"]) {
        NSString *dest = b.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (!dest.isAbsolutePath || sm_exists(dest) || [dest hasPrefix:[base stringByAppendingString:@"/"]]) { sm_fail(error,@"Choose a new export file outside the managed saves directory."); return nil; }
        NSString *temp = [dest stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
        ss_meta meta; NSString *save = sm_path(slot,@"save");
        if (!sm_ready(slot,title,error)) return nil;
        for (NSString *part in @[@"save",@"save_device"]) {
            NSString *data = sm_path(slot,part);
            if (sm_exists(data) && !sm_tree(data,error)) return nil;
        }
        if (ss_pack(save.fileSystemRepresentation,title.UTF8String,temp.fileSystemRepresentation,&meta)) { sm_fail(error,@"Cannot write the save archive."); return nil; }
        if (renamex_np(temp.fileSystemRepresentation,dest.fileSystemRepresentation,RENAME_EXCL)) { unlink(temp.fileSystemRepresentation); sm_fail(error,@"Cannot publish the export without replacing an existing file."); return nil; }
        return @{@"id":a,@"file":dest};
    }
    sm_fail(error,@"Unknown save command."); return nil;
}
static BOOL sm_arguments(const char *root, const char *title, NSError **error) {
    if (!root || !*root || ![@(root) isAbsolutePath] || !title || strlen(title) != 16 || strspn(title,"0123456789abcdefABCDEF") != 16)
        return sm_fail(error,@"Provide an absolute game data root and a 16-digit hexadecimal title ID.");
    return YES;
}
static void sm_error(NSError *error, char *out, size_t n) {
    if (out && n) snprintf(out,n,"%s",error.localizedDescription.UTF8String ?: "Save operation failed.");
}
int dm_saves_prepare(const char *root, const char *title, char *save, size_t size, int *lock_fd, char *error, size_t error_size) {
    @autoreleasepool {
        NSError *failure = nil; int fd = -1;
        if (lock_fd) *lock_fd = -1;
        if (error && error_size) *error = 0;
        if (!save || !size || !lock_fd || !sm_arguments(root,title,&failure)) { sm_error(failure,error,error_size); return -1; }
        NSString *r = [@(root) stringByStandardizingPath].stringByResolvingSymlinksInPath, *t = [@(title) uppercaseString];
        if (!r || !t) { sm_fail(&failure,@"The save root and title ID must be valid UTF-8."); sm_error(failure,error,error_size); return -1; }
        fd = sm_lock(r,&failure);
        if (fd >= 0 && sm_init(r,t,&failure) && sm_discover(r,t,&failure) >= 0) {
            NSString *current = sm_current(r,&failure);
            if (current && sm_ready(sm_slot(r,current),t,&failure)) {
                NSString *p = sm_path(sm_slot(r,current),@"save");
                if (strlcpy(save,p.fileSystemRepresentation,size) < size) { *lock_fd = fd; return 0; }
                sm_fail(&failure,@"The save path is too long.");
            }
        }
        if (fd >= 0) close(fd);
        sm_error(failure,error,error_size); return -1;
    }
}
char *dm_saves_command(const char *root, const char *title, const char *command, const char *arg1, const char *arg2, char *error, size_t error_size) {
    @autoreleasepool {
        NSError *failure = nil; int fd = -1; NSDictionary *result = nil;
        if (error && error_size) *error = 0;
        if (!command || !sm_arguments(root,title,&failure)) { sm_error(failure,error,error_size); return NULL; }
        NSString *r = [@(root) stringByStandardizingPath].stringByResolvingSymlinksInPath, *t = [@(title) uppercaseString];
        NSString *c = @(command), *a = arg1 ? @(arg1) : @"", *b = arg2 ? @(arg2) : @"";
        if (!r || !t || !c || !a || !b) { sm_fail(&failure,@"Save command arguments must be valid UTF-8."); sm_error(failure,error,error_size); return NULL; }
        if ([c isEqual:@"inspect"]) result = sm_operate(r,t,c,a,b,&failure);
        else {
            fd = sm_lock(r,&failure);
            if (fd >= 0 && sm_init(r,t,&failure)) result = sm_operate(r,t,c,a,b,&failure);
        }
        NSData *json = result ? [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&failure] : nil;
        if (fd >= 0) close(fd);
        if (!json) { sm_error(failure,error,error_size); return NULL; }
        char *out = strndup(json.bytes,json.length);
        if (!out) { sm_fail(&failure,@"Cannot allocate the save command result."); sm_error(failure,error,error_size); }
        return out;
    }
}
