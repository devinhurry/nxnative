// Ordered scene scaling, including queued size changes, on the production
// command buffer and encoding thread. No game files or translated shaders.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)

static void check_scene_boundary(void) {
    if (!*DM_GAME_SCENE_UPSCALE_PS) return;
    tex_t src = {.magic=MAGIC('T','E','X',0), .serial=970001};
    src.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=64, .height=64, .depth=1, .levels=1, .samples=1};
    tex_t dst = src; dst.serial++; dst.d.width=dst.d.height=128;
    MTLTextureDescriptor *source_desc=tex_desc(&src,0); source_desc.storageMode=MTLStorageModeShared;
    id<MTLTexture> source=[g_dev newTextureWithDescriptor:source_desc]; serial_put(src.serial,source); res_add(source);
    unsigned char pixels[64*64*4]; for(int i=0;i<64*64;i++) memcpy(pixels+i*4,(unsigned char[]){220,32,64,255},4);
    [source replaceRegion:MTLRegionMake2D(0,0,64,64) mipmapLevel:0 withBytes:pixels bytesPerRow:256];
    id<MTLTexture> target=[g_dev newTextureWithDescriptor:tex_desc(&dst,1)]; serial_put(dst.serial,target); res_add(target);
    mtl_reg_tex(300,&src,NULL);
    void *constants=NULL; posix_memalign(&constants,16384,16384); memset(constants,0,16384); mtl_pool_add(constants,16384);
    ((float *)constants)[0]=((float *)constants)[1]=1.0f/128;
    NvProg *pr=[NvProg new]; pr->sh[0]=[NvShader new]; pr->sh[1]=[NvShader new];
    snprintf(pr->sh[0]->key,sizeof pr->sh[0]->key,"%s_b",DM_GAME_SCENE_UPSCALE_VS);
    snprintf(pr->sh[1]->key,sizeof pr->sh[1]->key,"%s_b",DM_GAME_SCENE_UPSCALE_PS);
    p_draw draw={.prim=4,.count=3,.instances=1};
    mtl_sub_begin(); state_reset(); memset(&R,0,sizeof R); S.ds.dt=S.ds.dw=S.ds.st=0;
    R.has_rt=1; R.rt.n=1; R.rt.color[0]=&dst;
    S.has_vp=1; S.vp[0][2]=S.vp[0][3]=128;
    S.tex[1][0]=300; S.ubo[0][0]=(p_bind_buf){.addr=(uint64_t)(uintptr_t)constants,.size=16};
    const char *modes[]={"off","metalfx","scene"};
    for(int i=0;i<3;i++) {
        setenv("DM_PRESENT_UPSCALE",modes[i],1); g_fx_mode=-1;
        CHECK(fx_mode()==i,"the single setting selects exactly one scaling mode");
        if(i<2) { scene_upscale_prepare(pr,&draw,NULL); CHECK(!g_scene_up.output,"standard and full-screen modes leave the scene input unchanged"); }
    }
    scene_upscale_prepare(pr,&draw,NULL);
    CHECK(g_scene_up.output && g_scene_up.source==source,"verified native scene input is upscaled before its composite");
    CHECK(g_scene_up.output.width==128 && g_scene_up.output.height==128,"scene output matches native composite viewport");
    CHECK(((float *)constants)[0]==1.0f/128,"native FXAA constants stay unchanged");
    uint64_t fence=mtl_sub_commit(); CHECK(mtl_wait(fence,10000000000ull),"native scene preparation completes");
    id<MTLBuffer> rb=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
    [bl copyFromTexture:g_scene_up.output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,128,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:65536];
    [bl endEncoding];[cb commit];[cb waitUntilCompleted];
    unsigned char *pixel=(unsigned char *)rb.contents+(64*128+64)*4;
    CHECK(cb.status==MTLCommandBufferStatusCompleted && abs(pixel[0]-220)<=3 && abs(pixel[1]-32)<=3 && abs(pixel[2]-64)<=3,"native scene preparation produces the actual scene pixels");
    CHECK(!mtl_last_commit_error(),"native scene preparation has no GPU error");
    g_scene_up.source=g_scene_up.output=nil;
    mtl_sub_begin();
    pr->sh[1]->key[0]='x'; scene_upscale_prepare(pr,&draw,NULL);
    CHECK(!g_scene_up.output,"HUD / map shaders cannot claim the scene scaler");
    pr->sh[1]->key[0]=DM_GAME_SCENE_UPSCALE_PS[0];
    S.has_vp=0; scene_upscale_prepare(pr,&draw,NULL);
    CHECK(!g_scene_up.output,"unknown viewport retains the native path");
    S.has_vp=1; R.has_sc=1; R.sc=(p_scissor){.w=64,.h=64}; scene_upscale_prepare(pr,&draw,NULL);
    CHECK(!g_scene_up.output,"partial composites retain their native pixels");
    R.has_sc=0; ((float *)constants)[0]=1.0f/64; scene_upscale_prepare(pr,&draw,NULL);
    CHECK(!g_scene_up.output,"incompatible native texel constants refuse substitution");
    fence=mtl_sub_commit(); CHECK(mtl_wait(fence,10000000000ull),"refused scene cases complete");
    mtl_pool_del(constants); free(constants);
    memset(&R,0,sizeof R);
}

int main(void) { @autoreleasepool {
    mtl_init();
    if (![MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {
        fprintf(stderr, "Metal 4 spatial scaling is unavailable\n"); return 77;
    }
    fx_state fx = {0};
    id<MTLTexture> outputs[3];
    const unsigned widths[] = {64, 96, 64};
    const unsigned char colors[][4] = {{200, 32, 64, 255}, {16, 180, 80, 255}, {32, 64, 220, 255}};
    uint64_t fence = 0;
    for (int i = 0; i < 3; i++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:widths[i] height:64 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> src = [g_dev newTextureWithDescriptor:d]; res_add(src);
        unsigned char bytes[96*64*4];
        for (unsigned n = 0; n < widths[i]*64; n++) memcpy(bytes + n*4, colors[i], 4);
        [src replaceRegion:MTLRegionMake2D(0,0,widths[i],64) mipmapLevel:0 withBytes:bytes bytesPerRow:widths[i]*4];
        mtl_sub_begin();
        NSUInteger crop[] = {0,0,widths[i],64}; MTLViewport vp = {0,0,128,128,0,1};
        outputs[i] = fx_encode(&fx,g_cb,src,crop,vp,MTLPixelFormatRGBA8Unorm,FX_SCENE);
        CHECK(outputs[i] != nil, "scene scaler produces its output");
        fence = mtl_sub_commit();   // deliberately no GPU wait before the next size
        defer_obj_release(src);
    }
    CHECK(mtl_wait(fence,10000000000ull), "all queued scene sizes complete");
    CHECK(!mtl_last_commit_error(), "scene scaling has no Metal error");
    for (int i = 0; i < 3; i++) {
        id<MTLBuffer> rb = [g_dev newBufferWithLength:128*128*4 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [g_q commandBuffer]; id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
        [bl copyFromTexture:outputs[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(128,128,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:512 destinationBytesPerImage:65536];
        [bl endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "scaled pixels can be read back");
        unsigned char *pixel = (unsigned char *)rb.contents + (64*128+64)*4;
        for (int c = 0; c < 4; c++) CHECK(abs(pixel[c]-colors[i][c]) <= 3, "each queued scaler keeps its own textures and color");
    }
    check_scene_boundary();
    printf("scene upscale: %d checks, %d failed\n",checks,fails);
    return fails != 0;
} }
