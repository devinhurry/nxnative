// Standalone CPU/Metal experiment using the same backing helper as hle_svc.c.
// Build/run commands and interpretation: docs/experiments/file-backed-memory.md.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <mach/mach.h>
#include <sys/resource.h>
#include <time.h>
#include "../file_backed_heap.h"

static double seconds(void) {
    struct timespec t; assert(!clock_gettime(CLOCK_MONOTONIC, &t));
    return t.tv_sec + t.tv_nsec / 1e9;
}
static uint32_t pattern(uint32_t i) {
    uint32_t x = i * 747796405u + 2891336453u;
    uint32_t w = ((x >> ((x >> 28u) + 4u)) ^ x) * 277803737u;
    return (w >> 22u) ^ w;
}
static void fill(uint32_t *p, size_t n) {
    for (size_t i = 0; i < n / 4; i++) p[i] = pattern((uint32_t)i);
}
static void verify(const uint32_t *p, size_t n, uint32_t mask) {
    for (size_t i = 0; i < n / 4; i++) assert(p[i] == (pattern((uint32_t)i) ^ mask));
}
static void sample(const char *mode, const char *phase, void *p, size_t n, double elapsed, int rc, int err) {
    task_vm_info_data_t vi = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    assert(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &count) == KERN_SUCCESS);
    size_t page = (size_t)getpagesize(), incore = 0;
    char *vec = calloc(n / page, 1); assert(vec);
    assert(!mincore(p, n, vec));
    for (size_t i = 0; i < n / page; i++) if (vec[i] & MINCORE_INCORE) incore++;
    free(vec);
    struct rusage ru; assert(!getrusage(RUSAGE_SELF, &ru));
    printf("{\"mode\":\"%s\",\"phase\":\"%s\",\"mib\":%zu,\"ms\":%.3f,"
           "\"footprint_mib\":%.3f,\"resident_mib\":%.3f,\"internal_mib\":%.3f,"
           "\"compressed_mib\":%.3f,\"mapping_incore_mib\":%.3f,"
           "\"page_faults\":%ld,\"pageins\":%ld,\"rc\":%d,\"errno\":%d}\n",
           mode, phase, n >> 20, elapsed * 1000, vi.phys_footprint / 1048576.,
           vi.resident_size / 1048576., vi.internal / 1048576., vi.compressed / 1048576.,
           incore * page / 1048576., ru.ru_minflt, ru.ru_majflt, rc, err);
    fflush(stdout);
}
static const char *shader =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "uint pattern(uint i) {uint x=i*747796405u+2891336453u;"
    "uint w=((x>>((x>>28u)+4u))^x)*277803737u;return (w>>22u)^w;}\n"
    "kernel void check(device uint *p[[buffer(0)]],device uint *errors[[buffer(1)]],"
    "constant uint &words[[buffer(2)]],uint page[[thread_position_in_grid]]) {"
    "uint bad=0;for(uint j=0;j<words;j++){uint i=page*words+j;"
    "bad|=p[i]^pattern(i);p[i]^=0xa55a3cc3u;}errors[page]=bad;}";

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc < 3 || argc > 4 || (strcmp(argv[1], "anon") && strcmp(argv[1], "file") && strcmp(argv[1], "file-residency"))) {
        fprintf(stderr, "usage: bench_file_heap anon|file|file-residency <absolute scratch directory> [MiB, default 256]\n");
        return 2;
    }
    size_t mib = argc == 4 ? strtoul(argv[3], NULL, 10) : 256;
    assert(mib >= 1 && mib <= 2048);
    size_t n = mib << 20, page = (size_t)getpagesize();
    int file = strcmp(argv[1], "anon") != 0, residency = !strcmp(argv[1], "file-residency");
    // Surround the replacement mapping with owned guards. An invalid setup must
    // leave the reservation untouched and report its error, not silently fall back.
    uint8_t *whole = mmap(NULL, n + 2 * page, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(whole != MAP_FAILED); void *p = whole + page;
    assert(dm_file_heap_back(p, n, "relative") == -1 && errno == EINVAL);
    assert(dm_file_heap_back(p, n, "/dev/null/not-a-directory") == -1);
    assert(dm_file_heap_back((uint8_t *)p + 1, n, argv[2]) == -1 && errno == EINVAL);
    if (file) assert(!dm_file_heap_back(p, n, argv[2]));
    assert(!mprotect(p, n, PROT_READ | PROT_WRITE));
    sample(argv[1], "reserved", p, n, 0, 0, 0);
    double t = seconds(); fill(p, n);
    sample(argv[1], "cpu_write", p, n, seconds() - t, 0, 0);
    t = seconds(); verify(p, n, 0);
    sample(argv[1], "warm_read", p, n, seconds() - t, 0, 0);
    if (file) {
        t = seconds(); errno = 0; int rc = msync(p, n, MS_SYNC | MS_INVALIDATE), err = errno;
        sample(argv[1], "flush_invalidate", p, n, seconds() - t, rc, err); assert(!rc);
        t = seconds(); verify(p, n, 0);
        sample(argv[1], "refault_read", p, n, seconds() - t, 0, 0);
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); assert(dev);
    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:shader] options:nil error:&error];
    if (!lib) { fprintf(stderr, "Metal shader: %s\n", error.description.UTF8String); return 1; }
    id<MTLComputePipelineState> pipeline = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"check"] error:&error];
    assert(pipeline);
    id<MTLCommandQueue> queue = [dev newCommandQueue]; assert(queue);
    id<MTLBuffer> results = [dev newBufferWithLength:n / page * 4 options:MTLResourceStorageModeShared]; assert(results);
    // All references to the no-copy buffer must die before its mapping is unmapped.
    @autoreleasepool {
        id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:p length:n options:MTLResourceStorageModeShared deallocator:nil];
        assert(buf);
        uint64_t address = buf.gpuAddress;
        id<MTLResidencySet> resident = nil;
        if (residency) {
            t = seconds(); int rc = msync(p, n, MS_SYNC | MS_INVALIDATE), err = rc ? errno : 0;
            sample(argv[1], "flush_buffer_created_no_gpu", p, n, seconds() - t, rc, err); assert(!rc);
            verify(p, n, 0);
            MTLResidencySetDescriptor *desc = [MTLResidencySetDescriptor new]; desc.initialCapacity = 1;
            resident = [dev newResidencySetWithDescriptor:desc error:&error]; assert(resident);
            [resident addAllocation:buf]; [resident commit]; [resident requestResidency];
            t = seconds(); rc = msync(p, n, MS_SYNC | MS_INVALIDATE); err = rc ? errno : 0;
            sample(argv[1], "flush_explicit_residency", p, n, seconds() - t, rc, err);
            [resident endResidency]; [resident removeAllocation:buf]; [resident commit];
            t = seconds(); rc = msync(p, n, MS_SYNC | MS_INVALIDATE); err = rc ? errno : 0;
            sample(argv[1], "flush_end_residency_buffer_alive", p, n, seconds() - t, rc, err); assert(!rc);
            usleep(100000); // Probe asynchronous driver teardown, never a host synchronization rule.
            t = seconds(); rc = msync(p, n, MS_SYNC | MS_INVALIDATE); err = rc ? errno : 0;
            sample(argv[1], "flush_end_residency_buffer_alive_later", p, n, seconds() - t, rc, err); assert(!rc);
            verify(p, n, 0); assert(buf.gpuAddress == address);
            [resident addAllocation:buf]; [resident commit]; [resident requestResidency];
        }
        t = seconds();
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        [enc setBuffer:buf offset:0 atIndex:0]; [enc setBuffer:results offset:0 atIndex:1];
        uint32_t words = (uint32_t)(page / 4); [enc setBytes:&words length:4 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(n / page, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "Metal command: %s\n", cb.error.description.UTF8String); return 1;
        }
        uint32_t *errors = results.contents;
        for (size_t i = 0; i < n / page; i++) assert(!errors[i]);
        sample(argv[1], "gpu_read_write", p, n, seconds() - t, 0, 0);
        verify(p, n, 0xa55a3cc3u);
        if (file) {
            t = seconds(); errno = 0; int rc = msync(p, n, MS_SYNC | MS_INVALIDATE), err = errno;
            sample(argv[1], "flush_with_metal_buffer", p, n, seconds() - t, rc, err);
            verify(p, n, 0xa55a3cc3u);
        }
        if (residency) {
            [resident endResidency]; [resident removeAllocation:buf]; [resident commit];
            enc = nil; cb = nil;
            t = seconds(); int rc = msync(p, n, MS_SYNC | MS_INVALIDATE), err = rc ? errno : 0;
            sample(argv[1], "flush_gpu_complete_end_residency", p, n, seconds() - t, rc, err); assert(!rc);
            usleep(100000);
            t = seconds(); rc = msync(p, n, MS_SYNC | MS_INVALIDATE); err = rc ? errno : 0;
            sample(argv[1], "flush_gpu_complete_end_residency_later", p, n, seconds() - t, rc, err); assert(!rc);
            verify(p, n, 0xa55a3cc3u); assert(buf.gpuAddress == address);
        }
        buf = nil; enc = nil; cb = nil;
    }
    queue = nil; results = nil;
    // Driver teardown can be asynchronous. Observe it explicitly rather than
    // assuming a successful msync means the GPU's physical pages were evicted.
    usleep(100000);
    sample(argv[1], "metal_buffer_released", p, n, 0, 0, 0);
    if (file) {
        t = seconds(); errno = 0; int rc = msync(p, n, MS_SYNC | MS_INVALIDATE), err = errno;
        sample(argv[1], "flush_after_metal_release", p, n, seconds() - t, rc, err); assert(!rc);
        t = seconds(); verify(p, n, 0xa55a3cc3u);
        sample(argv[1], "refault_after_gpu", p, n, seconds() - t, 0, 0);
    }
    assert(!munmap(whole, n + 2 * page));
    return 0;
} }
