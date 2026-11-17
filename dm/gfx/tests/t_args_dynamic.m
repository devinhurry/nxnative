// Reuse the real-Metal fixture; changed parameter bytes and known GPU colors are
// the oracle, not the cache implementation. Both new paths retain native fallbacks.
#define main args_key_fixture_main
#include "t_args_key.m"
#undef main
static int pad_on;
static uint8_t *scratch_bytes(uint64_t gpu,size_t bytes) {
    for(NvArena *a in g_sub_arenas)if(gpu>=a->gpu && gpu-a->gpu<=a->used && bytes<=a->used-(gpu-a->gpu))return a->cpu+(gpu-a->gpu);
    return NULL;
}
static uint64_t slot(int aid) {return ((uint64_t *)shader->ab_cpu)[aid];}
static void dynamic_encode(void) {args_dirty_all();encode();}
static void direct(uint8_t r,uint8_t g,uint8_t b,uint8_t a,const char *label) {
    image((const uint8_t[]){r,g,b,a},label);
}
static void copied_bytes(const uint8_t *source,size_t live,const char *label) {
    uint8_t *d=scratch_bytes(slot(0),4096);int good=d && !memcmp(d,source,live);
    if(d)for(size_t i=live;i<4096;i++)good&=d[i]==0;
    CHECK(good,label);
}
static void benchmark(void) {
    enum {N=5000};g_args_check=0;
    for(int trial=0;trial<3;trial++) {
        dynamic_encode();
        uint64_t copies=g_ub_short,full=g_stat_args_enc,patched=g_stat_args_key_patch;
        uint64_t start=bp_now();
        for(int i=0;i<N;i++){g_args_dirty[1]=1;encode_args_((id<MTLCommandEncoder>)g_enc,shader,1,0);}
        printf("dynamic benchmark pad=%d args=%d trial=%d: %.1f ns/call, padded copies=%llu, full=%llu, patches=%llu\n",pad_on,keyed,trial,(double)(bp_now()-start)/N,(unsigned long long)(g_ub_short-copies),(unsigned long long)(g_stat_args_enc-full),(unsigned long long)(g_stat_args_key_patch-patched));
        rp_end();CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"benchmark trial completes");mtl_sub_begin();
    }
}
int main(void) {@autoreleasepool {
    setenv("DM_NVN_TBDR","0",1);mtl_init();keyed=args_key_on();checking=args_key_check_on();
    const char *off=getenv("DM_NVN_UB_PAD_CACHE");pad_on=!(off && !strcmp(off,"0"));
    NSError *err=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]){return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1);}\n"
        "struct A{constant uint*p[[id(0)]];texture2d<float>t[[id(1)]];sampler s[[id(2)]];constant uint*sizes[[id(3)]];constant uint*d0[[id(4)]];constant uint*d2[[id(5)]];};\n"
        "fragment float4 f(constant A&a[[buffer(0)]]){float ok=(a.p[16]==17u && a.p[1000]==0u && a.sizes[0]>=256u)?1.0:0.0;return float4(a.p[0]/255.0,(a.d0[401]&255u)/255.0,(a.d2[8]&255u)/255.0,ok)*a.t.sample(a.s,float2(.5));}\n"
        options:nil error:&err];
    CHECK(lib!=nil,"dynamic/padded shader compiles");if(!lib){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 1;}
    shader=[NvShader new];shader->stage=1;strcpy(shader->key,"abcdef9988776655");
    shader->fn=[lib newFunctionWithName:@"f"];shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];shader->arg_len=shader->ae.encodedLength;
    shader->rf.nb=6;shader->rf.drv_read[0]=shader->rf.drv_read[2]=1;
    shader->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.reg=0,.aid=0,.fixw=1024};
    shader->rf.b[1]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.aid=1,.dtt=MTLTextureType2D};
    shader->rf.b[2]=(nvn_rbind){.kind=NVN_RB_SAMPT,.reg=0,.aid=2};
    shader->rf.b[3]=(nvn_rbind){.kind=NVN_RB_CBSIZE,.aid=3};
    shader->rf.b[4]=(nvn_rbind){.kind=NVN_RB_DRV0,.aid=4};shader->rf.b[5]=(nvn_rbind){.kind=NVN_RB_DRV2,.aid=5};
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=shader->fn;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&err];CHECK(pipeline!=nil,"dynamic pipeline compiles");if(!pipeline)return 1;
    uint8_t *mem=mmap(NULL,65536,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);CHECK(mem!=MAP_FAILED,"test pool allocated");if(mem==MAP_FAILED)return 1;
    memset(mem,0x42,65536);((uint32_t *)mem)[0]=101;((uint32_t *)mem)[16]=17;
    mtl_pool_add(mem,65536);pixels=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];res_add(pixels);
    tex_t white,blue,output;texture(&white,99501,(const uint8_t[]){255,255,255,255});texture(&blue,99502,(const uint8_t[]){0,0,255,255});texture(&output,99503,(const uint8_t[]){0,0,0,255});
    mtl_reg_tex(701,&white,NULL);mtl_reg_tex(702,&blue,NULL);samp_par sp={0};sp.ws=sp.wt=sp.wr=2;mtl_reg_samp(703,&sp);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();R.has_rt=1;R.rt.n=1;R.rt.color[0]=&output;
    S.ubo[1][0]=(p_bind_buf){.addr=(uintptr_t)mem,.size=16};S.ubo_set[1]=1;S.tex[1][0]=701|(703u<<20);g_draw_binst=7;
    dynamic_encode();copied_bytes(mem,256,"rounded readable tail preserved, everything past it zero");
    uint64_t copies=g_ub_short,full=g_stat_args_enc;
    for(int i=0;i<100;i++)dynamic_encode();
    CHECK(g_ub_short-copies==(pad_on?0u:100u),"same contents reuse padding; disabled cache retains original copies");
    CHECK(g_stat_args_enc-full==(keyed&&!checking?0u:100u),"read driver constants reuse static arguments; original/check paths fully encode");
    direct(101,7,701&255,255,"initial value and native driver words");
    ((uint32_t *)mem)[0]=102;dynamic_encode();copied_bytes(mem,256,"untracked CPU change is compared by bytes");
    direct(102,7,701&255,255,"CPU data changed at the same address");
    ((uint32_t *)mem)[16]=18;dynamic_encode();copied_bytes(mem,256,"CPU change in rounded tail is not missed");
    direct(102,7,701&255,0,"rounded tail changes reach GPU");
    ((uint32_t *)mem)[16]=17;g_draw_binst=8;dynamic_encode();
    direct(102,8,701&255,255,"base instance changes with unchanged textures");
    S.ssbo[1][0]=(p_bind_buf){.addr=UINT64_C(0x123456789abcdef0),.size=77};S.samp[1][3]=12u<<20;dynamic_encode();
    uint8_t *d=scratch_bytes(slot(4),DMSH_DRV_SIZE);uint64_t addr=0;uint32_t size=0,handle=0;
    if(d){memcpy(&addr,d+0x510,8);memcpy(&size,d+0x518,4);}
    CHECK(addr==UINT64_C(0x123456789abcdef0) && size==77,"native c0 refresh sees storage address and size changes");
    d=scratch_bytes(slot(5),DMSH_DRV_SIZE);if(d)memcpy(&handle,d+0x568+3*8,4);
    CHECK(handle==(12u<<20),"native c2 refresh sees unconsumed separate sampler changes");
    S.tex[1][0]=702|(703u<<20);dynamic_encode();direct(0,0,702&255,255,"static texture change still rebuilds bindings");
    S.ubo[1][0].size=257;dynamic_encode();copied_bytes(mem,512,"resized binding refreshes rounded bytes and zero tail");
    copies=g_ub_short;atomic_fetch_add(&g_pool_gen,1);dynamic_encode();
    CHECK(g_ub_short==copies+1,"pool generation invalidates the padded snapshot");
    copies=g_ub_short;atomic_fetch_add(&g_reg_gen,1);dynamic_encode();
    CHECK(g_ub_short==copies+1,"resource generation invalidates the padded snapshot");
    // An old padded bank remains valid after allocating another arena in this submission.
    uint64_t saved=slot(0);id<MTLBuffer> overflow;arena_alloc(8u<<20,&overflow);dynamic_encode();
    CHECK(!pad_on || slot(0)==saved,"a new arena does not invalidate still-live submission data");
    uint32_t update=111;mtl_sub_update(&update,(uintptr_t)mem,4);dynamic_encode();
    copies=g_ub_short;dynamic_encode();CHECK(g_ub_short==copies+1,"overlapping deferred update uses native padding path");
    direct(0,0,702&255,255,"partial inline update retains native visibility");
    sbw_note((uintptr_t)mem,512,SBW_GPU);copies=g_ub_short;dynamic_encode();CHECK(g_ub_short==copies+1,"unknown GPU-write range bypasses padded reuse");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"submission finishes");CHECK(!mtl_last_commit_error(),"GPU completed without error");
    for(unsigned i=0;i<image_count;i++) {
        uint8_t *base=(uint8_t *)pixels.contents+i*1024,*want=(uint8_t *)pixels.contents+32768+i*1024;int good=1;
        for(int y=0;y<4;y++)for(int x=0;x<4;x++)good&=!memcmp(base+y*256+x*4,want,4);
        if(!good)fprintf(stderr,"image %u got %u,%u,%u,%u expected %u,%u,%u,%u\n",i,base[0],base[1],base[2],base[3],want[0],want[1],want[2],want[3]);
        CHECK(good,"queued draws keep their own immutable uniform/driver snapshots");
    }
    // Same contents in a new submission still require fresh arena ownership.
    mtl_sub_begin();copies=g_ub_short;dynamic_encode();CHECK(g_ub_short==copies+1,"submission rollover expires padded snapshot");
    if(getenv("DM_TEST_ARGS_BENCH"))benchmark();
    else {
        // Compute continues through full encoding and keeps indirect-dispatch bookkeeping.
        rp_end();S.ubo[5][0]=S.ubo[1][0];S.tex[5][0]=701|(703u<<20);
        g_dispatch_dim[0]=3;g_dispatch_dim[1]=5;g_dispatch_dim[2]=7;g_c0_dim_buf=nil;
        args_dirty_all();encode_args_((id<MTLCommandEncoder>)blit(),shader,5,0);
        uint32_t actual[3]={0};if(g_c0_dim_buf)memcpy(actual,(uint8_t *)g_c0_dim_buf.contents+g_c0_dim_off,12);
        CHECK(actual[0]==3 && actual[1]==5 && actual[2]==7,"compute retains the native dispatch-count buffer and offset");
    }
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"final submission finishes");
    printf("dynamic args pad=%d key=%d check=%d: %d/%d checks passed\n",pad_on,keyed,checking,checks-failed,checks);
    return failed?1:0;
}}
