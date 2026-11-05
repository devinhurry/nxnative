// Save collections for both Apple launchers. Foundation supplies JSON and copies;
// libarchive supplies portable ZIP exports; save_sync.c retains the legacy wire format.
#import <Foundation/Foundation.h>
#include "save_manager.h"
#include "save_sync.h"
#include <dirent.h>
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

// Apple SDKs export libarchive without its headers, as in GraphicsPack.m.
// Use its public streaming API; never extract archive paths through a shell.
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_none(struct archive *);
extern int archive_read_support_format_zip_seekable(struct archive *);
extern int archive_read_support_format_7zip(struct archive *);
extern int archive_read_support_format_rar(struct archive *);
extern int archive_read_support_format_rar5(struct archive *);
extern int archive_read_set_format_option(struct archive *, const char *, const char *, const char *);
extern int archive_read_open_filename(struct archive *, const char *, size_t);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern ssize_t archive_read_data(struct archive *, void *, size_t);
extern int archive_read_free(struct archive *);
extern const char *archive_error_string(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern int64_t archive_entry_size(struct archive_entry *);
extern unsigned int archive_entry_filetype(struct archive_entry *);
extern const char *archive_entry_symlink(struct archive_entry *);
extern const char *archive_entry_hardlink(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);
extern time_t archive_entry_mtime(struct archive_entry *);
extern long archive_entry_mtime_nsec(struct archive_entry *);
extern struct archive *archive_write_new(void);
extern int archive_write_set_format_zip(struct archive *);
extern int archive_write_zip_set_compression_deflate(struct archive *);
extern int archive_write_open_fd(struct archive *, int);
extern int archive_write_header(struct archive *, struct archive_entry *);
extern ssize_t archive_write_data(struct archive *, const void *, size_t);
extern int archive_write_close(struct archive *);
extern int archive_write_free(struct archive *);
extern struct archive_entry *archive_entry_new(void);
extern void archive_entry_copy_stat(struct archive_entry *, const struct stat *);
extern void archive_entry_set_pathname_utf8(struct archive_entry *, const char *);
extern void archive_entry_free(struct archive_entry *);

static const char *SM_GUEST_NAME = "org.d2rmobile.guest-name";

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
// Foundation hides ._* entries as AppleDouble sidecars. Game save names are
// literal, so validation and export must enumerate the actual filesystem.
static NSArray<NSString *> *sm_children(NSString *path, NSError **error) {
    DIR *dir = opendir(path.fileSystemRepresentation);
    if (!dir) { sm_fail(error,[@"Cannot read: " stringByAppendingString:path]); return nil; }
    NSMutableArray *names = [NSMutableArray array];
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            int failure = errno;
            closedir(dir);
            if (failure) { sm_fail(error,[@"Cannot read: " stringByAppendingString:path]); return nil; }
            return names;
        }
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name) { closedir(dir); sm_fail(error,@"A save file name is not valid UTF-8."); return nil; }
        [names addObject:name];
    }
}
// Refuse links and special files before copying an external save. Do not follow
// a link out of a save, even when it looks like a folder to NSFileManager.
static BOOL sm_tree(NSString *p, NSError **error) {
    struct stat st;
    if (lstat(p.fileSystemRepresentation, &st)) return sm_fail(error, [@"Cannot read: " stringByAppendingString:p]);
    if (S_ISREG(st.st_mode)) return YES;
    if (!S_ISDIR(st.st_mode)) return sm_fail(error, [@"Links and special files are not allowed in saves: " stringByAppendingString:p]);
    NSArray *names = sm_children(p,error);
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
// Once the journal exists, an interrupted batch finishes on the next launch.
// IDs are fresh and tagged, so recovery never replaces an unrelated save.
static BOOL sm_finish_import(NSString *root, NSString *job, NSString *title, NSError **error) {
    NSDictionary *journal = sm_json(sm_path(job,@"batch.json"));
    NSArray *ids = journal[@"ids"];
    if (![journal[@"version"] isEqual:@1] || ![journal[@"title_id"] isEqual:title] ||
        ![ids isKindOfClass:NSArray.class] || !ids.count || ids.count > 1000 || [NSSet setWithArray:ids].count != ids.count)
        return sm_fail(error,@"The interrupted import has invalid metadata. Its data has been kept.");
    for (id slot in ids) {
        if (!sm_id(slot) || ![[NSUUID alloc] initWithUUIDString:slot]) return sm_fail(error,@"The interrupted import has invalid metadata. Its data has been kept.");
        NSString *from = sm_path(sm_path(job,@"entries"),slot), *to = sm_slot(root,slot);
        NSString *existing = sm_exists(from) ? from : to;
        if ((sm_exists(from) && sm_exists(to)) || ![sm_json(sm_path(existing,@"info.json"))[@"import_batch"] isEqual:job.lastPathComponent] || !sm_has_save(existing) || !sm_tree(existing,error))
            return sm_fail(error,@"An interrupted import cannot be completed without replacing a save. Its data has been kept.");
    }
    NSMutableArray *published = [NSMutableArray array];
    for (NSString *slot in ids) {
        NSString *from = sm_path(sm_path(job,@"entries"),slot);
        if (!sm_exists(from)) continue;
        if (sm_publish(root,from,slot,error)) { [published addObject:slot]; continue; }
        for (NSString *done in published.reverseObjectEnumerator)
            renamex_np(sm_slot(root,done).fileSystemRepresentation,sm_path(sm_path(job,@"entries"),done).fileSystemRepresentation,RENAME_EXCL);
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtPath:job error:nil];
    return YES;
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
    NSString *staging = sm_path(base,@"staging");
    for (NSString *job in sm_ids(staging))
        if ([job hasPrefix:@"import-"] && sm_exists(sm_path(sm_path(staging,job),@"batch.json")) &&
            !sm_finish_import(root,sm_path(staging,job),title,error)) return NO;
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
// ZIP stores host spellings as ordinary files. Keep the guest-name attributes
// in JSON so imports and manually extracted folders also retain case collisions.
static BOOL sm_restore_names(NSDictionary *info, NSString *folder, NSError **error) {
    id names = info[@"guest_names"];
    if (!names) return YES;
    if (![names isKindOfClass:NSDictionary.class]) return sm_fail(error,@"The save's file-name metadata is invalid.");
    for (id key in names) {
        id encoded = names[key];
        if (![key isKindOfClass:NSString.class] || ![encoded isKindOfClass:NSString.class] ||
            [key isAbsolutePath] || ![[key stringByStandardizingPath] isEqual:key] || [key containsString:@"\\"] ||
            [key rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
            return sm_fail(error,@"The save's file-name metadata is invalid.");
        NSArray *parts = [key componentsSeparatedByString:@"/"];
        if (![@[@"save",@"save_device"] containsObject:parts.firstObject] || [parts containsObject:@".."] || [parts containsObject:@"."] || [parts containsObject:@""])
            return sm_fail(error,@"The save's file-name metadata is invalid.");
        NSData *value = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        NSString *path = sm_path(folder,key);
        if (!value.length || value.length > 1024 || !sm_exists(path) || !sm_tree(path,error))
            return sm_fail(error,@"The save's file-name metadata is invalid.");
    }
    for (NSString *key in names) {
        NSData *value = [[NSData alloc] initWithBase64EncodedString:names[key] options:0];
        if (setxattr(sm_path(folder,key).fileSystemRepresentation,SM_GUEST_NAME,value.bytes,value.length,0,XATTR_NOFOLLOW))
            return sm_fail(error,@"Cannot restore the save's original file names.");
    }
    return YES;
}
static BOOL sm_ready(NSString *slot, NSString *title, NSError **error) {
    NSDictionary *info = sm_json(sm_path(slot,@"info.json"));
    if (info[@"title_id"] && ![info[@"title_id"] isEqual:title]) return sm_fail(error,@"This save belongs to a different game.");
    for (NSString *part in @[@"save",@"save_device"]) {
        NSString *p = sm_path(slot,part);
        if (sm_exists(p) && !sm_dir(p)) return sm_fail(error,[@"The committed save must be a directory: " stringByAppendingString:p]);
        if (sm_exists(p) && !sm_tree(p,error)) return NO;
    }
    if (info[@"guest_names"]) {
        if (!sm_restore_names(info,slot,error)) return NO;
        NSMutableDictionary *restored = info.mutableCopy;
        [restored removeObjectForKey:@"guest_names"];
        if (!sm_write(sm_path(slot,@"info.json"),restored,error)) return NO;
    }
    return ss_prepare_pending(sm_path(slot,@"save").fileSystemRepresentation,title.UTF8String) ||
        sm_fail(error,@"This save exists in the cloud but has not downloaded yet. Connect to iCloud and retry; its existing progress has been kept.");
}
static BOOL sm_copy_tree(NSString *from, NSString *to, NSError **error) {
    if (!sm_dir(from)) return !copyfile(from.fileSystemRepresentation,to.fileSystemRepresentation,NULL,COPYFILE_ALL|COPYFILE_CLONE|COPYFILE_EXCL|COPYFILE_NOFOLLOW) || sm_fail(error,@"Cannot copy the save files.");
    if (!sm_mkdir(to,error)) return NO;
    NSArray *names = sm_children(from,error);
    if (!names) return NO;
    for (NSString *name in names) if (!sm_copy_tree(sm_path(from,name),sm_path(to,name),error)) return NO;
    return !copyfile(from.fileSystemRepresentation,to.fileSystemRepresentation,NULL,COPYFILE_METADATA|COPYFILE_NOFOLLOW) || sm_fail(error,@"Cannot preserve the save's file metadata.");
}
static BOOL sm_copy_data(NSString *from, NSString *stage, NSError **error) {
    for (NSString *part in @[@"save",@"save_device"]) {
        NSString *p = sm_path(from,part);
        if (sm_exists(p) && (!sm_tree(p,error) || !sm_copy_tree(p,sm_path(stage,part),error))) return NO;
    }
    return sm_mkdir(sm_path(stage,@"save"),error);
}

static BOOL sm_zip_tree(struct archive *writer, NSString *folder, NSString *relative, NSString *wrapper, NSMutableDictionary *names, uint64_t budget[2], NSError **error) {
    NSString *path = sm_path(folder,relative);
    NSString *archived = sm_path(wrapper,relative);
    struct stat st;
    if (lstat(path.fileSystemRepresentation,&st) || (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode)))
        return sm_fail(error,@"Cannot read the committed save for export.");
    if ([archived containsString:@"\\"] || [archived containsString:@":"] ||
        [archived rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        archived.pathComponents.count > 32 || [archived lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024 ||
        !budget[1] || (S_ISREG(st.st_mode) && (st.st_size < 0 || (uint64_t)st.st_size > budget[0])))
        return sm_fail(error,@"This save exceeds ZIP import limits. Export as .dmsync instead.");
    budget[1]--;
    if (S_ISREG(st.st_mode)) budget[0] -= (uint64_t)st.st_size;
    struct archive_entry *entry = archive_entry_new();
    if (!entry) return sm_fail(error,@"Cannot create the ZIP save archive.");
    archive_entry_copy_stat(entry,&st);
    archive_entry_set_pathname_utf8(entry,archived.UTF8String);
    int result = archive_write_header(writer,entry);
    archive_entry_free(entry);
    if (result != 0) return sm_fail(error,@"Cannot write the ZIP save archive.");
    char guest[1024];
    ssize_t length = getxattr(path.fileSystemRepresentation,SM_GUEST_NAME,guest,sizeof guest,0,XATTR_NOFOLLOW);
    if (length > 0) names[relative] = [[NSData dataWithBytes:guest length:(NSUInteger)length] base64EncodedStringWithOptions:0];
    else if (length < 0 && errno != ENOATTR) return sm_fail(error,@"Cannot read the save's original file names.");
    if (S_ISDIR(st.st_mode)) {
        NSArray *children = sm_children(path,error);
        if (!children) return NO;
        for (NSString *child in [children sortedArrayUsingSelector:@selector(compare:)])
            if (!sm_zip_tree(writer,folder,sm_path(relative,child),wrapper,names,budget,error)) return NO;
        return YES;
    }
    int fd = open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    if (fd < 0) return sm_fail(error,@"Cannot read the committed save for export.");
    @try {
        unsigned char buffer[65536]; uint64_t left = (uint64_t)st.st_size;
        while (left) {
            ssize_t n = read(fd,buffer,left < sizeof buffer ? (size_t)left : sizeof buffer);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0 || archive_write_data(writer,buffer,(size_t)n) != n)
                return sm_fail(error,@"Cannot write the ZIP save archive.");
            left -= (uint64_t)n;
        }
        return YES;
    } @finally { close(fd); }
}
static BOOL sm_zip_json(struct archive *writer, NSString *path, NSDictionary *object, uint64_t budget[2], NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:error];
    if (!data) return NO;
    if (data.length > 65536 || data.length > budget[0]) return sm_fail(error,@"The save metadata exceeds ZIP limits.");
    budget[0] -= data.length;
    struct archive_entry *entry = archive_entry_new();
    if (!entry) return sm_fail(error,@"Cannot create the ZIP save archive.");
    struct stat st = {0}; st.st_mode = S_IFREG|0600; st.st_size = (off_t)data.length; st.st_mtimespec.tv_sec = time(NULL);
    archive_entry_copy_stat(entry,&st);
    archive_entry_set_pathname_utf8(entry,path.UTF8String);
    int result = archive_write_header(writer,entry);
    archive_entry_free(entry);
    return (!result && archive_write_data(writer,data.bytes,data.length) == (ssize_t)data.length) || sm_fail(error,@"Cannot write the ZIP save archive.");
}
static BOOL sm_export_zip(NSArray<NSString *> *slots, NSString *current, NSString *title, NSString *destination, BOOL collection, NSError **error) {
    if (!slots.count || slots.count > 1000) return sm_fail(error,@"Choose between 1 and 1000 saves.");
    struct archive *writer = archive_write_new();
    if (!writer) return sm_fail(error,@"Cannot create the ZIP save archive.");
    int fd = -1;
    @try {
        if (archive_write_set_format_zip(writer) || archive_write_zip_set_compression_deflate(writer))
            return sm_fail(error,@"Cannot create the ZIP save archive.");
        fd = open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
        if (fd < 0 || archive_write_open_fd(writer,fd)) return sm_fail(error,@"Cannot create the ZIP save archive.");
        uint64_t budget[2] = {8ULL << 30,100000 - 2*slots.count - (collection ? 2 : 0)};
        NSMutableArray *ids = [NSMutableArray array]; NSString *selected = nil;
        for (NSString *slot in slots) {
            NSString *id = NSUUID.UUID.UUIDString.lowercaseString;
            NSString *wrapper = collection ? sm_path(@"saves",id) : [NSString stringWithFormat:@"nxnative-%@-%@",title,id];
            [ids addObject:id]; if ([slot isEqual:current]) selected = id;
            NSMutableDictionary *names = [NSMutableDictionary dictionary];
            for (NSString *part in @[@"save",@"save_device"])
                if (sm_exists(sm_path(slot,part)) && !sm_zip_tree(writer,slot,part,wrapper,names,budget,error)) return NO;
            NSString *name = sm_json(sm_path(slot,@"info.json"))[@"name"];
            if (![name isKindOfClass:NSString.class]) name = slot.lastPathComponent;
            NSMutableDictionary *info = [sm_info(title,name,@"export") mutableCopy];
            if (names.count) info[@"guest_names"] = names;
            if (!sm_zip_json(writer,sm_path(wrapper,@"info.json"),info,budget,error)) return NO;
        }
        if (collection && !sm_zip_json(writer,@"saves/library.json",@{@"format":@"nxnative-save-library",@"version":@1,@"title_id":title,@"slots":ids,@"current":selected ?: ids[0]},budget,error)) return NO;
        if (archive_write_close(writer) || fsync(fd)) return sm_fail(error,@"Cannot write the ZIP save archive.");
        return YES;
    } @finally {
        archive_write_free(writer);
        if (fd >= 0) close(fd);
    }
}

static BOOL sm_unpack(NSString *source, NSString *into, NSError **error) {
    if (!sm_mkdir(into,error)) return NO;
    struct archive *reader = archive_read_new();
    if (!reader) return sm_fail(error,@"Cannot open the compressed save.");
    archive_read_support_filter_none(reader);
    archive_read_support_format_zip_seekable(reader);
    archive_read_support_format_7zip(reader);
    archive_read_support_format_rar(reader);
    archive_read_support_format_rar5(reader);
    // Retain errors outside each entry's autorelease pool until the caller receives them.
    NSError *failure = nil;
    @try {
        // Keep entries literal. Otherwise libarchive hides every ._* path as
        // AppleDouble metadata, including files genuinely owned by the game.
        if (archive_read_set_format_option(reader,"zip","mac-ext",NULL))
            return sm_fail(&failure,@"Cannot open the compressed save.");
        if (archive_read_open_filename(reader,source.fileSystemRepresentation,65536) != 0)
            return sm_fail(&failure,@"Cannot read this save. Choose a .dmsync, ZIP, 7z or RAR file.");
        NSMutableDictionary<NSString *,NSString *> *spellings = [NSMutableDictionary dictionary];
        NSMutableSet *entries = [NSMutableSet set];
        struct archive_entry *entry = NULL;
        uint64_t total = 0, files = 0, count = 0;
        const uint64_t limit = UINT64_C(8) << 30;
        int status;
        while ((status = archive_read_next_header(reader,&entry)) == 0) { @autoreleasepool {
            if (++count > 100000) return sm_fail(&failure,@"The compressed save contains too many entries (limit: 100,000).");
            if (archive_entry_is_encrypted(entry) > 0)
                return sm_fail(&failure,@"Password-protected saves must be extracted before importing.");
            unsigned int type = archive_entry_filetype(entry);
            if ((type != S_IFREG && type != S_IFDIR) || archive_entry_symlink(entry) || archive_entry_hardlink(entry))
                return sm_fail(&failure,@"Links and special files are not allowed in compressed saves.");
            const char *name = archive_entry_pathname_utf8(entry);
            NSString *path = name ? [NSString stringWithUTF8String:name] : nil;
            if (!path.length || path.isAbsolutePath || [path containsString:@"\\"] ||
                [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
                return sm_fail(&failure,@"The compressed save contains an invalid file path.");
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (NSString *part in [path componentsSeparatedByString:@"/"]) {
                if ([part isEqual:@".."] || [part containsString:@":"])
                    return sm_fail(&failure,@"The compressed save contains a path outside its save folder.");
                if (part.length && ![part isEqual:@"."]) [parts addObject:part];
            }
            if (!parts.count && type == S_IFDIR) continue;
            path = [parts componentsJoinedByString:@"/"];
            if (!path.length || parts.count > 32 || [path lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 1024)
                return sm_fail(&failure,@"A path in the compressed save is too long.");
            int64_t size = archive_entry_size(entry);
            if (size < 0 || (uint64_t)size > limit - total)
                return sm_fail(&failure,@"The compressed save is too large (limit: 8 GiB after extraction).");
            total += (uint64_t)size;
            BOOL metadata = NO, gameData = NO;
            for (NSString *part in parts) {
                // Explicit save/ containers preserve every game file, including
                // names which Finder also uses for its own metadata.
                if ([part isEqual:@"save"] || [part isEqual:@"save_device"]) gameData = YES;
                if (!gameData && ([part isEqual:@"__MACOSX"] || [part isEqual:@".DS_Store"] || [part hasPrefix:@"._"])) metadata = YES;
            }
            if (metadata) continue;
            NSString *prefix = @"";
            for (NSString *part in parts) {
                prefix = prefix.length ? sm_path(prefix,part) : part;
                NSString *key = prefix.precomposedStringWithCanonicalMapping.lowercaseString;
                if (spellings[key] && ![spellings[key] isEqual:prefix])
                    return sm_fail(&failure,@"The compressed save contains file names that collide on this device.");
                spellings[key] = prefix;
            }
            if (spellings.count > 100000 || [entries containsObject:path])
                return sm_fail(&failure,@"The compressed save contains too many paths or duplicate entries.");
            [entries addObject:path];
            NSString *destination = sm_path(into,path);
            if (type == S_IFDIR) { if (!sm_mkdir(destination,&failure)) return NO; continue; }
            if (!sm_mkdir(destination.stringByDeletingLastPathComponent,&failure)) return NO;
            int fd = open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
            if (fd < 0) return sm_fail(&failure,@"Cannot create an extracted save file.");
            @try {
                unsigned char buffer[65536]; ssize_t n; uint64_t written = 0;
                while ((n = archive_read_data(reader,buffer,sizeof buffer)) > 0) {
                    written += (uint64_t)n;
                    if (written > (uint64_t)size) return sm_fail(&failure,@"An extracted save file exceeds its declared size.");
                    ssize_t offset = 0;
                    while (offset < n) {
                        ssize_t w = write(fd,buffer+offset,(size_t)(n-offset));
                        if (w < 0 && errno == EINTR) continue;
                        if (w <= 0) return sm_fail(&failure,@"Cannot write the imported save. Check the available storage.");
                        offset += w;
                    }
                }
                if (n < 0 || written != (uint64_t)size) return sm_fail(&failure,@"The compressed save is damaged or incomplete. Password-protected and split archives must be extracted first.");
                time_t seconds = archive_entry_mtime(entry); long nanos = archive_entry_mtime_nsec(entry);
                struct timespec dates[2] = {{seconds,nanos},{seconds,nanos}};
                if (futimens(fd,dates)) return sm_fail(&failure,@"Cannot preserve an imported save file's date.");
            } @finally { close(fd); }
            files++;
        } }
        if (status != 1) return sm_fail(&failure,@"The compressed save is damaged, encrypted or incomplete. Extract password-protected and split archives first.");
        return files > 0 || sm_fail(&failure,@"The compressed archive does not contain any save files.");
    } @finally {
        if (error && failure) *error = failure;
        archive_read_free(reader);
    }
}

static BOOL sm_import_native(NSString *source, NSString *stage, NSString *title, NSError **error) {
    ss_meta meta;
    if (ss_read(source.fileSystemRepresentation,stage.fileSystemRepresentation,&meta))
        return sm_fail(error,@"The save archive is damaged or has invalid paths.");
    return !strcasecmp(meta.title,title.UTF8String) || sm_fail(error,@"The save archive belongs to a different game.");
}
static BOOL sm_is_native(NSString *path) {
    int fd = open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);
    char magic[8]; ssize_t n = -1;
    if (fd >= 0) { do { n = read(fd,magic,sizeof magic); } while (n < 0 && errno == EINTR); close(fd); }
    return n == (ssize_t)sizeof magic && !memcmp(magic,"DMSYNC1\n",sizeof magic);
}
// Recognize the progress-file pair used by BOTW's numbered save format. The
// screenshot is optional; even a damaged caption must keep its game-owned path.
static BOOL sm_progress_slot(NSString *path) {
    for (NSString *file in @[@"game_data.sav",@"caption.sav"]) {
        struct stat st;
        if (lstat(sm_path(path,file).fileSystemRepresentation,&st) || !S_ISREG(st.st_mode)) return NO;
    }
    return YES;
}
static BOOL sm_numeric_folder(NSString *name) {
    return name.length && [name rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location == NSNotFound;
}
static BOOL sm_numbered_save(NSString *path) {
    for (NSString *name in sm_ids(path))
        if (sm_numeric_folder(name) && sm_progress_slot(sm_path(path,name))) return YES;
    return NO;
}
static BOOL sm_add_raw_import(NSString *path, NSString *source, NSString *name, NSMutableArray *entries, NSError **error) {
    NSMutableDictionary *entry = [@{@"path":path,@"raw":@YES,@"name":name} mutableCopy];
    if (sm_progress_slot(path)) {
        // Picking 3/ in the directory picker must still produce save/3/.
        // An archive of loose progress files has lost this identity; never guess it.
        if (!sm_dir(source) || !sm_numeric_folder(source.lastPathComponent))
            return sm_fail(error,@"These progress files need their numbered folder. Import the numbered directory itself or a package that keeps it.");
        entry[@"subdir"] = source.lastPathComponent;
    }
    [entries addObject:entry]; return YES;
}
// Explicit containers, manifests and recognized game roots are unambiguous.
// Other lone directories need a real layout choice rather than a name-based guess.
static BOOL sm_known_container(NSString *path) {
    for (NSUInteger depth = 0; depth < 32; depth++) {
        if (sm_has_save(path) || sm_exists(sm_path(path,@"library.json")) || sm_slots(path).count || sm_numbered_save(path) || sm_progress_slot(path)) return YES;
        NSArray *names = sm_children(path,nil);
        if (names.count != 1 || !sm_dir(sm_path(path,names[0]))) return NO;
        path = sm_path(path,names[0]);
    }
    return NO;
}
static BOOL sm_detect_import(NSString *payload, NSString *source, NSString *fallback, NSString *title, NSString *choice,
                             NSMutableArray *entries, NSDictionary **layout, NSString *scratch, NSUInteger depth, NSError **error) {
    if (depth > 32) return sm_fail(error,@"The save archive has too many enclosing folders.");
    if (sm_has_save(payload) && sm_json(sm_path(payload,@"info.json"))[@"title_id"]) {
        [entries addObject:@{@"path":payload,@"raw":@NO,@"name":fallback}]; return YES;
    }
    NSString *manifest = sm_path(payload,@"library.json");
    if (sm_exists(manifest)) {
        NSDictionary *library = sm_json(manifest); NSArray *ids = library[@"slots"];
        if (![library[@"format"] isEqual:@"nxnative-save-library"] || ![library[@"version"] isEqual:@1] ||
            ![ids isKindOfClass:NSArray.class] || !ids.count || ids.count > 1000 || [NSSet setWithArray:ids].count != ids.count ||
            ![ids containsObject:library[@"current"] ?: NSNull.null]) return sm_fail(error,@"The save library manifest is invalid or incomplete.");
        if (![library[@"title_id"] isEqual:title]) return sm_fail(error,@"The save library belongs to a different game.");
        for (id slot in ids) {
            if (!sm_id(slot) || !sm_has_save(sm_path(payload,slot))) return sm_fail(error,@"The save library manifest is invalid or incomplete.");
            [entries addObject:@{@"path":sm_path(payload,slot),@"raw":@NO,@"name":slot,@"preferred":@([slot isEqual:library[@"current"]])}];
        }
        return YES;
    }
    NSArray *names = sm_children(payload,error);
    if (!names) return NO;
    BOOL nativeFiles = names.count > 0;
    for (NSString *file in names) if (!sm_is_native(sm_path(payload,file))) nativeFiles = NO;
    if (nativeFiles) {
        for (NSString *file in [names sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *native = sm_path(scratch,[@"native-" stringByAppendingString:NSUUID.UUID.UUIDString]);
            if (!sm_mkdir(native,error) || !sm_import_native(sm_path(payload,file),native,title,error)) return NO;
            [entries addObject:@{@"path":native,@"raw":@NO,@"name":names.count == 1 ? fallback : file.stringByDeletingPathExtension}];
        }
        return YES;
    }
    NSMutableArray *containers = [NSMutableArray array];
    for (NSString *name in names) if (sm_id(name) && sm_has_save(sm_path(payload,name))) [containers addObject:name];
    if (containers.count) {
        for (NSString *name in names) if (sm_dir(sm_path(payload,name)) && ![containers containsObject:name] &&
            ![@[@"trash",@"staging",@"__MACOSX"] containsObject:name]) return sm_fail(error,@"The archive mixes save folders with other folders. Import those folders separately.");
        NSString *current = sm_json(sm_path(payload,@"current.json"))[@"slot_id"];
        for (NSString *name in [containers sortedArrayUsingSelector:@selector(compare:)])
            [entries addObject:@{@"path":sm_path(payload,name),@"raw":@NO,@"name":name,@"preferred":@([name isEqual:current])}];
        return YES;
    }
    if (sm_has_save(payload)) {
        [entries addObject:@{@"path":payload,@"raw":@NO,@"name":fallback}]; return YES;
    }
    if (sm_numbered_save(payload)) return sm_add_raw_import(payload,source,fallback,entries,error);
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    for (NSString *name in names) if (sm_dir(sm_path(payload,name))) [folders addObject:name];
    if (folders.count == 1) {
        NSString *outer = folders[0], *child = sm_path(payload,outer);
        NSArray *nested = sm_children(child,error);
        if (!nested) return NO;
        if (names.count == 1 && (sm_known_container(child) || (nested.count == 1 && sm_is_native(sm_path(child,nested[0])))))
            return sm_detect_import(child,source,fallback,title,choice,entries,layout,scratch,depth+1,error);
        if (![choice isEqual:@"root"] && ![choice isEqual:@"inside"]) {
            NSMutableArray *files = [NSMutableArray array];
            NSArray *children = sm_children(child,error);
            if (!children) return NO;
            for (NSString *name in [children sortedArrayUsingSelector:@selector(compare:)]) {
                if (files.count == 8) break;
                [files addObject:[name stringByAppendingString:sm_dir(sm_path(child,name)) ? @"/" : @""]];
            }
            NSMutableArray *rootFiles = [NSMutableArray arrayWithObject:[outer stringByAppendingString:@"/"]];
            for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
                if (rootFiles.count == 8) break;
                if (![name isEqual:outer]) [rootFiles addObject:name];
            }
            *layout = @{@"source":source,@"folder":outer,@"files":files,@"root_files":rootFiles}; return YES;
        }
        if ([choice isEqual:@"inside"]) return sm_detect_import(child,source,fallback,title,@"root",entries,layout,scratch,depth+1,error);
    }
    return sm_add_raw_import(payload,source,fallback,entries,error);
}
static NSDictionary *sm_import_many(NSString *root, NSString *title, NSArray *sources, NSDictionary *choices, NSString *name, BOOL raw, NSError **error) {
    if (![sources isKindOfClass:NSArray.class] || !sources.count || sources.count > 1000 || ![choices isKindOfClass:NSDictionary.class]) {
        sm_fail(error,@"Choose between 1 and 1000 save files or folders."); return nil;
    }
    NSString *job = sm_path(sm_path(sm_base(root),@"staging"),[@"import-" stringByAppendingString:NSUUID.UUID.UUIDString.lowercaseString]);
    NSFileManager *fm = NSFileManager.defaultManager;
    __block NSMutableArray *ids = [NSMutableArray array]; __block NSString *preferred = nil; __block BOOL preferredFound = NO;
    @try {
        if (!sm_mkdir(sm_path(job,@"entries"),error)) return nil;
        NSUInteger index = 0;
        for (id value in sources) {
            if (![value isKindOfClass:NSString.class]) { sm_fail(error,@"Choose valid save file paths."); return nil; }
            NSString *source = [value stringByStandardizingPath];
            if (!source.isAbsolutePath || [source rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
                [job hasPrefix:[source.stringByResolvingSymlinksInPath stringByAppendingString:@"/"]] || !sm_tree(source,error)) {
                sm_fail(error,@"Choose a save archive or directory outside the staging directory."); return nil;
            }
            if ([source.lastPathComponent rangeOfString:@"(?i)(\\.part[0-9]+\\.rar|\\.(zip|7z|rar)\\.[0-9]+|\\.[rz][0-9]{2})$" options:NSRegularExpressionSearch].location != NSNotFound) {
                sm_fail(error,@"Split archives must be extracted before importing."); return nil;
            }
            NSString *input = sm_path(job,[NSString stringWithFormat:@"input-%lu",(unsigned long)index++]);
            __block NSError *failure = nil; __block NSDictionary *layout = nil; __block BOOL ok = NO;
            NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil]; NSError *coordination = nil;
            [coordinator coordinateReadingItemAtURL:[NSURL fileURLWithPath:source] options:NSFileCoordinatorReadingWithoutChanges error:&coordination byAccessor:^(NSURL *readable) {
                NSString *payload = readable.path;
                if (raw && !sm_dir(payload)) { sm_fail(&failure,@"A raw save must be a directory."); return; }
                if (!sm_dir(payload)) {
                    if (sm_is_native(payload)) { if (!sm_mkdir(input,&failure) || !sm_import_native(payload,input,title,&failure)) return; }
                    else if (!sm_unpack(payload,input,&failure)) return;
                    payload = input;
                }
                NSMutableArray *entries = [NSMutableArray array];
                if (raw) { if (!sm_add_raw_import(payload,source,source.lastPathComponent,entries,&failure)) return; }
                else if (!sm_detect_import(payload,source,source.lastPathComponent.stringByDeletingPathExtension,title,choices[source] ?: choices[value],entries,&layout,job,0,&failure)) return;
                if (layout) { ok = YES; return; }
                for (NSDictionary *entry in entries) {
                    if (ids.count >= 1000) { sm_fail(&failure,@"Choose between 1 and 1000 saves."); return; }
                    NSString *from = entry[@"path"]; BOOL isRaw = [entry[@"raw"] boolValue];
                    NSDictionary *info = isRaw ? nil : sm_json(sm_path(from,@"info.json"));
                    if (info[@"title_id"] && ![info[@"title_id"] isEqual:title]) { sm_fail(&failure,@"The save folder belongs to a different game."); return; }
                    if (!isRaw && sm_exists(sm_path(from,@"cloud-pending"))) { sm_fail(&failure,@"Download this cloud save before importing its directory."); return; }
                    NSString *label = name.length ? name : ([info[@"name"] isKindOfClass:NSString.class] ? info[@"name"] : entry[@"name"]);
                    if (!sm_name(label,&failure)) return;
                    NSString *slot = NSUUID.UUID.UUIDString.lowercaseString, *stage = sm_path(sm_path(job,@"entries"),slot);
                    NSString *target = sm_path(stage,@"save");
                    if (entry[@"subdir"]) target = sm_path(target,entry[@"subdir"]);
                    if (!sm_mkdir(stage,&failure) || (isRaw ? !sm_copy_tree(from,target,&failure) :
                        (!sm_copy_data(from,stage,&failure) || !sm_restore_names(info,stage,&failure)))) return;
                    NSMutableDictionary *record = [sm_info(title,label,@"import") mutableCopy]; record[@"import_batch"] = job.lastPathComponent;
                    if (!sm_write(sm_path(stage,@"info.json"),record,&failure)) return;
                    [ids addObject:slot];
                    if (!preferred) preferred = slot;
                    if (!preferredFound && [entry[@"preferred"] boolValue]) { preferred = slot; preferredFound = YES; }
                }
                ok = YES;
            }];
            if (!ok || coordination) { if (error) *error = coordination ?: failure; return nil; }
            if (layout) return @{@"needs_layout":layout};
        }
        if (!ids.count) { sm_fail(error,@"No saves were found in the selected files."); return nil; }
        if (!sm_write(sm_path(job,@"batch.json"),@{@"version":@1,@"title_id":title,@"ids":ids},error) || !sm_finish_import(root,job,title,error)) return nil;
        return @{@"id":preferred,@"ids":ids,@"count":@(ids.count),@"path":sm_slot(root,preferred)};
    } @finally {
        BOOL published = NO;
        for (NSString *slot in ids) if ([sm_json(sm_path(sm_slot(root,slot),@"info.json"))[@"import_batch"] isEqual:job.lastPathComponent]) published = YES;
        if (!sm_exists(sm_path(job,@"batch.json")) || !published) [fm removeItemAtPath:job error:nil];
    }
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
    if ([@[@"import",@"import-raw",@"import-root",@"import-inside",@"import-many"] containsObject:cmd]) {
        NSArray *sources = @[a]; NSDictionary *choices = @{}; NSString *name = b;
        if ([cmd isEqual:@"import-many"]) {
            sources = [NSJSONSerialization JSONObjectWithData:[a dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:error];
            choices = b.length ? [NSJSONSerialization JSONObjectWithData:[b dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:error] : @{};
            name = @"";
        } else if ([cmd isEqual:@"import-root"] || [cmd isEqual:@"import-inside"]) choices = @{a.stringByStandardizingPath:[cmd isEqual:@"import-root"] ? @"root" : @"inside"};
        return sm_import_many(root,title,sources,choices,name,[cmd isEqual:@"import-raw"],error);
    }
    if ([cmd isEqual:@"export-many"]) {
        id ids = [NSJSONSerialization JSONObjectWithData:[a dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:error];
        if (![ids isKindOfClass:NSArray.class]) { sm_fail(error,@"Choose valid saves to export."); return nil; }
        if (![ids count]) ids = sm_slots(base);
        if (![ids count] || [ids count] > 1000 || [NSSet setWithArray:ids].count != [ids count]) { sm_fail(error,@"Choose between 1 and 1000 saves."); return nil; }
        NSMutableArray *slots = [NSMutableArray array];
        for (id slot in ids) {
            if (!sm_id(slot) || !sm_has_save(sm_slot(root,slot))) { sm_fail(error,@"The selected save does not exist."); return nil; }
            NSString *path = sm_slot(root,slot);
            if (!sm_ready(path,title,error)) return nil;
            [slots addObject:path];
        }
        NSString *dest = b.stringByStandardizingPath.stringByResolvingSymlinksInPath;
        if (!dest.isAbsolutePath || ![dest.pathExtension.lowercaseString isEqual:@"zip"] || sm_exists(dest) || [dest hasPrefix:[base stringByAppendingString:@"/"]]) {
            sm_fail(error,@"Choose a new ZIP file outside the managed saves directory."); return nil;
        }
        NSString *temp = [dest stringByAppendingFormat:@".%@.tmp",NSUUID.UUID.UUIDString];
        NSString *current = sm_selection(root,@"current.json");
        BOOL ok = sm_export_zip(slots,current ? sm_slot(root,current) : nil,title,temp,YES,error);
        if (!ok || renamex_np(temp.fileSystemRepresentation,dest.fileSystemRepresentation,RENAME_EXCL)) {
            unlink(temp.fileSystemRepresentation);
            if (ok) sm_fail(error,@"Cannot publish the export without replacing an existing file.");
            return nil;
        }
        return @{@"file":dest,@"count":@([slots count])};
    }
    if ([cmd isEqual:@"create"] || [cmd isEqual:@"copy"]) {
        NSString *slot = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *stage = sm_path(sm_path(base,@"staging"),slot);
        NSString *name = [cmd isEqual:@"create"] ? a : b;
        if (!name.length) name = @"Copy";
        if (!sm_name(name,error) || !sm_mkdir(stage,error)) return nil;
        BOOL ok = YES;
        if ([cmd isEqual:@"copy"]) {
            if (!sm_id(a) || !sm_dir(sm_slot(root,a))) ok = sm_fail(error,@"The source save does not exist.");
            else ok = sm_ready(sm_slot(root,a),title,error) && sm_copy_data(sm_slot(root,a),stage,error);
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
        if ([dest.pathExtension.lowercaseString isEqual:@"zip"]) {
            if (!sm_export_zip(@[slot],slot,title,temp,NO,error)) { unlink(temp.fileSystemRepresentation); return nil; }
        } else if (ss_pack(save.fileSystemRepresentation,title.UTF8String,temp.fileSystemRepresentation,&meta)) { sm_fail(error,@"Cannot write the save archive."); return nil; }
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
