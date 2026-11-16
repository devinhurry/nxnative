// A blocked cold function build must not block cached lookups, duplicate jobs or lose its shader owner.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t *g_mod;int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static int checks,failed;
#define CHECK(c,label) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s (line %d)\n",label,__LINE__);}}while(0)
int main(void){@autoreleasepool{
    mtl_init();NSError *error=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nconstant int target[[function_constant(0)]];\nfragment float4 main0_f(){return target==0?float4(1,0,0,1):float4(0,1,0,1);}\n" options:nil error:&error];
    CHECK(lib!=nil,"specialization fixture compiles");if(!lib)return 1;
    NvShader *fs=[NvShader new];fs->rf.nfc=1;fs->bflib=lib;fs->bflib_state=1;strcpy(fs->key,"bf-async-fixture");
    int fx[32]={0};uint8_t lm[8];memset(lm,0xff,8);lm[0]=0;
    id<MTLFunction> red=bf_fn(fs,fx,1,lm);CHECK(red!=nil,"warm caller waits for its completed function");
    dispatch_suspend(bf_queue());fx[0]=1;
    CHECK(bf_fn_async(fs,fx,1,lm)==nil,"runtime cold miss returns while its build queue is blocked");
    CHECK(fs->bffn.count==2,"one job is created for the cold specialization");
    CHECK(bf_fn_async(fs,fx,1,lm)==nil && fs->bffn.count==2,"repeated pending lookup does not enqueue again");
    fx[0]=0;CHECK(bf_fn_async(fs,fx,1,lm)==red,"already cached function remains immediately available");fx[0]=1;
    __weak NvShader *live=fs;fs=nil;
    CHECK(live!=nil,"queued work owns its shader after the caller releases it");fs=live;dispatch_resume(bf_queue());
    id<MTLFunction> green=bf_fn(fs,fx,1,lm);CHECK(green!=nil && live!=nil,"pending function finishes with its shader alive");
    CHECK(bf_fn_async(fs,fx,1,lm)==green,"completed function is published to runtime lookup");
    dispatch_group_t group=dispatch_group_create();
    const int *fxp=fx;const uint8_t *lmp=lm;
    for(int i=0;i<12;i++)dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool{
        id<MTLFunction> f=bf_fn(fs,fxp,1,lmp);assert(f==green);
    }});
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,5000000000ll))==0 && fs->bffn.count==2,"concurrent warm lookups share the completed entry");
    NvShader *bad=[NvShader new];bad->bflib_state=2;bad->rf.nfc=1;
    CHECK(bf_fn(bad,fx,1,lm)==nil,"failed library completes without a stuck waiter");
    CHECK(bf_fn_async(bad,fx,1,lm)==nil && bad->bffn.count==1,"failed specialization is remembered once");
    printf("feedback functions: %d/%d checks passed\n",checks-failed,checks);return failed?1:0;
}}
