// MIT nxnative-mkw donor XPC/extension mechanism, adapted for native guest-range
// backing and early startup. See ../ios/Donor/README.md.
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
@import Foundation;
#import <mach/mach.h>
#import <os/lock.h>
#import <pthread.h>
#import <signal.h>
#import <xpc/xpc.h>
#import "ram_donor.h"
#import "ram_donor_proto.h"

extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
extern kern_return_t mach_vm_remap(vm_map_t, mach_vm_address_t *, mach_vm_size_t, mach_vm_offset_t, int, vm_map_t, mach_vm_address_t, boolean_t, vm_prot_t *, vm_prot_t *, vm_inherit_t);
// This iOS SPI provides the donor's process ID; the public header marks it unavailable.
extern pid_t donor_connection_pid(xpc_connection_t) __asm("_xpc_connection_get_pid");
@interface NSObject (DmDonorExtension)
+ (id)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)setPreferredLanguages:(NSArray *)languages;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *))block;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)signal;
@end
@interface NSXPCListenerEndpoint (DmDonorPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end
@interface DmDonorProc : NSObject
@property (nonatomic, strong) xpc_connection_t conn;
@property (nonatomic, strong) id ext;
@property (nonatomic) int pid;
@property (atomic) BOOL gone;
@end
@implementation DmDonorProc @end

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static os_unfair_lock g_accept_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<DmDonorProc *> *g_donors;
static int g_used, g_back_started, g_waiting;
static DmDonorProc *g_pending;
static xpc_connection_t g_listener;
static xpc_object_t g_endpoint;
static dispatch_semaphore_t g_connected;

static NSString *extension_id(char *why, size_t cap) {
    static NSString *identifier; static char failure[256]; static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:NSBundle.mainBundle.builtInPlugInsURL includingPropertiesForKeys:nil options:0 error:nil]) {
            if (![url.pathExtension isEqualToString:@"appex"]) continue;
            NSBundle *bundle = [NSBundle bundleWithURL:url];
            if ([bundle.infoDictionary[@"NSExtension"][@"NSExtensionPrincipalClass"] isEqualToString:@"DmRamDonorHandler"]) { identifier = bundle.bundleIdentifier; break; }
        }
        if (identifier) fprintf(stderr, "[dm] [mem] RAM donor: the donor extension is %s\n", identifier.UTF8String);
        else snprintf(failure, sizeof failure, "no donor extension (principal class DmRamDonorHandler) in PlugIns");
    });
    if (!identifier) snprintf(why, cap, "%s", failure);
    return identifier;
}
static void listen_once(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_connected = dispatch_semaphore_create(0);
        g_listener = xpc_connection_create(NULL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        xpc_connection_set_event_handler(g_listener, ^(xpc_object_t ev) {
            if (xpc_get_type(ev) != XPC_TYPE_CONNECTION) return;
            DmDonorProc *p = [DmDonorProc new]; p.conn = (xpc_connection_t)ev; p.pid = donor_connection_pid(p.conn);
            os_unfair_lock_lock(&g_accept_lock);
            if (!g_waiting || g_pending) {
                os_unfair_lock_unlock(&g_accept_lock);
                fprintf(stderr, "[dm] [mem] RAM donor: a connection from pid %d that no start waits for, refused\n", p.pid); xpc_connection_cancel(p.conn); return;
            }
            __weak DmDonorProc *weak = p;
            xpc_connection_set_event_handler(p.conn, ^(xpc_object_t x) { if (xpc_get_type(x) == XPC_TYPE_ERROR) weak.gone = YES; });
            xpc_connection_resume(p.conn); g_pending = p;
            os_unfair_lock_unlock(&g_accept_lock); dispatch_semaphore_signal(g_connected);
        });
        xpc_connection_resume(g_listener); g_endpoint = xpc_endpoint_create(g_listener);
    });
}
// Called with g_mu held to serialize prestart/start operations.
static int start_one(char *why, size_t cap) {
    listen_once(); if (!g_endpoint) { snprintf(why, cap, "xpc_endpoint_create failed"); return -1; }
    while (!dispatch_semaphore_wait(g_connected, DISPATCH_TIME_NOW)) {}
    os_unfair_lock_lock(&g_accept_lock); g_waiting = 1; g_pending = nil; os_unfair_lock_unlock(&g_accept_lock);
    NSString *identifier = extension_id(why, cap); id ext = nil; int result = -1; Class cls = Nil; NSError *error = nil;
    if (!identifier) goto done;
    cls = NSClassFromString(@"NSExtension"); if (!cls) { snprintf(why, cap, "this system has no NSExtension class"); goto done; }
    ext = [cls extensionWithIdentifier:identifier error:&error];
    if (!ext) { snprintf(why, cap, "NSExtension %s: %s", identifier.UTF8String, error.localizedDescription.UTF8String ?: "not found"); goto done; }
    [ext setPreferredLanguages:@[]];
    [ext setRequestCancellationBlock:^(NSUUID *u) { (void)u; fprintf(stderr, "[dm] [mem] RAM donor: a donor request was cancelled\n"); }];
    [ext setRequestInterruptionBlock:^(NSUUID *u) { (void)u; fprintf(stderr, "[dm] [mem] RAM donor: a donor request was interrupted (its process ended)\n"); }];
    {
        NSXPCListenerEndpoint *ep = [NSXPCListenerEndpoint new]; ep._endpoint = g_endpoint;
        NSExtensionItem *item = [NSExtensionItem new]; item.userInfo = @{@"endpoint":ep};
        __block NSUUID *request; dispatch_semaphore_t spawned = dispatch_semaphore_create(0);
        [ext beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *u) { request = u; dispatch_semaphore_signal(spawned); }];
        if (dispatch_semaphore_wait(spawned, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) || !request) { snprintf(why, cap, "the extension request was refused: no donor process"); goto done; }
        int pid = [ext pidForRequestIdentifier:request];
        if (dispatch_semaphore_wait(g_connected, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) { snprintf(why, cap, "donor process %d started but did not connect within 10 s", pid); goto done; }
        os_unfair_lock_lock(&g_accept_lock); DmDonorProc *p = g_pending; g_pending = nil; os_unfair_lock_unlock(&g_accept_lock);
        if (!p || p.gone) { snprintf(why, cap, "donor process %d has ended", pid); goto done; }
        p.ext = ext; if (!g_donors) g_donors = [NSMutableArray array]; result = (int)g_donors.count; [g_donors addObject:p];
        fprintf(stderr, "[dm] [mem] RAM donor: started pid %d, connected pid %d\n", pid, p.pid);
    }
done:
    os_unfair_lock_lock(&g_accept_lock); g_waiting = 0; DmDonorProc *pending = g_pending; g_pending = nil; os_unfair_lock_unlock(&g_accept_lock);
    if (pending.conn) xpc_connection_cancel(pending.conn);
    if (result < 0 && ext) [ext _kill:SIGKILL];
    return result;
}

static xpc_object_t call(int donor, const char *op, uint64_t size, char *why, size_t cap, double seconds) {
    pthread_mutex_lock(&g_mu); DmDonorProc *p = donor >= 0 && donor < (int)g_donors.count ? g_donors[(NSUInteger)donor] : nil; pthread_mutex_unlock(&g_mu);
    if (!p) { snprintf(why, cap, "no donor %d", donor); return nil; }
    if (p.gone) { snprintf(why, cap, "donor process %d has ended", p.pid); return nil; }
    xpc_object_t m = xpc_dictionary_create(NULL, NULL, 0); xpc_dictionary_set_string(m, DM_DONOR_OP, op); if (size) xpc_dictionary_set_uint64(m, DM_DONOR_SIZE, size);
    __block xpc_object_t reply; dispatch_semaphore_t done = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(p.conn, m, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t r) { reply = r; dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)))) { snprintf(why, cap, "donor process %d did not answer \"%s\" within %g s", p.pid, op, seconds); return nil; }
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY) { snprintf(why, cap, "donor process %d went away during \"%s\" (%s)", p.pid, op, reply ? xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION) ?: "XPC error" : "no reply"); return nil; }
    return reply;
}
static int op_start(void *ctx, char *why, size_t cap) {
    (void)ctx; pthread_mutex_lock(&g_mu);
    if (!g_donors) g_donors = [NSMutableArray array];
    int i = g_used < (int)g_donors.count ? g_used : start_one(why, cap);
    if (i >= 0 && g_donors[(NSUInteger)i].gone) { snprintf(why, cap, "donor process %d, started early, has ended", g_donors[(NSUInteger)i].pid); i = -1; }
    if (i >= 0) g_used++;
    pthread_mutex_unlock(&g_mu); return i;
}
static uint64_t op_available(void *ctx, int donor) {
    (void)ctx; char why[256] = ""; xpc_object_t r = call(donor, DM_DONOR_OP_AVAILABLE, 0, why, sizeof why, 2);
    if (r) {
        const char *error = xpc_dictionary_get_string(r, DM_DONOR_ERROR); xpc_object_t n = xpc_dictionary_get_value(r, DM_DONOR_AVAILABLE);
        if (!error && n && xpc_get_type(n) == XPC_TYPE_UINT64) return xpc_dictionary_get_uint64(r, DM_DONOR_AVAILABLE);
        snprintf(why, sizeof why, "%s", error ?: "its answer carried no number");
    }
    fprintf(stderr, "[dm] [mem] RAM donor: donor %d says nothing about its memory: %s\n", donor, why); return 0;
}
static int op_map(void *ctx, int donor, uintptr_t address, size_t size, char *why, size_t cap) {
    (void)ctx; char reason[200] = ""; xpc_object_t r = call(donor, DM_DONOR_OP_CREATE, size, reason, sizeof reason, 30);
    if (!r) { snprintf(why, cap, "donor %d: %s", donor, reason); return -1; }
    const char *error = xpc_dictionary_get_string(r, DM_DONOR_ERROR);
    if (error) { snprintf(why, cap, "donor %d: it could not make %.0f MB: %s", donor, size / 1048576.0, error); return -1; }
    xpc_object_t sh = xpc_dictionary_get_value(r, DM_DONOR_SHMEM);
    if (!sh || xpc_get_type(sh) != XPC_TYPE_SHMEM) { snprintf(why, cap, "donor %d: its answer carried no shared memory", donor); return -1; }
    void *temporary = NULL; size_t n = xpc_shmem_map(sh, &temporary);
    if (!temporary || n < size) { if (temporary) mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)temporary, n); snprintf(why, cap, "xpc_shmem_map gave %zu of %zu bytes", temporary ? n : 0, size); return -1; }
    mach_vm_address_t target = address; vm_prot_t current = 0, maximum = 0;
    kern_return_t k = mach_vm_remap(mach_task_self(), &target, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), (mach_vm_address_t)temporary, false, &current, &maximum, VM_INHERIT_SHARE);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)temporary, n);
    if (k != KERN_SUCCESS) { snprintf(why, cap, "mach_vm_remap of the shared memory to %#lx failed: %s", (unsigned long)address, mach_error_string(k)); return -1; }
    if (target != address || (current & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) { snprintf(why, cap, "the shared memory landed at %#llx (protection %d), not read-write at %#lx", target, current, (unsigned long)address); return -1; }
    return 0;
}
static void op_end(void *ctx) {
    (void)ctx; pthread_mutex_lock(&g_mu); NSArray<DmDonorProc *> *donors = [g_donors copy]; [g_donors removeAllObjects]; g_used = 0; pthread_mutex_unlock(&g_mu);
    for (DmDonorProc *p in donors) { if (p.conn) xpc_connection_cancel(p.conn); [p.ext _kill:SIGKILL]; fprintf(stderr, "[dm] [mem] RAM donor: ended donor process %d\n", p.pid); }
}
static void back(const dm_donor_range *ranges, int count) {
    pthread_mutex_lock(&g_mu); g_back_started = 1; pthread_mutex_unlock(&g_mu);
    const dm_donor_ops ops = {op_start, op_available, op_map, op_end, NULL};
    dm_donor_back(ranges, count, &ops, 4); op_end(NULL);
}
__attribute__((constructor)) static void ram_donor_attach(void) {
    static const dm_donor_hooks hooks = {back, dm_donor_run, dm_donor_zero}; svc_donor_attach(&hooks);
}
void dm_ram_donor_prestart(void) {
    if (!dm_donor_enabled()) return;
    const char *files = getenv("DM_GUEST_FILE"); if (files && *files && atoi(files) > 0) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pthread_mutex_lock(&g_mu);
        if (!g_back_started && g_used == (int)g_donors.count) { char why[256] = ""; if (start_one(why, sizeof why) < 0) fprintf(stderr, "[dm] [mem] RAM donor: early start: %s\n", why); }
        pthread_mutex_unlock(&g_mu);
    });
}
#endif
