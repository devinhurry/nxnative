// Use the system's ZIP/ZIP64 reader. Payloads stream to a private staging folder;
// an incomplete or incompatible import never replaces the selected package.
#import "GraphicsPack.h"
#import <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <unistd.h>

// Apple SDKs export libarchive but omit its C headers. These are declarations
// of the stable public read API, not a separate ZIP parser (libarchive.org).
struct archive; struct archive_entry;
extern struct archive *archive_read_new(void);
extern int archive_read_support_format_zip(struct archive *);
extern int archive_read_support_filter_none(struct archive *);
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

static const uint64_t graphics_max_bytes = UINT64_C(64) << 30;
static BOOL graphics_read_package(NSURL *source, NSURL *documents, NSDictionary *required,
                                  void (^progress)(long long,long long), BOOL validateOnly, NSError **error);
static NSError *graphics_error(NSString *message) {
    return [NSError errorWithDomain:@"nxnative.graphics" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSString *graphics_text(const char *value) { return value ? @(value) : @"Invalid graphics ZIP."; }
static int graphics_integer(id n) {
    return [n isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)n) != CFBooleanGetTypeID() &&
           [n doubleValue] >= 0 && [n doubleValue] <= graphics_max_bytes && [n doubleValue] == (double)[n longLongValue];
}
static BOOL graphics_match(NSString *text, NSString *pattern) {
    return [text isKindOfClass:NSString.class] && [text rangeOfString:pattern options:NSRegularExpressionSearch].location != NSNotFound;
}
static BOOL graphics_path(NSString *path) {
    if (!graphics_match(path,@"^[A-Za-z0-9_./-]+$") || [path hasPrefix:@"/"] || [path hasSuffix:@"/"]) return NO;
    for (NSString *part in [path componentsSeparatedByString:@"/"])
        if (!part.length || [part isEqual:@"."] || [part isEqual:@".."]) return NO;
    return [path hasPrefix:@"msl/"] || [path hasPrefix:@"tables/"] || [path hasPrefix:@"pso/"];
}
static NSString *graphics_hex(const unsigned char *bytes, size_t n) {
    NSMutableString *text=[NSMutableString stringWithCapacity:n*2];
    for (size_t i=0;i<n;i++) [text appendFormat:@"%02x",bytes[i]];
    return text;
}
static void graphics_hash_text(CC_SHA256_CTX *hash, NSString *text) {
    NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding]; CC_SHA256_Update(hash,data.bytes,(CC_LONG)data.length);
}
static NSDictionary *graphics_json(NSURL *url) {
    NSNumber *size=nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (!size || size.unsignedLongLongValue > (64u<<20)) return nil;
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:nil];
    id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
NSDictionary *dm_graphics_requirements(NSURL *bundle) {
    NSDictionary *r=graphics_json([bundle URLByAppendingPathComponent:@"dm/graphics-required.json"]);
    if (![r[@"schema"] isEqual:@1] || ![r[@"series"] isKindOfClass:NSString.class] || ![r[@"series"] length] ||
        ![r[@"compatibility"] isKindOfClass:NSDictionary.class] || !graphics_integer(r[@"minimum_version"]) || ![r[@"minimum_version"] longLongValue]) return nil;
    return r;
}

static NSString *graphics_compatibility_error(NSDictionary *manifest, NSDictionary *required) {
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isEqual:@1] || ![manifest[@"kind"] isEqual:@"graphics"])
        return NSLocalizedString(@"This is not a supported graphics package.",nil);
    if (![required isKindOfClass:NSDictionary.class] || ![required[@"schema"] isEqual:@1])
        return NSLocalizedString(@"This app has no graphics package requirements.",nil);
    if (![manifest[@"series"] isEqual:required[@"series"]] || ![manifest[@"compatibility"] isEqual:required[@"compatibility"]])
        return NSLocalizedString(@"The graphics compatibility series does not match this app.",nil);
    if (!graphics_integer(required[@"minimum_version"]) || ![required[@"minimum_version"] longLongValue] ||
        !graphics_integer(manifest[@"version"]) || [manifest[@"version"] compare:required[@"minimum_version"]] == NSOrderedAscending)
        return [NSString stringWithFormat:NSLocalizedString(@"This app requires graphics package version %@ or later.",nil),required[@"minimum_version"] ?: @"?"];
    if (!graphics_match(manifest[@"id"],@"^[0-9a-f]{64}$") || !graphics_match(manifest[@"compiler_id"],@"^[0-9a-f]{64}$"))
        return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    if (![manifest[@"compilers"] isKindOfClass:NSDictionary.class]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    NSData *compilerJSON=[NSJSONSerialization dataWithJSONObject:manifest[@"compilers"] options:NSJSONWritingSortedKeys|NSJSONWritingWithoutEscapingSlashes error:nil];
    unsigned char compilerSHA[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(compilerJSON.bytes,(CC_LONG)compilerJSON.length,compilerSHA);
    if (![graphics_hex(compilerSHA,sizeof compilerSHA) isEqual:manifest[@"compiler_id"]]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    NSString *minimumOS=manifest[@"compilers"][@"minimum_os"];
    if (!graphics_match(minimumOS,@"^[0-9]+\\.[0-9]+$")) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
#if TARGET_OS_IOS
    NSArray *os=[minimumOS componentsSeparatedByString:@"."];
    if (![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){[os[0] integerValue],[os[1] integerValue],0}])
        return [NSString stringWithFormat:NSLocalizedString(@"This graphics package requires iOS %@ or later.",nil),minimumOS];
#endif
    return nil;
}

NSString *dm_graphics_manifest_error(NSDictionary *manifest, NSDictionary *required) {
    NSString *error=graphics_compatibility_error(manifest,required); if (error) return error;
    NSArray *files=manifest[@"files"];
    if (![files isKindOfClass:NSArray.class] || !files.count || files.count>200000)
        return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    NSMutableSet *names=[NSMutableSet set]; NSString *previous=nil; uint64_t total=0;
    CC_SHA256_CTX hash; CC_SHA256_Init(&hash);
    graphics_hash_text(&hash,[NSString stringWithFormat:@"nxnative-graphics-v1\n%@\n%@\n%@\n",manifest[@"series"],manifest[@"version"],manifest[@"compiler_id"]]);
    BOOL library=NO;
    NSString *lib=[@"msl/" stringByAppendingFormat:@"%@/",required[@"compatibility"][@"library"] ?: @""];
    for (id item in files) {
        if (![item isKindOfClass:NSDictionary.class]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
        NSString *path=item[@"path"];
        if (!graphics_path(path) || !graphics_integer(item[@"size"]) || !graphics_match(item[@"sha256"],@"^[0-9a-f]{64}$") ||
            [names containsObject:path.lowercaseString] || (previous && [previous compare:path options:NSLiteralSearch] != NSOrderedAscending))
            return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
        [names addObject:path.lowercaseString]; previous=path;
        total += [item[@"size"] unsignedLongLongValue];
        if (total>graphics_max_bytes) return NSLocalizedString(@"The graphics package is too large.",nil);
        if ([path hasPrefix:lib] && [path hasSuffix:@".metallib"]) library=YES;
        graphics_hash_text(&hash,[NSString stringWithFormat:@"%@\t%@\t%@\n",path,item[@"size"],item[@"sha256"]]);
    }
    unsigned char result[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(result,&hash);
    if (!library || ![names containsObject:@"tables/shader_map.tsv"] || ![graphics_hex(result,sizeof result) isEqual:manifest[@"id"]])
        return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    return nil;
}

static NSString *graphics_installed_error(NSURL *directory, NSDictionary *manifest, NSDictionary *required) {
    NSString *error=graphics_compatibility_error(manifest,required); if (error) return error;
    NSString *name=[NSString stringWithFormat:@"v%@-%@",manifest[@"version"],manifest[@"id"]];
    if (![directory.lastPathComponent isEqual:name]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    // Import already verified the complete inventory and hashes. Readiness only
    // needs the map and a representative library, not a stat for every shader.
    NSURL *map=[directory URLByAppendingPathComponent:@"tables/shader_map.tsv"];
    if (![[NSFileManager.defaultManager attributesOfItemAtPath:map.path error:nil][NSFileType] isEqual:NSFileTypeRegular])
        return NSLocalizedString(@"The graphics package is incomplete. Import it again.",nil);
    if (![manifest[@"files"] isKindOfClass:NSArray.class]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
    NSString *library=[@"msl/" stringByAppendingFormat:@"%@/",required[@"compatibility"][@"library"]];
    for (NSDictionary *entry in manifest[@"files"]) {
        if (![entry isKindOfClass:NSDictionary.class]) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
        NSString *path=entry[@"path"];
        if (![path isKindOfClass:NSString.class] || ![path hasPrefix:library] || ![path hasSuffix:@".metallib"]) continue;
        if (!graphics_path(path) || !graphics_integer(entry[@"size"])) return NSLocalizedString(@"The graphics package manifest is invalid.",nil);
        NSURL *file=[directory URLByAppendingPathComponent:entry[@"path"]];
        NSDictionary *a=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        if (![a[NSFileType] isEqual:NSFileTypeRegular] || ![a[NSFileSize] isEqual:entry[@"size"]])
            return NSLocalizedString(@"The graphics package is incomplete. Import it again.",nil);
        return nil;
    }
    return NSLocalizedString(@"The graphics package is incomplete. Import it again.",nil);
}
static NSURL *graphics_selected(NSURL *documents, NSURL *bundle, NSDictionary **info, NSError **error) {
    NSDictionary *required=dm_graphics_requirements(bundle);
    if (!required) {
        // Legacy apps are usable only when their libraries are actually bundled.
        BOOL hasRequirements=[NSFileManager.defaultManager fileExistsAtPath:[bundle URLByAppendingPathComponent:@"dm/graphics-required.json"].path];
        if (!hasRequirements && [NSFileManager.defaultManager fileExistsAtPath:[bundle URLByAppendingPathComponent:@"msl"].path]) return bundle;
        if (error) *error=graphics_error(NSLocalizedString(@"This app is missing graphics requirements. Rebuild or reinstall it.",nil));
        return nil;
    }
    NSURL *root=[documents URLByAppendingPathComponent:@"graphics" isDirectory:YES];
    NSDictionary *current=graphics_json([root URLByAppendingPathComponent:@"current.json"]);
    NSString *selected=current[@"directory"];
    NSURL *best=nil; long long version=-1; NSString *why=nil;
    NSDictionary *bestInfo=nil;
    if (graphics_match(selected,@"^v[0-9]+-[0-9a-f]{64}$")) {
        NSURL *active=[root URLByAppendingPathComponent:selected isDirectory:YES];
        if ([[NSFileManager.defaultManager attributesOfItemAtPath:active.path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) {
            NSDictionary *m=graphics_json([active URLByAppendingPathComponent:@"manifest.json"]);
            why=graphics_installed_error(active,m,required);
            if (!why) { if (info) *info=m; return active; }
        }
    }
    NSArray *children=[NSFileManager.defaultManager contentsOfDirectoryAtURL:root includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    for (NSURL *child in children) {
        if ([child.lastPathComponent isEqual:selected]) continue;
        if (!graphics_match(child.lastPathComponent,@"^v[0-9]+-[0-9a-f]{64}$")) continue;
        if (![[NSFileManager.defaultManager attributesOfItemAtPath:child.path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) continue;
        NSDictionary *m=graphics_json([child URLByAppendingPathComponent:@"manifest.json"]);
        NSString *problem=graphics_installed_error(child,m,required);
        if (problem) continue;
        if ([m[@"version"] longLongValue]>version) { best=child; bestInfo=m; version=[m[@"version"] longLongValue]; }
    }
    if (best) { if (info) *info=bestInfo; return best; }
    if (![required[@"external"] boolValue]) return bundle;
    if (error) *error=graphics_error(why ?: NSLocalizedString(@"Import a compatible graphics ZIP to start.",nil));
    return nil;
}
NSString *dm_graphics_status(NSURL *documents, NSURL *bundle) {
    NSError *error=nil; graphics_selected(documents,bundle,NULL,&error); return error.localizedDescription;
}
NSURL *dm_graphics_pending_package(NSURL *documents, NSURL *bundle, NSError **error) {
    if (!dm_graphics_status(documents,bundle)) return nil;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSArray<NSURL *> *files=[fm contentsOfDirectoryAtURL:documents includingPropertiesForKeys:nil
                                               options:NSDirectoryEnumerationSkipsHiddenFiles error:error];
    if (!files) return nil;
    NSDictionary *required=dm_graphics_requirements(bundle);
    if (!required) {
        if (error) *error=graphics_error(NSLocalizedString(@"This app has no graphics package requirements.",nil));
        return nil;
    }
    NSURL *package=nil;
    NSError *firstError=nil;
    for (NSURL *file in files) {
        if (![file.pathExtension.lowercaseString isEqual:@"zip"]) continue;
        NSDictionary *attributes=[fm attributesOfItemAtPath:file.path error:error];
        if (!attributes) return nil;
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) continue;
        NSError *invalid=nil;
        if (!graphics_read_package(file,documents,required,nil,YES,&invalid)) {
            fprintf(stderr,"launcher: skipping ZIP %s: %s\n",file.lastPathComponent.UTF8String,invalid.localizedDescription.UTF8String);
            if (!firstError) firstError=invalid;
            continue;
        }
        if (package) {
            if (error) *error=graphics_error(NSLocalizedString(@"More than one valid graphics ZIP was found. Use Import shaders to choose a package.",nil));
            return nil;
        }
        package=file;
    }
    if (!package && error) *error=firstError;
    return package;
}
NSDictionary *dm_graphics_current_info(NSURL *documents, NSURL *bundle, NSError **error) {
    NSDictionary *info=nil;
    NSURL *selected=graphics_selected(documents,bundle,&info,error);
    return selected ? (info ?: @{}) : nil;
}
BOOL dm_graphics_configure(NSURL *documents, NSURL *bundle, NSError **error) {
    NSURL *selected=graphics_selected(documents,bundle,NULL,error); if (!selected) return NO;
    if ([selected isEqual:bundle]) return YES;
    setenv("DM_MSL_DIR",[selected URLByAppendingPathComponent:@"msl"].fileSystemRepresentation,1);
    setenv("DM_NVN_SHMAP",[selected URLByAppendingPathComponent:@"tables/shader_map.tsv"].fileSystemRepresentation,1);
    NSURL *pso=[selected URLByAppendingPathComponent:@"pso"];
    setenv("DM_PSO_BUNDLE",[NSFileManager.defaultManager fileExistsAtPath:pso.path] ? pso.fileSystemRepresentation : "off",1);
    fprintf(stderr,"boot: graphics package %s\n",selected.lastPathComponent.UTF8String);
    return YES;
}

BOOL dm_import_graphics_package(NSURL *source, NSURL *documents, NSDictionary *required,
                                void (^progress)(long long,long long), NSError **error) {
    return graphics_read_package(source,documents,required,progress,NO,error);
}

// Discovery checks the same manifest, inventory and payload hashes without writing files.
static BOOL graphics_read_package(NSURL *source, NSURL *documents, NSDictionary *required,
                                  void (^progress)(long long,long long), BOOL validateOnly, NSError **error) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *root=[documents URLByAppendingPathComponent:@"graphics" isDirectory:YES];
    NSURL *stage=[root URLByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    NSError *failure=nil; __block BOOL imported=NO;
    if (!validateOnly) {
        NSDictionary *rootAttributes=[fm attributesOfItemAtPath:root.path error:nil];
        if (rootAttributes && ![rootAttributes[NSFileType] isEqual:NSFileTypeDirectory]) {
            if (error) *error=graphics_error(NSLocalizedString(@"The graphics destination must be a regular directory.",nil)); return NO;
        }
        if (![fm createDirectoryAtURL:stage withIntermediateDirectories:YES attributes:nil error:&failure]) { if (error) *error=failure; return NO; }
        [stage setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
    BOOL scope=[source startAccessingSecurityScopedResource];
    NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    __block NSError *readError=nil;
    [coordinator coordinateReadingItemAtURL:source options:NSFileCoordinatorReadingWithoutChanges error:&failure byAccessor:^(NSURL *readable) {
        struct archive *archive=archive_read_new(); struct archive_entry *entry=NULL;
        if (!archive) { readError=graphics_error(@"Cannot open graphics ZIP."); return; }
        archive_read_support_filter_none(archive); archive_read_support_format_zip(archive);
        @try {
            if (archive_read_open_filename(archive,readable.fileSystemRepresentation,256*1024)!=0 ||
                archive_read_next_header(archive,&entry)!=0 || !archive_entry_pathname_utf8(entry) ||
                strcmp(archive_entry_pathname_utf8(entry),"manifest.json") || archive_entry_filetype(entry)!=0100000 ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry) || archive_entry_size(entry)<1 || archive_entry_size(entry)>(64u<<20)) {
                readError=graphics_error(NSLocalizedString(@"This is not a supported graphics package.",nil)); return;
            }
            NSMutableData *manifestData=[NSMutableData dataWithLength:(NSUInteger)archive_entry_size(entry)];
            size_t copied=0;
            while (copied<manifestData.length) {
                ssize_t n=archive_read_data(archive,(char *)manifestData.mutableBytes+copied,manifestData.length-copied);
                if (n<=0) { readError=graphics_error(graphics_text(archive_error_string(archive))); return; } copied+=(size_t)n;
            }
            id manifest=[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&readError];
            NSString *invalid=dm_graphics_manifest_error(manifest,required);
            if (invalid) { readError=graphics_error(invalid); return; }
            NSDictionary *m=manifest;
            NSMutableDictionary *remaining=[NSMutableDictionary dictionary]; long long total=0,done=0;
            for (NSDictionary *item in m[@"files"]) { remaining[item[@"path"]]=item; total += [item[@"size"] longLongValue]; }
            NSNumber *capacity=nil;
            if (!validateOnly) [stage getResourceValue:&capacity forKey:NSURLVolumeAvailableCapacityKey error:nil];
            if (capacity && total>capacity.longLongValue) { readError=graphics_error(NSLocalizedString(@"Not enough free space to import graphics.",nil)); return; }
            if (progress) progress(0,total);
            unsigned char buffer[256*1024]; int status;
            while ((status=archive_read_next_header(archive,&entry))==0) {
                @autoreleasepool {
                const char *name=archive_entry_pathname_utf8(entry); NSString *path=name ? @(name) : nil;
                NSDictionary *item=path ? remaining[path] : nil;
                if (!item || archive_entry_filetype(entry)!=0100000 || archive_entry_symlink(entry) || archive_entry_hardlink(entry) ||
                    archive_entry_size(entry)!=[item[@"size"] longLongValue]) {
                    readError=graphics_error(NSLocalizedString(@"The graphics ZIP contains an unexpected file.",nil)); return;
                }
                int fd=-1;
                if (!validateOnly) {
                    NSURL *destination=[stage URLByAppendingPathComponent:path];
                    if (![fm createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&readError]) return;
                    fd=open(destination.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
                    if (fd<0) { readError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return; }
                }
                CC_SHA256_CTX hash; CC_SHA256_Init(&hash); long long bytes=0;
                @try {
                    ssize_t n;
                    while ((n=archive_read_data(archive,buffer,sizeof buffer))>0) {
                        bytes+=n;
                        if (bytes>[item[@"size"] longLongValue]) { readError=graphics_error(@"Graphics file size mismatch."); return; }
                        CC_SHA256_Update(&hash,buffer,(CC_LONG)n);
                        ssize_t offset=0;
                        while (fd>=0 && offset<n) { ssize_t w=write(fd,buffer+offset,(size_t)(n-offset)); if (w<0 && errno==EINTR) continue;
                            if (w<=0) { readError=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return; } offset+=w; }
                        done+=n; if (progress) progress(done,total);
                    }
                    if (n<0) { readError=graphics_error(graphics_text(archive_error_string(archive))); return; }
                } @finally { if (fd>=0) close(fd); }
                unsigned char sha[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(sha,&hash);
                if (bytes!=[item[@"size"] longLongValue] || ![graphics_hex(sha,sizeof sha) isEqual:item[@"sha256"]]) {
                    readError=graphics_error(NSLocalizedString(@"A graphics file failed its integrity check.",nil)); return;
                }
                [remaining removeObjectForKey:path];
                }
            }
            if (status!=1 || remaining.count) { readError=graphics_error(NSLocalizedString(@"The graphics ZIP is incomplete.",nil)); return; }
            if (validateOnly) { imported=YES; return; }
            if (![manifestData writeToURL:[stage URLByAppendingPathComponent:@"manifest.json"] options:NSDataWritingAtomic error:&readError]) return;
            [stage setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
            NSString *directory=[NSString stringWithFormat:@"v%@-%@",m[@"version"],m[@"id"]];
            NSURL *destination=[root URLByAppendingPathComponent:directory isDirectory:YES];
            if ([fm fileExistsAtPath:destination.path]) {
                if (![[fm attributesOfItemAtPath:destination.path error:nil][NSFileType] isEqual:NSFileTypeDirectory]) { readError=graphics_error(@"Invalid graphics destination."); return; }
                if (![fm replaceItemAtURL:destination withItemAtURL:stage backupItemName:nil
                                 options:NSFileManagerItemReplacementUsingNewMetadataOnly resultingItemURL:nil error:&readError]) return;
            } else if (![fm moveItemAtURL:stage toURL:destination error:&readError]) return;
            NSData *active=[NSJSONSerialization dataWithJSONObject:@{@"directory":directory} options:0 error:&readError];
            if (!active || ![active writeToURL:[root URLByAppendingPathComponent:@"current.json"] options:NSDataWritingAtomic error:&readError]) return;
            imported=YES;
        } @finally { archive_read_free(archive); }
    }];
    if (scope) [source stopAccessingSecurityScopedResource];
    if (!validateOnly) [fm removeItemAtURL:stage error:nil];
    if (error) *error=readError ?: failure;
    return imported;
}
