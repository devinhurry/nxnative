// Exercise production encoding, argument lifetimes and rendered pixels, with content keys on/off/check.
static int test_key_allowed=1;
#define NX_GFX_ARGS_KEY_ALLOWED(stage) test_key_allowed
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) {return NULL;}
module_t *module_of(const void *p) {(void)p;return NULL;}
module_t *g_mod;int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) {return bp_now();}
static int checks,failed;
#define CHECK(c,label) do {checks++;if(!(c)){failed++;fprintf(stderr,"FAIL: %s\n",label);}} while(0)
static int keyed,checking;
static NvShader *shader;
static id<MTLRenderPipelineState> pipeline;
static id<MTLBuffer> pixels;
static unsigned image_count;
static void encode(void) {
    CHECK(rp_begin()!=nil,"production pass opens");
    enc_r_pso(g_enc,pipeline);enc_r_viewport(g_enc,(MTLViewport){0,0,4,4,0,1});
    enc_r_scissor(g_enc,(MTLScissorRect){0,0,4,4});enc_r_cull(g_enc,MTLCullModeNone);
    CHECK(encode_args((id<MTLCommandEncoder>)g_enc,shader,1,0),"production arguments encode");
}
static void new_encode(const char *label) {
    uint64_t before=g_stat_args_enc;args_dirty_all();encode();
    CHECK(g_stat_args_enc==before+1,label);
}
static void reuse(const char *label) {
    uint64_t before=checking?g_stat_args_key_check:g_stat_args_key_reuse;
    args_dirty_all();encode();
    uint64_t after=checking?g_stat_args_key_check:g_stat_args_key_reuse;
    CHECK(keyed?after==before+1:after==before,label);
}
static id<MTLTexture> texture(tex_t *t,uint64_t serial,const uint8_t color[4]) {
    *t=(tex_t){.magic=MAGIC('T','E','X',0),.serial=serial};
    t->d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=4,.height=4,.depth=1,.levels=1,.samples=1};
    MTLTextureDescriptor *d=tex_desc(t,0);d.storageMode=MTLStorageModeShared;
    id<MTLTexture> v=[g_dev newTextureWithDescriptor:d];CHECK(v!=nil,"test texture allocated");
    uint8_t data[64];for(int i=0;i<16;i++)memcpy(data+i*4,color,4);
    [v replaceRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0 withBytes:data bytesPerRow:16];
    res_add(v);mtl_tex_init(t);serial_put(serial,v);return v;
}
static void image(const uint8_t want[4],const char *label) {
    rp_end();R.clear_c[0]=1;R.cc[0]=MTLClearColorMake(0.25,0.25,0.25,1);
    encode();enc_r_draw(g_enc,MTLPrimitiveTypeTriangle,0,3);rp_end();
    size_t off=image_count++*1024;
    enc_b_copy_texture_buffer(blit(),tex_mtl(R.rt.color[0]),0,0,MTLOriginMake(0,0,0),MTLSizeMake(4,4,1),pixels,off,256,1024);
    // Keep each draw's expected result beside its readback; compare after GPU completion.
    memcpy((uint8_t *)pixels.contents+32768+off,want,4);
    printf("queued image: %s\n",label);
}
static void safety_cases(void) {
    uint64_t key[ARGS_KEY_MAX];
    CHECK(!args_key_make(shader,5,0,key),"compute stays on native full path");
    test_key_allowed=0;CHECK(!args_key_make(shader,1,0,key),"custom UI transformation bypasses keys");
    new_encode("active custom UI forces full encoding");test_key_allowed=1;
    new_encode("leaving custom UI establishes a fresh normal block");
    g_fb_n=1;g_fb_seq=g_draw_seq;
    CHECK(!args_key_make(shader,1,0,key),"feedback snapshot bypasses keys");g_fb_n=0;
    g_res_check_on=1;CHECK(!args_key_make(shader,1,0,key),"resource diagnostics bypass keys");g_res_check_on=0;
    // Only the samplers this shader consumes can require its generated border block.
    samp_par sp={0};sp.ws=sp.wt=sp.wr=5;sp.border[0]=0.25f;sp.border[3]=1;
    mtl_reg_samp(704,&sp);S.tex[1][0]=702|(704u<<20);shader->rf.b[2].bw=1;
    CHECK(!args_key_make(shader,1,0,key),"active border correction bypasses content keys");
    S.tex[1][0]=702|(703u<<20);
    CHECK(!keyed || args_key_make(shader,1,0,key)>0,"unrelated border sampler does not disable ordinary shader reuse");
    shader->rf.b[2].bw=0;
    NvShader *s=[NvShader new];s->rf.nb=1;s->rf.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1};
    CHECK(!args_keyable(s),"storage writes stay on native full path");
    s=[NvShader new];s->rf.nb=1;s->rf.b[0]=(nvn_rbind){.kind=255};
    CHECK(!args_keyable(s),"unknown binding kinds stay on native full path");
}
static void bench(void) {
    g_args_check=0;
    double ns[2];enum {N=20000};
    for(int on=0;on<2;on++) {
        g_args_key=on;shader->ab_nkey=0;encode();
        uint64_t start=bp_now();
        for(int i=0;i<N;i++){g_args_dirty[1]=1;encode_args_((id<MTLCommandEncoder>)g_enc,shader,1,0);}
        ns[on]=(double)(bp_now()-start)/N;
    }
    printf("argument encode, %d calls with unchanged consumed bindings: off %.1f ns/call, on %.1f ns/call (%.2fx)\n",N,ns[0],ns[1],ns[0]/ns[1]);
}
int main(void) {@autoreleasepool {
    setenv("DM_NVN_TBDR","0",1);mtl_init();keyed=args_key_on();checking=args_key_check_on();
    NSError *err=nil;
    id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]){return float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1);}\n"
        "struct A{constant float4 *tint[[id(0)]];texture2d<float> t[[id(1)]];sampler s[[id(2)]];constant uint4 *sizes[[id(3)]];};\n"
        "fragment float4 f(constant A&a[[buffer(0)]]){return a.sizes[0].x>=256?a.t.sample(a.s,float2(0.5))*a.tint[0]:float4(0,0,0,1);}\n"
        options:nil error:&err];
    CHECK(lib!=nil,"test Metal shader compiles");if(!lib){fprintf(stderr,"%s\n",err.localizedDescription.UTF8String);return 1;}
    shader=[NvShader new];shader->stage=1;strcpy(shader->key,"aabbeeff00112233");
    shader->fn=[lib newFunctionWithName:@"f"];shader->ae=[shader->fn newArgumentEncoderWithBufferIndex:0];shader->arg_len=shader->ae.encodedLength;
    shader->rf.nb=4;
    shader->rf.b[0]=(nvn_rbind){.kind=NVN_RB_CBUF,.reg=0,.aid=0};
    shader->rf.b[1]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0,.aid=1,.dtt=MTLTextureType2D};
    shader->rf.b[2]=(nvn_rbind){.kind=NVN_RB_SAMPT,.reg=0,.aid=2};
    shader->rf.b[3]=(nvn_rbind){.kind=NVN_RB_CBSIZE,.aid=3};
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=shader->fn;pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    pipeline=[g_dev newRenderPipelineStateWithDescriptor:pd error:&err];CHECK(pipeline!=nil,"test pipeline compiles");if(!pipeline)return 1;
    void *mem=NULL;CHECK(!posix_memalign(&mem,16384,65536),"uniform memory allocated");memset(mem,0,65536);
    const float red[4]={1,0,0,1},green[4]={0,1,0,1};memcpy(mem,red,16);memcpy((uint8_t *)mem+256,green,16);
    mtl_pool_add(mem,65536);pixels=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];res_add(pixels);
    tex_t white,blue,output;texture(&white,99301,(const uint8_t[]){255,255,255,255});texture(&blue,99302,(const uint8_t[]){0,0,255,255});texture(&output,99303,(const uint8_t[]){0,0,0,255});
    mtl_reg_tex(701,&white,NULL);mtl_reg_tex(702,&blue,NULL);
    samp_par sp={0};sp.ws=sp.wt=sp.wr=2;mtl_reg_samp(703,&sp);
    state_reset();memset(&R,0,sizeof R);mtl_sub_begin();R.has_rt=1;R.rt.n=1;R.rt.color[0]=&output;
    S.ubo[1][0]=(p_bind_buf){.addr=(uintptr_t)mem,.size=256};S.ubo_set[1]=1;S.tex[1][0]=701|(703u<<20);
    new_encode("first encode builds a block");
    reuse("unused binding dirtiness reuses consumed contents");
    rp_end();reuse("new pass in same submission reuses consumed contents");
    image((const uint8_t[]){255,0,0,255},"initial red uniform");
    S.ubo[1][0].addr=(uintptr_t)mem+256;g_args_ubo[1]=1;
    uint64_t patches=g_stat_args_key_patch;encode();
    CHECK(keyed&&!checking?g_stat_args_key_patch==patches+1:g_stat_args_key_patch==patches,"changed CBUF address patches only dynamic slots");
    image((const uint8_t[]){0,255,0,255},"changed uniform gives green");
    S.ubo[1][0].size=512;new_encode("changed rounded uniform size rebuilds size table");
    S.tex[1][0]=702|(703u<<20);new_encode("changed consumed texture rebuilds arguments");
    image((const uint8_t[]){0,0,0,255},"blue texture times green uniform is black");
    mtl_reg_tex(702,&white,NULL);new_encode("same texture ID re-registration invalidates content key");
    image((const uint8_t[]){0,255,0,255},"replacement texture is visible");
    sp.minf=sp.magf=1;mtl_reg_samp(703,&sp);new_encode("sampler re-registration invalidates content key");
    serial_put(99301,tex_mtl(&white));new_encode("texture serial changes invalidate content key");
    nvn_dirty_touch();new_encode("guest write generation invalidates content key");
    atomic_fetch_add(&g_pool_gen,1);new_encode("memory pool generation invalidates content key");
    g_psnap_gen++;args_dirty_all();new_encode("pool snapshot generation invalidates content key");
    safety_cases();
    // Inline data is refreshed through cbuf_slot, even when all static contents match.
    mtl_sub_update(red,(uintptr_t)mem+256,sizeof red);g_args_ubo[1]=1;encode();
    image((const uint8_t[]){255,0,0,255},"deferred inline uniform update is visible");
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"GPU submission completes");CHECK(!mtl_last_commit_error(),"GPU submission has no error");
    for(unsigned i=0;i<image_count;i++) {
        const uint8_t *want=(const uint8_t *)pixels.contents+32768+i*1024;int good=1;
        for(int y=0;y<4;y++)for(int x=0;x<4;x++)good&=!memcmp((const uint8_t *)pixels.contents+i*1024+y*256+x*4,want,4);
        if(!good)fprintf(stderr,"image %u: got %u,%u,%u,%u want %u,%u,%u,%u\n",i,((uint8_t *)pixels.contents+i*1024)[0],((uint8_t *)pixels.contents+i*1024)[1],((uint8_t *)pixels.contents+i*1024)[2],((uint8_t *)pixels.contents+i*1024)[3],want[0],want[1],want[2],want[3]);
        CHECK(good,"rendered pixels match expected uniform/texture contents");
    }
    mtl_sub_begin();new_encode("new submission never reuses a retired scratch block");
    if(getenv("DM_TEST_ARGS_BENCH"))bench();
    CHECK(mtl_wait(mtl_sub_commit(),5000000000ull),"final submission completes");
    printf("argument keys (%s%s): %d/%d checks passed, reused %llu, patched %llu, checked %llu\n",keyed?"on":"off",checking?", full comparison":"",checks-failed,checks,(unsigned long long)g_stat_args_key_reuse,(unsigned long long)g_stat_args_key_patch,(unsigned long long)g_stat_args_key_check);
    return failed?1:0;
}}
