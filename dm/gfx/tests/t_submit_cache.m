// Incremental address-index mutations and borrowed program hits use the real production helpers.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t *g_mod;int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
static int checks,failed;
#define CHECK(c,label) do{checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s (line %d)\n",label,__LINE__);}}while(0)
static uint64_t random_state=91201;
static unsigned next(void){random_state^=random_state<<13;random_state^=random_state>>7;random_state^=random_state<<17;return (unsigned)random_state;}
static void valid(void){
    unsigned char *seen=calloc((size_t)g_npool+1,1);int ok=1;
    for(int i=0;i<g_npool;i++){int k=g_pidx[i];if(k<0||k>=g_npool||seen[k]){ok=0;break;}seen[k]=1;if(i&&g_pools[g_pidx[i-1]].lo>g_pools[k].lo)ok=0;}
    free(seen);CHECK(ok,"index sorted with each live slot exactly once");
}
static void index_cases(void){
    g_cap=g_pidx_cap=520;g_pools=calloc(g_cap,sizeof *g_pools);g_pidx=calloc(g_pidx_cap,sizeof *g_pidx);g_npool=512;
    for(int i=0;i<g_npool;i++)g_pools[i]=(pool_ent){.lo=(next()%64+1)*65536,.hi=(next()%64+65)*65536};
    pidx_sort();
    for(int i=0;i<3000;i++){
        int k=(int)(next()%(unsigned)g_npool);pidx_del(k);g_pools[k]=g_pools[--g_npool];valid();
        uintptr_t key=(next()%64+1)*65536;g_pools[g_npool++]=(pool_ent){.lo=key,.hi=key+131072};pidx_add();valid();
        g_plast=-1;int hit=pool_held(key+65535,1);CHECK(hit>=0&&key+65535<g_pools[hit].hi,"lookup remains valid with equal starts and overlaps");
    }
    g_cap=1024;g_pools=realloc(g_pools,(size_t)g_cap*sizeof *g_pools);
    for(int i=0;i<40;i++){g_pools[g_npool++]=(pool_ent){.lo=(uintptr_t)(i+100)*65536,.hi=(uintptr_t)(i+102)*65536};pidx_add();valid();}
    CHECK(g_pidx_cap>=g_npool,"incremental insertion grows index capacity");
    while(g_npool){pidx_del(0);g_pools[0]=g_pools[--g_npool];valid();}
    free(g_pools);free(g_pidx);g_pools=NULL;g_pidx=NULL;g_cap=g_pidx_cap=0;g_pidx_ok=0;g_plast=-1;
}
static void program_cases(void){
    NvProg *a=[NvProg new],*b=[NvProg new];prog_t p={.serial=992001},q={.serial=992002};
    serial_put(p.serial,a);serial_put(q.serial,b);
    __unsafe_unretained NvProg *got;PROG_BORROW(got,&p);CHECK(got==a,"cold borrowed lookup resolves the registry");
    for(int i=0;i<100;i++){PROG_BORROW(got,&p);CHECK(got==a,"cache hit keeps the registry-owned program");}
    __weak NvProg *weak=a;a=nil;CHECK(weak!=nil,"borrowed lookup has a real owner");
    serial_put(p.serial,b);PROG_BORROW(got,&p);CHECK(got==b,"serial replacement invalidates the cached result");
    p.serial=q.serial;PROG_BORROW(got,&p);CHECK(got==b,"descriptor serial changes invalidate the cached result");
    PROG_BORROW(got,&q);CHECK(got==b,"different descriptor refreshes the cache");
    PROG_BORROW(got,NULL);CHECK(got==nil,"null program preserves native nil behavior");
}
int main(void){@autoreleasepool{
    index_cases();program_cases();
    // Real registered buffers and atomic sparse-run replacements keep their generations and index coherent.
    mtl_init();uint8_t *mem=mmap(NULL,0x40000,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);CHECK(mem!=MAP_FAILED,"pool memory allocated");if(mem==MAP_FAILED)return 1;
    mtl_pool_add(mem,0x20000);mtl_pool_add(mem+0x20000,0x20000);
    void *b;uint64_t off,gpu;CHECK(mtl_gpu_addr((uintptr_t)mem+8,16,&b,&off,&gpu),"registered pool resolves");
    uint64_t gen=g_pool_gen;const void *del[]={mem,mem+0x20000},*add[]={mem};uint64_t sizes[]={0x40000};
    mtl_pool_replace(del,2,add,sizes,1);CHECK(g_pool_gen>gen,"replacement invalidates per-thread address caches");
    CHECK(mtl_gpu_addr((uintptr_t)mem+0x30000,16,&b,&off,&gpu),"replacement range resolves atomically");
    pidx_sort();valid();mtl_pool_del(mem);CHECK(!mtl_gpu_addr((uintptr_t)mem+8,16,&b,&off,&gpu),"removed pool is no longer addressable");
    pidx_sort();valid();
    printf("submit cache: %d/%d checks passed\n",checks-failed,checks);return failed?1:0;
}}
