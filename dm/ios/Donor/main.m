// Donor extension: MIT nxnative-mkw base with guest-range release, footprint
// reporting and lifecycle handling. See README.md and LICENSE.
@import Foundation;
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <xpc/xpc.h>
#import "../../host/ram_donor_proto.h"

extern kern_return_t mach_vm_allocate(vm_map_t, mach_vm_address_t *, mach_vm_size_t, int);
extern kern_return_t mach_vm_deallocate(vm_map_t, mach_vm_address_t, mach_vm_size_t);
#ifndef VM_FLAGS_PURGABLE
#define VM_FLAGS_PURGABLE 0x2
#endif
@interface NSXPCListenerEndpoint (DmPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end
static struct { mach_vm_address_t address; mach_vm_size_t size; } g_regions[1024];
static int g_regions_n;
static void handle(xpc_connection_t c, xpc_object_t m) {
    if (xpc_get_type(m) != XPC_TYPE_DICTIONARY) return;
    xpc_object_t r = xpc_dictionary_create_reply(m); if (!r) return;
    const char *op = xpc_dictionary_get_string(m, DM_DONOR_OP); char error[256] = "";
    if (!op) snprintf(error, sizeof error, "no operation");
    else if (!strcmp(op, DM_DONOR_OP_CREATE)) {
        uint64_t size = xpc_dictionary_get_uint64(m, DM_DONOR_SIZE); mach_vm_address_t a = 0;
        if (!size) snprintf(error, sizeof error, "refusing a region of 0 bytes");
        else if (g_regions_n == 1024) snprintf(error, sizeof error, "this donor already gave %d regions", g_regions_n);
        else {
            kern_return_t k = mach_vm_allocate(mach_task_self(), &a, size, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);
            if (k != KERN_SUCCESS) snprintf(error, sizeof error, "mach_vm_allocate of %llu bytes failed: %s", size, mach_error_string(k));
            else {
                // Purgeable objects are created nonvolatile; no volatile transition is made.
                xpc_object_t sh = xpc_shmem_create((void *)a, (size_t)size);
                if (sh) { g_regions[g_regions_n++] = (typeof(g_regions[0])){a, size}; xpc_dictionary_set_value(r, DM_DONOR_SHMEM, sh); }
                else { mach_vm_deallocate(mach_task_self(), a, size); snprintf(error, sizeof error, "xpc_shmem_create returned NULL for %llu bytes", size); }
            }
        }
    } else if (!strcmp(op, DM_DONOR_OP_RELEASE)) {
        for (int i = 0; i < g_regions_n; i++) mach_vm_deallocate(mach_task_self(), g_regions[i].address, g_regions[i].size);
        g_regions_n = 0;
    } else if (!strcmp(op, DM_DONOR_OP_AVAILABLE)) xpc_dictionary_set_uint64(r, DM_DONOR_AVAILABLE, (uint64_t)os_proc_available_memory());
    else if (!strcmp(op, DM_DONOR_OP_FOOTPRINT)) {
        task_vm_info_data_t info = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        uint64_t bytes = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS ? info.phys_footprint : 0;
        xpc_dictionary_set_uint64(r, DM_DONOR_OP_FOOTPRINT, bytes);
    } else snprintf(error, sizeof error, "unknown operation \"%s\"", op);
    if (*error) { xpc_dictionary_set_string(r, DM_DONOR_ERROR, error); NSLog(@"RAM donor %d: %s", getpid(), error); }
    xpc_connection_send_message(c, r);
}
static void allow_any_class(void) {}
__attribute__((constructor)) static void allow_endpoint_decoding(void) {
    Method m = class_getInstanceMethod(NSClassFromString(@"NSXPCDecoder"), NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:"));
    if (m) method_setImplementation(m, (IMP)allow_any_class);
    else NSLog(@"RAM donor %d: NSXPCDecoder's class check was not found: the app's endpoint may not decode", getpid());
}
@interface DmRamDonorHandler : NSObject <NSExtensionRequestHandling>
@end
@implementation DmRamDonorHandler { xpc_connection_t _app; }
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)ctx {
    NSExtensionItem *item = ctx.inputItems.firstObject;
    id ep = item.userInfo[@"endpoint"];
    if (ep && ![ep isKindOfClass:NSXPCListenerEndpoint.class]) { NSLog(@"RAM donor %d: the endpoint decoded as %@, not an NSXPCListenerEndpoint", getpid(), [ep class]); return; }
    xpc_object_t endpoint = ep ? ((NSXPCListenerEndpoint *)ep)._endpoint : nil;
    if (!endpoint || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT) { NSLog(@"RAM donor %d: the request carried no endpoint (userInfo keys %@): nothing to serve", getpid(), item.userInfo.allKeys); return; }
    _app = xpc_connection_create_from_endpoint((xpc_endpoint_t)endpoint);
    xpc_connection_t app = _app;
    xpc_connection_set_event_handler(app, ^(xpc_object_t ev) {
        if (xpc_get_type(ev) == XPC_TYPE_ERROR) { NSLog(@"RAM donor %d: the app's connection ended (%s), exiting", getpid(), xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION)); exit(0); }
        handle(app, ev);
    });
    xpc_connection_resume(app);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0); xpc_dictionary_set_string(hello, DM_DONOR_OP, "hello"); xpc_connection_send_message(app, hello);
}
@end
