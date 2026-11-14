// CPU-only queue snapshot check and optional --bench: compact recordings are
// expanded into the same owned canonical stream as uncompressed recordings.
#include <stdlib.h>
#include <dispatch/dispatch.h>
static void *snapshot_realloc(void *p, size_t n);
#define realloc snapshot_realloc
#define mtl_prepare snapshot_prepare
#include "../nvn/hle_nvn.c"
#undef realloc
#undef mtl_prepare
#include <time.h>

module_t *g_mod; int g_nmod;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void snapshot_prepare(void) {}
static _Thread_local int observe_copy;
static dispatch_semaphore_t copying, submitted;
static void *snapshot_realloc(void *p, size_t n) {
    if (observe_copy) dispatch_semaphore_signal(copying);
    return realloc(p, n);
}

typedef struct { uint8_t *bytes; uint64_t control[128]; pool_t pool; NVNcommandBuffer cmd; uint64_t handle; } recording;
static int checks, failed;
static int measure_snapshot;
static uint64_t snapshot_ns;
#define CHECK(c, name) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", name); } } while (0)

static recording *record(int compact, int meshes, int waits) {
    recording *r = calloc(1, sizeof *r); if (!r) abort();
    r->bytes = calloc(1, 4 << 20); if (!r->bytes) abort();
    r->pool.mem = r->bytes; r->pool.size = 4 << 20;
    h_nvnCommandBufferInitialize(&r->cmd, NULL);
    h_nvnCommandBufferAddCommandMemory(&r->cmd, (NVNmemoryPool *)&r->pool, 0, r->pool.size);
    h_nvnCommandBufferAddControlMemory(&r->cmd, r->control, sizeof r->control);
    h_nvnCommandBufferBeginRecording(&r->cmd); g_rec_compact = compact;
    const float viewport[] = {0, 0, 1280, 720};
    h_nvnCommandBufferSetViewports(&r->cmd, 0, 1, viewport);
    NVNbufferRange ub[4], vb[2] = {{0x80000, 4096}, {0x90000, 4096}};
    static uint32_t event_word; ev_t event = {.val = &event_word};
    for (int i = 0; i < meshes; i++) {
        for (int k = 0; k < 4; k++) ub[k] = (NVNbufferRange){0x10000 + (uint64_t)(i * 4 + k) * 256, 64};
        h_nvnCommandBufferBindUniformBuffers(&r->cmd, NVN_SHADER_STAGE_VERTEX, 0, 4, ub);
        h_nvnCommandBufferBindVertexBuffers(&r->cmd, 0, 2, vb);
        h_nvnCommandBufferSetStencilRef(&r->cmd, NVN_FACE_FRONT_AND_BACK, i & 255);
        h_nvnCommandBufferDrawElementsBaseVertex(&r->cmd, NVN_DRAW_PRIMITIVE_TRIANGLES, NVN_INDEX_TYPE_UNSIGNED_SHORT, 36, 0xa0000, i);
        if (waits && i == meshes / 2) h_nvnCommandBufferWaitEvent(&r->cmd, (NVNevent *)&event, NVN_EVENT_WAIT_MODE_EQUAL, 1);
    }
    r->handle = h_nvnCommandBufferEndRecording(&r->cmd); return r;
}
static void recording_free(recording *r) { h_nvnCommandBufferFinalize(&r->cmd); free(r->bytes); free(r); }
static nq_job *flatten(recording *r) {
    nq_job *j = calloc(1, sizeof *j); j->objects.klen = 16;
    nq_flatten(j, (const uint8_t *)(uintptr_t)r->handle); nq_end(j);
    uint64_t start = measure_snapshot ? now_ns() : 0;
    pthread_mutex_lock(&g_sub_mu); nq_snapshot(j); pthread_mutex_unlock(&g_sub_mu);
    if (measure_snapshot) snapshot_ns += now_ns() - start;
    return j;
}
static void job_free(nq_job *j) {
    for (nq_node *n = j->first, *next; n; n = next) { next = n->next; free(n->bytes); free(n->signals); free(n); }
    nq_job_free(j);
}
static void same_stream(int meshes, int waits) {
    recording *compact = record(1, meshes, waits), *plain = record(0, meshes, waits);
    nq_job *a = flatten(compact), *b = flatten(plain); nq_node *x = a->first, *y = b->first;
    for (; x && y; x = x->next, y = y->next) {
        CHECK(x->kind == y->kind && x->length == y->length, "compact and canonical continuations have the same layout");
        if (x->kind == NQ_COMMANDS && x->length == y->length) CHECK(!memcmp(x->bytes, y->bytes, x->length), "every expanded draw/binding byte matches canonical recording");
        if (x->kind == NQ_EVENT) CHECK(x->event == y->event && x->mode == y->mode && x->value == y->value, "queue wait keeps its event and predicate");
    }
    CHECK(!x && !y, "compact and canonical streams split at the same queue waits");
    if (!waits) {
        size_t bytes; uint8_t *linear = nvn_rec_linear(plain->handle, &bytes);
        CHECK(a->first && !a->first->next && a->first->length == bytes && !memcmp(a->first->bytes, linear, bytes), "owned stream matches the canonical stream used by capture/replay diagnostics");
        free(linear);
    }
    job_free(a); job_free(b); recording_free(compact); recording_free(plain);
}
typedef struct { queue_t queue; uint64_t handle; } copy_job;
static void *submit_while_replay_locked(void *arg) {
    copy_job *j = arg; observe_copy = 1; nvn_queue_submit(&j->queue, 1, &j->handle);
    dispatch_semaphore_signal(submitted); return NULL;
}
static void copy_overlaps_replay(void) {
    recording *r = record(1, 37, 0); copy_job work = {.queue = {.serial = 0x123456}, .handle = r->handle};
    copying = dispatch_semaphore_create(0); submitted = dispatch_semaphore_create(0);
    nvn_queue_test_hold(1); pthread_mutex_lock(&g_sub_mu); pthread_t thread;
    if (pthread_create(&thread, NULL, submit_while_replay_locked, &work)) abort();
    CHECK(!dispatch_semaphore_wait(copying, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)), "command assembly progresses while earlier replay holds the renderer lock");
    CHECK(dispatch_semaphore_wait(submitted, DISPATCH_TIME_NOW) != 0, "descriptor preparation still waits for the renderer lock before enqueue");
    pthread_mutex_unlock(&g_sub_mu);
    if (dispatch_semaphore_wait(submitted, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC))) exit(2);
    pthread_join(thread, NULL);
    pthread_mutex_lock(&nq_mu); nq_queue *q = nq_get(&work.queue); nq_job *j = q->first; q->first = q->last = NULL;
    nq_put(q->tail); q->tail = NULL; nq_put(j->receipt); pthread_mutex_unlock(&nq_mu);
    job_free(j); recording_free(r);
}
static void bench(void) {
    recording *r = record(1, 4096, 0);
    const int runs = 300; measure_snapshot = 1; snapshot_ns = 0; uint64_t start = now_ns(); size_t bytes = 0;
    for (int i = 0; i < runs; i++) { nq_job *j = flatten(r); bytes = j->first->length; job_free(j); }
    uint64_t elapsed = now_ns() - start;
    printf("queue snapshot: 4096 meshes, %zu canonical bytes, %.3f ms/flatten (%d runs)\n", bytes, elapsed / (double)runs / 1e6, runs);
    printf("descriptor pass under renderer lock: %.3f ms/flatten\n", snapshot_ns / (double)runs / 1e6); measure_snapshot = 0;
    recording_free(r);
}
int main(int argc, char **argv) {
    same_stream(1, 0); same_stream(37, 1); same_stream(4096, 0);
    copy_overlaps_replay();
    printf("queue snapshot: %d checks, %d failed\n", checks, failed);
    if (argc > 1 && !strcmp(argv[1], "--bench")) bench();
    return failed != 0;
}
