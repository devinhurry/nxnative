// Present crop regression: colored 8×8 texture, closed-form RGBA expectations; real Metal rendering, no dependence on the game or on cross-run determinism.
// nvn_mtl.m's nvn_game_fps is a weak default and hle_nvn.c gives the strong definition; in one translation unit that is a redefinition, so the weak one is renamed (this test does not look at the frame-rate target)
#define NVN_ASPECT_HOST
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle   // both files have a static g_ft, so hle_nvn.c's is renamed too
#include "../nvn/hle_nvn.c"
#undef g_ft
#include "../../host/hle_aspect.c"
void gate_obs_read_set(int id, void (*fn)(const uint64_t *)) { (void)id; (void)fn; }
int gate_obs_present(int id) { (void)id; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int g_layer_crop[4];   // what the vi layer crop (hle_vi.c) answers: x, y, w, h, all 0 = none
void dm_vi_layer_crop(int c[4]) { memcpy(c, g_layer_crop, sizeof g_layer_crop); }
#ifdef CROP_LEGACY_HEADER
#include CROP_LEGACY_HEADER
#define ENCODE legacy_present_encode
#else
#define ENCODE present_encode
#endif
static int failed, cases;
#define EXPECT(n, w, v) do { int a=(w),b=(v); cases++; printf("%s expected %d → got %d %s\n",n,a,b,a==b?"✓":"✗");failed+=a!=b; } while(0)
static const uint8_t colors[4][4]={{255,0,0,255},{0,255,0,255},{0,0,255,255},{255,255,0,255}};

#ifndef CROP_LEGACY_HEADER
// Exercise the persistent scaler used by real presents, completing each command buffer before its allocator and output leave scope.
static int check_present_resize(id<MTLTexture> src, int w, int h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];res_add(out);res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator];id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    [cb beginCommandBufferWithAllocator:al];int kind=present_encode_m4(cb,src,out,NULL,g_present_uv[0],&g_fx_present);[cb endCommandBuffer];
    [g_q4 commit:&cb count:1];[g_q4 signalEvent:ev value:1];
    EXPECT("resize present completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]);res_remove(out);return kind;
}
#endif

static void check_seated_dock(id<MTLTexture> src) {
    const int w=8,h=20;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];
    id<MTLBuffer> uv=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    const float values[]={0,0,1,1,.5f/8,.5f/8,1-.5f/8,1-.5f/8}; memcpy(uv.contents,values,sizeof values);
    res_add(src); res_add(out); res_add(uv); res_commit();
    for (int ll=0;ll<2;ll++) {
        uint8_t black_pixels[w*h*4]={0}; for (int i=0;i<w*h;i++) black_pixels[4*i+3]=255;
        [out replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:black_pixels bytesPerRow:w*4];
        atomic_store(&g_origin_ll,ll); float picture[]={0,.7f,1,.3f}; ui_region_to_render(picture);
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent]; [cb beginCommandBufferWithAllocator:al];
        seated_dock_encode(cb,src,out,picture,uv.gpuAddress); [cb endCommandBuffer];
        [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:1];
        EXPECT("Seated dock GPU completes",1,[event waitUntilSignaledValue:1 timeoutMS:10000]);
        uint8_t pixels[w*h*4]; [out getBytes:pixels bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
        int bad=0; const uint8_t black[]={0,0,0,255};
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            int row=y-(ll?0:14);
            const uint8_t *want=row>=0 && row<6 ? colors[(x>=4)+2*(row>=3)] : black;
            bad+=memcmp(pixels+4*(y*w+x),want,4)!=0;
        }
        EXPECT("Seated composites the whole dock below the fold without overwriting the picture",0,bad);
    }
    atomic_store(&g_origin_ll,0); res_remove(out); res_remove(uv); res_remove(src);
}
static void check(id<MTLTexture> src, const char *name, const int crop[4], int w, int h, int color) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:d];id<MTLCommandBuffer> cb=[g_q commandBuffer];
    EXPECT("encode succeeds",1,ENCODE(cb,src,dst,crop));[cb commit];[cb waitUntilCompleted];
    EXPECT("GPU done",MTLCommandBufferStatusCompleted,cb.status);
    uint8_t *out=malloc(w*h*4);[dst getBytes:out bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
    int bad=0;
    for(int y=0;y<h;y++)for(int x=0;x<w;x++) {
        int q=color;
        if(q==4) { // square valid area onto a 2:1 target: 4 black columns on each side, the middle 8 columns all red.
            static const uint8_t black[4]={0,0,0,255};
            const uint8_t *want=x<4||x>=12?black:colors[0];bad+=memcmp(out+4*(y*w+x),want,4)!=0;continue;
        }
        if(q==-2) { // crop=(1,1,4,4): 3×3 red, last column green, last row blue, bottom-right 1 cell yellow.
            q=(x+1>=4)+2*(y+1>=4);
        } else if(q<0) { // same-size default whole frame: the boundary is dead center.
            q=(x>=w/2)+2*(y>=h/2);
        }
        bad+=memcmp(out+4*(y*w+x),colors[q],4)!=0;
    }
    EXPECT(name,0,bad);free(out);
}

int main(void) { @autoreleasepool {
    setenv("DM_ASPECT", "0", 1);
    mtl_init();
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> src=[g_dev newTextureWithDescriptor:d];uint8_t px[8*8*4];
    for(int y=0;y<8;y++)for(int x=0;x<8;x++)memcpy(px+4*(y*8+x),colors[(x>=4)+2*(y>=4)],4);
    [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:px bytesPerRow:32];
    check_seated_dock(src);
    int zero[4]={0},tl[4]={0,0,4,4},tr[4]={4,0,4,4},bl[4]={0,4,4,4},br[4]={4,4,4,4},one[4]={3,3,1,1},inset[4]={1,1,4,4};
    check(src,"default whole frame 64 pixels",zero,8,8,-1);
    check(src,"NULL default whole frame 64 pixels",NULL,8,8,-1);
    check(src,"top-left crop scaled up, 256 pixels all red",tl,16,16,0);
    check(src,"non-zero x crop scaled up, 256 pixels all green",tr,16,16,1);
    check(src,"non-zero y crop scaled up, 256 pixels all blue",bl,16,16,2);
    check(src,"bottom-right crop at the edge, 256 pixels all yellow",br,16,16,3);
    check(src,"single texel scaled up without crossing edges, 256 pixels all red",one,16,16,0);
    check(src,"non-zero x and y offset, 16 pixels byte-identical to a hand-written sub-rectangle",inset,4,4,-2);
    check(src,"aspect of the valid area kept, 128 pixels red in the middle / black on both sides",tl,16,8,4);
    g_on=1; g_custom=2; dm_aspect_set_display(1); dm_aspect_set_seated(.4f,.6f);
    check(src,"Seated present keeps the combined picture/dock canvas full size with a fixed picture aspect",NULL,8,8,-1);
    {
        MTLTextureDescriptor *target=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        target.storageMode=MTLStorageModeShared; target.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> out=[g_dev newTextureWithDescriptor:target];
        id<MTLBuffer> uv=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent]; res_add(src); res_add(out); res_add(uv); res_commit();
        [cb beginCommandBufferWithAllocator:al]; present_encode_m4(cb,src,out,NULL,uv,nil); [cb endCommandBuffer];
        [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:1];
        EXPECT("Seated M4 fixed-aspect present completes",1,[event waitUntilSignaledValue:1 timeoutMS:10000]);
        uint8_t pixels[8*8*4]; [out getBytes:pixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        EXPECT("Seated M4 present does not letterbox the lower dock",0,memcmp(pixels,px,sizeof px));
        res_remove(src); res_remove(out); res_remove(uv);
    }
    dm_aspect_set_seated(0,0); g_on=0; g_custom=0;
#ifndef CROP_LEGACY_HEADER
    {
        // sRGB swapchain: present sends the raw bytes (as the Switch's scan-out does) without decoding first; unfixed, 128/64/200 decode to about 55/13/148
        MTLTextureDescriptor *sd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:8 height:8 mipmapped:NO];sd.storageMode=MTLStorageModeShared;sd.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> s8=[g_dev newTextureWithDescriptor:sd];uint8_t g[8*8*4];
        for(int i=0;i<64;i++){g[4*i]=128;g[4*i+1]=64;g[4*i+2]=200;g[4*i+3]=255;}
        [s8 replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:g bytesPerRow:32];
        MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];od.storageMode=MTLStorageModeShared;od.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> dst=[g_dev newTextureWithDescriptor:od];id<MTLCommandBuffer> cb=[g_q commandBuffer];
        EXPECT("sRGB source encode succeeds",1,ENCODE(cb,s8,dst,zero));[cb commit];[cb waitUntilCompleted];
        uint8_t o[8*8*4];[dst getBytes:o bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        int bad=0;for(int i=0;i<64;i++)bad+=abs(o[4*i]-128)>1||abs(o[4*i+1]-64)>1||abs(o[4*i+2]-200)>1;
        EXPECT("sRGB swapchain present sends raw bytes, 64 pixels",0,bad);
    }
#endif
#ifndef CROP_LEGACY_HEADER
    {   // DM_PRESENT_UPSCALE: which content MetalFX scales, and to which size (the picture's rectangle on the canvas)
        const struct { unsigned cw,ch,dw,dh,w,h; int upscale; } sizes[] = {
            {1280,720,2868,1320,2347,1320,1},   // handheld, letterboxed on an iPhone
            {1952,900,2868,1320,2868,1320,1},   // ratios within 1 % fill the canvas
            {1280,720,2560,1440,2560,1440,1},   // Retina window
            {1280,720,1280,720,1280,720,0},     // native size
            {1600,900,1280,720,1280,720,0},     // downscale
            {8,8,16,8,8,8,0},                  // larger canvas, native-size picture
        };
        for (unsigned i=0;i<sizeof sizes/sizeof *sizes;i++) {
            MTLViewport vp=present_viewport(sizes[i].cw,sizes[i].ch,sizes[i].dw,sizes[i].dh);
            EXPECT("MetalFX only upscales the picture",sizes[i].upscale,fx_wanted(vp,sizes[i].cw,sizes[i].ch));
            EXPECT("picture width",sizes[i].w,(int)vp.width);EXPECT("picture height",sizes[i].h,(int)vp.height);
        }
        EXPECT("empty content is not upscaled",0,fx_wanted((MTLViewport){0,0,2868,1320,0,1},0,720));
    }
    if([MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {   // the present pass through MetalFX into an offscreen canvas (present_offscreen_m4, as DM_NVN_SHOT_OUT uses it)
        g_fx_mode=1;
        const int N=64;MTLTextureDescriptor *bd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:N height:N mipmapped:NO];bd.storageMode=MTLStorageModeShared;bd.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> big=[g_dev newTextureWithDescriptor:bd];uint8_t *bp=malloc(N*N*4);
        for(int y=0;y<N;y++)for(int x=0;x<N;x++)memcpy(bp+4*(y*N+x),colors[(x>=N/2)+2*(y>=N/2)],4);
        for(int y=N/2;y<N;y++)for(int x=0;x<N/2;x++){uint8_t g[4]={128,64,200,255};memcpy(bp+4*(y*N+x),g,4);}   // lower-left quadrant: a mid grey-violet the sRGB bytes must keep
        [big replaceRegion:MTLRegionMake2D(0,0,N,N) mipmapLevel:0 withBytes:bp bytesPerRow:N*4];free(bp);
        res_add(big);res_commit();
        const int W=4*N,H=2*N;MTLTextureDescriptor *od=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
        od.storageMode=MTLStorageModePrivate;od.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;id<MTLTexture> out=[g_dev newTextureWithDescriptor:od];
        const int crops[5][4]={{0},{8,8,48,48},{8,8,48,48},{8,8,48,48},{8,8,48,48}};
        for (int mode=0;mode<5;mode++) {
            g_fx_mode=mode==3?0:mode==4?2:1;atomic_store(&g_origin_ll,mode==2);
            EXPECT("offscreen present reports the scaler actually used (scene mode never scales the final picture)",mode>=3?PRESENT_STANDARD:PRESENT_METALFX,present_offscreen_wait(big,crops[mode],out));
            id<MTLBuffer> rb=[g_dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
            [bl copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
            [bl endEncoding];[cb commit];[cb waitUntilCompleted];
            const uint8_t *o=rb.contents;   // BGRA
        #define PX(x,y,c) o[4*((y)*W+(x))+(c)]
            int bars=0;for(int y=0;y<H;y++)for(int x=0;x<W;x++)if(x<64||x>=192)bars+=PX(x,y,0)||PX(x,y,1)||PX(x,y,2);
            EXPECT("  black bars beside the square picture, 0 lit pixels",0,bars);
            int bad=0;const int cxs[2]={64+32,64+96},cys[2]={32,96};
            for(int q=0;q<4;q++){int x=cxs[q&1],y=cys[q>>1],sq=mode==2?q^2:q;const uint8_t *want=sq==2?(const uint8_t[4]){128,64,200,255}:colors[sq];
                bad+=abs(PX(x,y,2)-want[0])>3||abs(PX(x,y,1)-want[1])>3||abs(PX(x,y,0)-want[2])>3;}
            EXPECT("  quadrant centres keep their colours, raw bytes of the sRGB source (4 checked)",0,bad);
        #undef PX
        }
        atomic_store(&g_origin_ll,0);g_fx_mode=1;
        MTLTextureDescriptor *smallD=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:NO];
        smallD.storageMode=MTLStorageModePrivate;smallD.usage=MTLTextureUsageRenderTarget;
        id<MTLTexture> small=[g_dev newTextureWithDescriptor:smallD];int whole[4]={0},invalidCrop[4]={63,0,2,2};
        EXPECT("MetalFX requested but downscaling uses standard",PRESENT_STANDARD,present_offscreen_wait(big,whole,small));
        EXPECT("offscreen rejects an invalid crop before submission",PRESENT_FAILED,present_offscreen_wait(big,invalidCrop,out));

        uint64_t savedPresent=g_present_n;g_present_n=1;
        EXPECT("initial present makes its scaler",PRESENT_METALFX,check_present_resize(big,W,H));
        id<MTL4FXSpatialScaler> first=g_fx_present.sc;
        g_present_n=2;
        EXPECT("resizing within 30 presents falls back to standard",PRESENT_STANDARD,check_present_resize(big,192,96));
        EXPECT("resizing keeps the previous scaler until replacement",1,g_fx_present.sc==first);
        g_present_n=31;
        EXPECT("stable new size makes its scaler",PRESENT_METALFX,check_present_resize(big,192,96));
        EXPECT("replacement has the new picture size",96,(int)g_fx_present.out.width);
        EXPECT("exactly two scalers made",2,g_fx_present.made);
        g_present_n=32;
        EXPECT("same size reuses its scaler",PRESENT_METALFX,check_present_resize(big,192,96));
        EXPECT("reuse makes no new scaler",2,g_fx_present.made);
        g_present_n=savedPresent;

        // Whole-window capture uses the same upscale and remains asynchronous; its completion includes the final BGRA readback.
        dispatch_semaphore_t grabbed=dispatch_semaphore_create(0);
        mtl_grab_next_present(^(CGImageRef img) {
            EXPECT("whole-window capture produces an image",1,img!=NULL);
            if (img) {
                EXPECT("whole-window image width",W,(int)CGImageGetWidth(img));
                CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(img));const uint8_t *p=CFDataGetBytePtr(data);
                size_t off=96*CGImageGetBytesPerRow(img)+96*4;
                EXPECT("whole-window capture preserves sRGB bytes",1,abs(p[off]-200)<=3&&abs(p[off+1]-64)<=3&&abs(p[off+2]-128)<=3);
                CFRelease(data);
            }
            dispatch_semaphore_signal(grabbed);
        });
        grab_present(big,whole,CGSizeMake(W,H));
        EXPECT("whole-window capture callback completes",0,(int)dispatch_semaphore_wait(grabbed,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)));
        res_remove(big);g_fx_mode=0;
    } else printf("no Metal 4 MetalFX spatial scaler on this GPU: the MetalFX present is not checked\n");
#endif
    int invalid[4][4]={{-1,0,4,4},{0,-1,4,4},{0,0,0,4},{7,0,4,4}};
    for(int i=0;i<4;i++) {
        MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];dd.usage=MTLTextureUsageRenderTarget;dd.storageMode=MTLStorageModeShared;
        id<MTLTexture> dst=[g_dev newTextureWithDescriptor:dd];
        EXPECT("invalid crop is not encoded and does not fake success by stretching the whole image",0,ENCODE([g_q commandBuffer],src,dst,invalid[i]));
    }
    // Real QueuePresent entry: set crop and enqueue first, then immediately change the window; the present ticket must keep that frame's copy.
    PFNNVNDEVICEGETPROCADDRESSPROC get=(PFNNVNDEVICEGETPROCADDRESSPROC)h_nvnBootstrapLoader("nvnDeviceGetProcAddress");
    NVNT_nvnWindowSetCrop set=(NVNT_nvnWindowSetCrop)get(NULL,"nvnWindowSetCrop");
    NVNT_nvnQueuePresentTexture present=(NVNT_nvnQueuePresentTexture)get(NULL,"nvnQueuePresentTexture");
    tex_t tex={.magic=MAGIC('T', 'E', 'X', 0), .serial =10001};tex.d.width=tex.d.height=8;tex.d.depth=tex.d.levels=1;tex.d.format=NVN_FORMAT_RGBA8;tex.d.target=NVN_TEXTURE_TARGET_2D;serial_put(tex.serial,src);
    win_t win={.ntex=1};win.tex[0]=(NVNtexture *)&tex;set((NVNwindow *)&win,4,4,4,4);
    mtl_present_test_stall(100000000);present(NULL,(NVNwindow *)&win,0);uint64_t tk=win.ticket[0];set((NVNwindow *)&win,0,0,8,8);
#ifdef CROP_LEGACY_HEADER
    EXPECT("old queue struct has no room for a four-value copy (struct check)",1,sizeof(pq_item)>=sizeof(tex_t)+sizeof(double)+sizeof(uint64_t)+sizeof br);
#else
    pthread_mutex_lock(&g_pq_mu);if(!tk)tk=g_pq_in;   // a present snapshot (DM_PRESENT_SNAP; with the encode thread too) hands back no ticket: the frame is the last one queued
    int saved=memcmp(g_pq[(tk-1)%PQ].crop,br,sizeof br)==0;pthread_mutex_unlock(&g_pq_mu);
    EXPECT("real QueuePresent: the frame's crop copy does not change with the window",1,saved);
#endif
    mtl_present_wait(tk);mtl_present_test_stall(0);
#if DM_GAME_ASPECT_NATIVE
    // Native aspect: every font/layout variant is transformed at the final canvas, including masks and captured panes.
    g_on = 1; dm_aspect_set_display(20.f / 9); // enable the native path after the legacy presentation checks
    tex_t canvas = {.serial = 50001}; R.rt.n = 1; R.rt.color[0] = &canvas; g_ui_tex = canvas.serial;
    NvProg *layout = [NvProg new]; layout->sh[0] = [NvShader new];
    char *keys = strdup(DM_GAME_ASPECT_UI), *save = NULL;
    for (char *key = strtok_r(keys, " ", &save); key; key = strtok_r(NULL, " ", &save)) {
        strcpy(layout->sh[0]->key, key); double ux, uy;
        EXPECT("each font/layout variant corrected", 1, ui_squeeze_scale(layout, &ux, &uy, 0));
        EXPECT("20:9 UI x scale", 1250, lround(ux * 1000)); EXPECT("20:9 UI y scale", 1000, lround(uy * 1000));
    }
    free(keys); double ux, uy;
    dm_aspect_set_display(16.f / 9);
    EXPECT("16:9 leaves viewport/scissor exactly unchanged", 0, ui_squeeze_scale(layout, &ux, &uy, 0));
    dm_aspect_set_display(4.f / 3);
    EXPECT("4:3 layout corrected vertically", 1, ui_squeeze_scale(layout, &ux, &uy, 0));
    EXPECT("4:3 UI x unchanged", 1000, lround(ux * 1000)); EXPECT("4:3 UI y scale", 1333, lround(uy * 1000));
    if (!strcmp(DM_GAME_ID,"01007EF00011E000")) {
        const float narrow[]={4.f/3,9.f/16};
        for (unsigned i=0;i<sizeof narrow/sizeof *narrow;i++) {
            dm_aspect_set_display(narrow[i]);
            EXPECT("narrow menu content retains native centered proportions",1,ui_squeeze_scale(layout,&ux,&uy,0));
            EXPECT("native-scaled narrow heart/environment HUD is not scaled twice",0,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_HUD));
            EXPECT("native-scaled narrow map retains its capture and clip coordinates",0,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_MAP));
            // Rune capture takes precedence over its ancestor's HUD tag while
            // recording. It must still share the equipment group's viewport.
            EXPECT("native-scaled narrow rune keeps the equipment viewport",0,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_RUNE));
            EXPECT("narrow rune keeps both viewport axes unchanged",1,ux==1 && uy==1);
            EXPECT("weather keeps native model geometry and corrects its projection",1,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_WEATHER));
            EXPECT("weather projection compensates both display axes",1,fabs(ux*dm_aspect_hud_gain()-1)<.0001 && fabs(uy*narrow[i]/(16.f/9)*dm_aspect_hud_gain()-1)<.0001);
            EXPECT("narrow loading fills extend over the full canvas",0,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_STRETCH));
        }
    }
    dm_aspect_set_display(20.f / 9);
    R.rt.color[0] = &tex;
    EXPECT("offscreen capture remains unscaled (no double transform)", 0, ui_squeeze_scale(layout, &ux, &uy, 0));
    R.rt.color[0] = &canvas; strcpy(layout->sh[0]->key, "0000000000000000_b");
    EXPECT("3D composite remains unscaled", 0, ui_squeeze_scale(layout, &ux, &uy, 0));
    memcpy(layout->sh[0]->key, DM_GAME_ASPECT_UI, 16); layout->sh[0]->key[16] = 0;
    dm_aspect_set_display(21.f / 10);
    EXPECT("wide rune retains the existing layout correction",1,ui_squeeze_scale(layout,&ux,&uy,NVN_UI_RUNE));
    const char *split_fill_vs[] = {"78a4ace2913b091d_b", "a983fef957911db8_b"};
    for (int i = 0; i < 2; i++) {
        strcpy(layout->sh[0]->key, split_fill_vs[i]);
        EXPECT("BOTW split-fill layout VS scales at 21:10", 1, ui_squeeze_scale(layout, &ux, &uy, 0));
        EXPECT("BOTW split-fill 21:10 factor", 1181, lround(ux * 1000));
        R.rt.color[0] = &tex;
        EXPECT("BOTW split-fill offscreen capture stays unscaled", 0, ui_squeeze_scale(layout, &ux, &uy, 0));
        R.rt.color[0] = &canvas;
    }
    tex_t picture = {.magic=MAGIC('T','E','X',0), .serial=60001};
    picture.d.width=320; picture.d.height=180; picture.d.depth=picture.d.samples=picture.d.levels=1;
    picture.d.format=NVN_FORMAT_RGBA8; picture.d.target=NVN_TEXTURE_TARGET_2D;
    mtl_sub_begin(); tex_mtl(&picture); // a render target already exists on this storage
    picture.serial++; // the game's new transient object has not been resolved yet
    EXPECT("transient serial is unresolved before its first draw", 0, mtl_tex_gpu_owned(picture.serial));
    mtl_reg_tex(1200, &picture, NULL); S.tex[1][0] = 1200;
    EXPECT("first sample of an aliased screen picture is not transformed twice", 0, ui_squeeze_scale(layout, &ux, &uy, 0));
    EXPECT("transient serial resolves to GPU content", 1, mtl_tex_gpu_owned(picture.serial));
    EXPECT("a resized background capture follows layout coordinates once", 1, ui_squeeze_scale(layout, &ux, &uy, 1));
    EXPECT("texture setup completes", 1, mtl_wait(mtl_sub_commit(), 5000000000ull));
    // An illustration of the same size, uploaded by the CPU, remains in layout coordinates.
    MTLTextureDescriptor *pd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:320 height:180 mipmapped:NO];
    pd.usage=MTLTextureUsageShaderRead; serial_put(++picture.serial, [g_dev newTextureWithDescriptor:pd]);
    mtl_reg_tex(1201, &picture, NULL); S.tex[1][0] = 1201;
    EXPECT("CPU illustration keeps its proportions", 1, ui_squeeze_scale(layout, &ux, &uy, 0));
    EXPECT("projected fullscreen fill keeps clip and texture projection together", 0, ui_squeeze_scale(layout, &ux, &uy, NVN_UI_STRETCH));
    EXPECT("projected fill retains its native horizontal coordinates", 1, ux == 1 && uy == 1);
    check(src, "native present fills its target", tl, 20, 9, 0);
#endif
#ifndef CROP_LEGACY_HEADER
    {   // A window without a crop of its own presents by the vi layer crop (Link's Awakening in handheld mode: 1280x720 of its 1920x1080 window textures, cropped through vi::SetLayerCrop)
        int none[4]={0},lay[4]={0,4,4,4},over[4]={0,0,16,16},lc[4];
        memset(g_layer_crop,0,sizeof g_layer_crop);EXPECT("no window or layer crop: the whole texture",1,present_crop(none,8,8,lc)==none);
        memcpy(g_layer_crop,lay,sizeof lay);const int *r=present_crop(none,8,8,lc);EXPECT("no window crop: the layer crop",1,r==lc&&!memcmp(lc,lay,sizeof lay));
        EXPECT("the window's own crop wins over the layer crop",1,present_crop(br,8,8,lc)==br);
        memcpy(g_layer_crop,over,sizeof over);EXPECT("a layer crop larger than the texture: the whole texture",1,present_crop(none,8,8,lc)==none);
        memcpy(g_layer_crop,lay,sizeof lay);win_t w2={.ntex=1};w2.tex[0]=(NVNtexture *)&tex;
        mtl_present_test_stall(100000000);present(NULL,(NVNwindow *)&w2,0);uint64_t t2=w2.ticket[0];memset(g_layer_crop,0,sizeof g_layer_crop);
        pthread_mutex_lock(&g_pq_mu);if(!t2)t2=g_pq_in;int got=memcmp(g_pq[(t2-1)%PQ].crop,lay,sizeof lay)==0;pthread_mutex_unlock(&g_pq_mu);
        EXPECT("real QueuePresent: a window without a crop queues the layer crop",1,got);
        mtl_present_wait(t2);mtl_present_test_stall(0);
    }
#endif
    // Clip-space correction keeps content at its former location but permits
    // an enlarged native background to reach beyond the old 16:9 viewport.
    float projection[32], corrected[32], original[32];
    for (int i = 0; i < 32; i++) projection[i] = i + 0.25f;
    memcpy(original, projection, sizeof original);
    g_ui_clip_x=1; g_ui_clip_bias=0; g_ui_clip_y=.3; g_ui_clip_bias_y=.125;
    ui_projection_copy(0,projection,corrected,sizeof corrected);
    EXPECT("weather projection changes only the vertical clip row",1,!memcmp(original,corrected,16) && !memcmp(original+8,corrected+8,sizeof original-32));
    EXPECT("weather y projection preserves its clip center",1,fabs(corrected[5]-(original[5]*.3+original[13]*.125))<.000001);
    EXPECT("weather projection leaves source uniforms untouched",1,!memcmp(original,projection,sizeof original));
    ui_projection_copy(10,projection,corrected,sizeof corrected);
    EXPECT("vertical correction leaves the clip-x driver bank unchanged",1,!memcmp(original,corrected,sizeof original));
    g_ui_clip_y=1; g_ui_clip_bias_y=0;
    g_ui_clip_x = (16.0 / 9) / (21.0 / 10); g_ui_clip_bias = 0;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("UI source uniforms remain unchanged", 1, !memcmp(original, projection, sizeof original));
    EXPECT("UI x projection scaled before clipping", lround(projection[0] * g_ui_clip_x * 10000), lround(corrected[0] * 10000));
    EXPECT("UI y/z/w and material parameters unchanged", 1, !memcmp(projection + 4, corrected + 4, sizeof projection - 16));
    EXPECT("enlarged background reaches clip edge", 10000, lround((21.0 / 10) / (16.0 / 9) * g_ui_clip_x * 10000));
    g_ui_clip_bias = 0.125;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("partial viewport clip center preserved", lround((projection[1] * g_ui_clip_x + projection[13] * g_ui_clip_bias) * 10000), lround(corrected[1] * 10000));
    ui_projection_copy(10, projection, corrected, sizeof corrected);
    EXPECT("UI clip-x offset follows projection", lround(projection[0] * g_ui_clip_x * 10000), lround(corrected[0] * 10000));
    EXPECT("other driver constants unchanged", 1, !memcmp(projection + 1, corrected + 1, sizeof projection - 4));
    g_ui_clip_x = 1; g_ui_clip_bias = 0;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("16:9 projection remains byte-identical", 1, !memcmp(projection, corrected, sizeof projection));
    long left=1080,right=1280; double squeeze=(21.0/10)/(16.0/9);
    ui_scissor_x(&left,&right,1280,squeeze,1,NVN_UI_HUD);
    EXPECT("right-edge HUD preserves its clamped open edge",1280,right);
    EXPECT("right-edge HUD keeps its interior clip at the corrected position",1012,left);
    left=0;right=200;ui_scissor_x(&left,&right,1280,squeeze,1,NVN_UI_HUD);
    EXPECT("left-edge HUD preserves its clamped open edge",0,left);
    EXPECT("left-edge HUD keeps its interior clip at the corrected position",268,right);
    left=1080;right=1280;ui_scissor_x(&left,&right,1280,squeeze,1,0);
    EXPECT("menus retain the centered right clip",1182,right);
    left=120;right=1160;ui_scissor_x(&left,&right,1280,squeeze,1,NVN_UI_HUD);
    EXPECT("HUD interior clip remains bounded",1,left>120 && right<1160);
    left=0;right=1280;ui_scissor_x(&left,&right,1280,squeeze,1,NVN_UI_BACKGROUND);
    EXPECT("full backgrounds retain both open edges",1,left==0 && right==1280);
    left=40;right=1200;ui_scissor_x(&left,&right,1280,1,1,NVN_UI_HUD);
    EXPECT("16:9 HUD scissor stays unchanged",1,left==40 && right==1200);
    g_on=1; g_custom=0; dm_aspect_set_display(32.f/9); dm_aspect_set_safe_area(2560, 720, 0, 0, 0);
    left=1042;right=1208;ui_scissor_x(&left,&right,1280,2,1,NVN_UI_MAP);
    EXPECT("32:9 map clip moves to the right edge without leaving native clip space",1,left==1161 && right==1244);
    dm_aspect_set_safe_area(2560, 720, 0, 0, 40);
    left=1042;right=1208;ui_scissor_x(&left,&right,1280,2,1,NVN_UI_MAP);
    EXPECT("32:9 map clip uses authored right padding without an extra landscape inset",1,left==1161 && right==1244);
    dm_aspect_set_display(16.f/9); dm_aspect_set_safe_area(1280, 720, 0, 0, 0);
    left=1042;right=1208;ui_scissor_x(&left,&right,1280,1,0,NVN_UI_MAP);
    EXPECT("map clip restores its native position at 16:9",1,left==1042 && right==1208);
    // Captured return-animation data: a 192x192 read of the map at (485,257).
    // Its old left edge also reads the adjacent temperature/noise HUD.
    float copy[28]={0}, old_copy[28], bounds[4]={.79f,0,.97f,.4f};
    copy[22]=485.f/192;copy[23]=-257.f/192;copy[24]=192.f/1280;copy[25]=192.f/720;
    memcpy(old_copy,copy,sizeof copy);
    double scale=1/((21.0/10)/(16.0/9)), bias=116/(640*((21.0/10)/(16.0/9)));
    EXPECT("map framebuffer read follows its rendered projection",1,ui_capture_projection(copy,bounds,scale,bias));
    double u0=.5+(old_copy[22]-.5)*old_copy[24], u1=.5+(old_copy[22]+.5)*old_copy[24];
    EXPECT("blur reads corrected map left edge",lround((.5+(u0-.5)*scale+bias/2)*100000),lround((.5+(copy[22]-.5)*copy[24])*100000));
    EXPECT("blur reads corrected map right edge",lround((.5+(u1-.5)*scale+bias/2)*100000),lround((.5+(copy[22]+.5)*copy[24])*100000));
    EXPECT("capture y stays native",1,copy[23]==old_copy[23] && copy[25]==old_copy[25]);
    memcpy(copy,old_copy,sizeof copy);
    EXPECT("16:9 capture stays unchanged",0,ui_capture_projection(copy,bounds,1,0));
    EXPECT("16:9 capture bank stays byte-identical",1,!memcmp(copy,old_copy,sizeof copy));
    copy[22]=copy[23]=0;copy[24]=copy[25]=1;
    memcpy(old_copy,copy,sizeof copy);
    EXPECT("full-frame and other-menu copies do not borrow map correction",0,ui_capture_projection(copy,bounds,scale,bias));
    EXPECT("unrelated copy stays byte-identical",1,!memcmp(copy,old_copy,sizeof copy));
    printf("== %d checks, %d failed ==\n",cases,failed);return failed!=0;
} }
