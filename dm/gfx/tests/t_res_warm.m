// Preparation may overlap callers; commits wait for prior work, preserve order
// and release removed allocations. Exercise both the optional and native paths.
static void warm_batch_gate(void);
#define NVN_RES_WARM_BATCH_BEGIN() warm_batch_gate()
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t *g_mod;int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static int checks,failed;
#define CHECK(c,label) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",label);}}while(0)
static dispatch_semaphore_t entered,release_batch;
static _Atomic int gate,worker_seen;
static pthread_t main_thread;
static void warm_batch_gate(void){
    worker_seen=!pthread_equal(pthread_self(),main_thread);
    if(atomic_exchange(&gate,0)){
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release_batch,DISPATCH_TIME_FOREVER);
    }
}
static int wait_sem(dispatch_semaphore_t s,int ms){return dispatch_semaphore_wait(s,dispatch_time(DISPATCH_TIME_NOW,(int64_t)ms*NSEC_PER_MSEC))==0;}
static id<MTLBuffer> buffer(void){return[g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];}
static int contained(id<MTLAllocation> r){pthread_mutex_lock(&g_res_commit_mu);int yes=[g_res containsAllocation:r];pthread_mutex_unlock(&g_res_commit_mu);return yes;}
static void benchmark(void){
    for(int trial=0;trial<12;trial++){@autoreleasepool{
        uint64_t start=bp_now();NSMutableArray<id<MTLBuffer>> *buffers=[NSMutableArray array];
        for(int i=0;i<64;i++){id<MTLBuffer>b=[g_dev newBufferWithLength:256u<<10 options:MTLResourceStorageModeShared];[buffers addObject:b];res_add(b);}
        uint64_t allocated=bp_now();res_commit();uint64_t prepared=bp_now();
        id<MTLCommandBuffer>cb=[g_q commandBuffer];[cb useResidencySet:g_res];id<MTLBlitCommandEncoder>bl=[cb blitCommandEncoder];
        for(id<MTLBuffer>b in buffers)[bl fillBuffer:b range:NSMakeRange(0,b.length) value:0x4c];[bl endEncoding];[cb commit];[cb waitUntilCompleted];
        uint64_t complete=bp_now();int good=!cb.error;
        for(id<MTLBuffer>b in buffers)good&=((const uint8_t*)b.contents)[b.length-1]==0x4c;
        CHECK(good,"benchmark GPU output");
        printf("bench warm=%d trial=%d allocation_us=%.3f boundary_us=%.3f gpu_completion_us=%.3f total_us=%.3f\n",!!g_rw_started,trial,(allocated-start)/1000.,(prepared-allocated)/1000.,(complete-prepared)/1000.,(complete-start)/1000.);
        for(id<MTLBuffer>b in buffers)res_remove(b);res_commit();
    }}
}
int main(void){@autoreleasepool{
    main_thread=pthread_self();entered=dispatch_semaphore_create(0);release_batch=dispatch_semaphore_create(0);
    mtl_init();res_commit();
    const char *env=getenv("DM_RES_WARM");int enabled=!env||atoi(env)!=0;
    id<MTLBuffer>a=buffer();res_add(a);res_commit();
    CHECK(contained(a),"main set includes committed resource");
    CHECK(!!g_rw_started==enabled,"default and explicit preparation switch");
    if(enabled){
        CHECK(worker_seen,"preparation runs on a different thread");
        CHECK([g_rw_set containsAllocation:a],"independent preparation set includes resource");
        gate=1;id<MTLBuffer>b=buffer(),c=buffer();res_add(b);
        CHECK(wait_sem(entered,2000),"worker is held outside residency locks");
        dispatch_semaphore_t committed=dispatch_semaphore_create(0),added=dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{res_commit();dispatch_semaphore_signal(committed);});
        CHECK(!wait_sem(committed,20),"commit waits for preceding preparation");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{res_add(c);dispatch_semaphore_signal(added);});
        CHECK(wait_sem(added,200),"new resources enqueue while preparation is held");
        dispatch_semaphore_signal(release_batch);
        CHECK(wait_sem(committed,2000),"commit resumes after preparation");res_commit();
        CHECK(contained(b)&&contained(c),"all resources preceding commit are included");
        res_remove(b);res_remove(c);res_commit();
        CHECK(!contained(b)&&!contained(c),"main set removes resources");
        CHECK(![g_rw_set containsAllocation:b]&&![g_rw_set containsAllocation:c],"preparation set follows removals");
    }
    __weak id<MTLBuffer> weak=nil;
    @autoreleasepool{id<MTLBuffer> victim=buffer();weak=victim;res_add(victim);res_commit();if(enabled)gate=1;res_remove(victim);}
    if(enabled)CHECK(wait_sem(entered,2000),"removal batch is held");
    CHECK(weak!=nil,"pending removal keeps its allocation alive");
    if(enabled)dispatch_semaphore_signal(release_batch);
    @autoreleasepool{res_commit();}
    CHECK(weak==nil,"both sets and pending queues release committed removals");
    __block _Atomic int bad=0;dispatch_group_t group=dispatch_group_create();
    for(int t=0;t<4;t++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        for(int i=0;i<20;i++){@autoreleasepool{id<MTLBuffer>r=buffer();res_add(r);res_commit();if(!contained(r))bad=1;res_remove(r);res_commit();}}
    }});
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0,"concurrent producers and committers finish");
    CHECK(!bad,"racing commits preserve every preceding addition");res_commit();
    if(enabled)CHECK(g_rw_done==g_rw_req,"all prior preparation is complete");
    // Real GPU consumption after the native boundary, with the same residency set.
    id<MTLCommandBuffer>cb=[g_q commandBuffer];[cb useResidencySet:g_res];
    id<MTLBlitCommandEncoder>bl=[cb blitCommandEncoder];[bl fillBuffer:a range:NSMakeRange(0,a.length) value:0x6d];[bl endEncoding];
    [cb commit];[cb waitUntilCompleted];CHECK(!cb.error,"GPU command completes without residency errors");
    int ok=1;for(unsigned i=0;i<a.length;i++)ok&=((const uint8_t*)a.contents)[i]==0x6d;
    CHECK(ok,"GPU writes every expected byte");res_remove(a);res_commit();
    CHECK(!res_pending(),"main queue is drained");
    if(getenv("DM_TEST_RES_WARM_BENCH"))benchmark();
    printf("resource preparation (%s): %d/%d checks passed\n",enabled?"on":"off",checks-failed,checks);
    return failed?1:0;
}}
