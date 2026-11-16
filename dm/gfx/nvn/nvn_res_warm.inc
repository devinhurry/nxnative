// An independent set prepares allocations before their first GPU use. The main
// residency set and its commit lock still own submission correctness and lifetime.
static pthread_mutex_t g_rw_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_rw_work=PTHREAD_COND_INITIALIZER,g_rw_idle=PTHREAD_COND_INITIALIZER;
static id<MTLResidencySet> g_rw_set;
static res_op *g_rw_q;static size_t g_rw_n,g_rw_cap;
static _Atomic int g_rw_started;
static _Atomic uint64_t g_rw_req,g_rw_done;
static uint64_t g_rw_batches,g_rw_prepare_ns,g_rw_wait_ns;
#ifndef NVN_RES_WARM_BATCH_BEGIN
#define NVN_RES_WARM_BATCH_BEGIN() ((void)0)
#endif
static void *res_warm_thread(void *unused) {
    (void)unused;pthread_setname_np("dm.res.warm");
    for(;;) {
        pthread_mutex_lock(&g_rw_mu);
        while(!g_rw_n)pthread_cond_wait(&g_rw_work,&g_rw_mu);
        res_op *q=g_rw_q;size_t n=g_rw_n;uint64_t target=g_rw_req;
        g_rw_q=NULL;g_rw_n=g_rw_cap=0;
        pthread_mutex_unlock(&g_rw_mu);
        uint64_t start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        @autoreleasepool {
            NVN_RES_WARM_BATCH_BEGIN();
            int added=0;
            for(size_t i=0;i<n;i++) {
                id<MTLAllocation> r=(__bridge id<MTLAllocation>)q[i].o;
                if(q[i].add){[g_rw_set addAllocation:r];added=1;}
                else [g_rw_set removeAllocation:r];
            }
            [g_rw_set commit];
            if(added)[g_rw_set requestResidency];
            for(size_t i=0;i<n;i++)CFRelease(q[i].o);
            free(q);
        }
        pthread_mutex_lock(&g_rw_mu);
        g_rw_prepare_ns+=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-start;g_rw_batches++;
        g_rw_done=target;   // released batch references and autoreleases before publishing completion
        pthread_cond_broadcast(&g_rw_idle);
        pthread_mutex_unlock(&g_rw_mu);
    }
    return NULL;
}
static void res_warm_put(id<MTLAllocation> r,int add) {   // caller holds g_res_mu: preserve the main queue's ordering
    if(!g_res)return;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        const char *e=getenv("DM_RES_WARM");
        if(e && !atoi(e)){MLOG("background residency preparation off (DM_RES_WARM)");return;}
        MTLResidencySetDescriptor *d=[MTLResidencySetDescriptor new];d.initialCapacity=256;d.label=@"background resource preparation";
        NSError *error=nil;g_rw_set=[g_dev newResidencySetWithDescriptor:d error:&error];
        if(!g_rw_set){MLOG("[RED] background residency set unavailable: %s; keeping native commits",error.localizedDescription.UTF8String);return;}
        pthread_t thread;int err=pthread_create(&thread,NULL,res_warm_thread,NULL);
        if(err){g_rw_set=nil;MLOG("[RED] background residency thread unavailable (%d); keeping native commits",err);return;}
        pthread_detach(thread);g_rw_started=1;
        MLOG("background residency preparation on (DM_RES_WARM=0 disables)");
    });
    if(!g_rw_started)return;
    pthread_mutex_lock(&g_rw_mu);
    if(g_rw_n==g_rw_cap){g_rw_cap=g_rw_cap?g_rw_cap*2:256;g_rw_q=realloc_or_die(g_rw_q,g_rw_cap*sizeof *g_rw_q,"the residency preparation queue");}
    g_rw_q[g_rw_n++]=(res_op){CFBridgingRetain(r),add};g_rw_req++;
    pthread_cond_signal(&g_rw_work);
    pthread_mutex_unlock(&g_rw_mu);
}
static void res_warm_wait(void) {
    if(!g_rw_started)return;
    uint64_t target=g_rw_req;if(g_rw_done>=target)return;
    uint64_t start=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    pthread_mutex_lock(&g_rw_mu);
    while(g_rw_done<target)pthread_cond_wait(&g_rw_idle,&g_rw_mu);
    g_rw_wait_ns+=clock_gettime_nsec_np(CLOCK_UPTIME_RAW)-start;
    pthread_mutex_unlock(&g_rw_mu);
}
static void res_warm_report(void) {
    if(!g_rw_started)return;
    static uint64_t prev[3];uint64_t now[3];
    pthread_mutex_lock(&g_rw_mu);now[0]=g_rw_batches;now[1]=g_rw_prepare_ns;now[2]=g_rw_wait_ns;pthread_mutex_unlock(&g_rw_mu);
    MLOG("residency preparation since last report: %llu batches, worker %.3f ms, caller waits %.3f ms",
        (unsigned long long)(now[0]-prev[0]),(now[1]-prev[1])/1e6,(now[2]-prev[2])/1e6);
    memcpy(prev,now,sizeof now);
}
