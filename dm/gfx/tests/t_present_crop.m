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
static int test_relocate_loadout;
int dm_botw_touch_hud_relocates_loadout(void) { return test_relocate_loadout; }
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

// These assertions test byte-preserving uniform copies, including float bit patterns.
static int same_bytes(const void *a, const void *b, size_t bytes) { return memcmp(a, b, bytes) == 0; }

#ifndef CROP_LEGACY_HEADER
// Exercise the persistent scaler used by real presents, completing each command buffer before its allocator and output leave scope.
static int check_present_resize(id<MTLTexture> src, int w, int h) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];res_add(out);res_commit();
    id<MTL4CommandAllocator> al=[g_dev newCommandAllocator];id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];id<MTLSharedEvent> ev=[g_dev newSharedEvent];
    if (!out || !al || !cb || !ev) MDIE("present command resource allocation failed");
    [cb beginCommandBufferWithAllocator:al];int kind=present_encode_m4(cb,src,out,NULL,g_present_uv[0],&g_fx_present,NULL);[cb endCommandBuffer];
    [g_q4 commit:&cb count:1];[g_q4 signalEvent:ev value:1];
    EXPECT("resize present completes",1,[ev waitUntilSignaledValue:1 timeoutMS:10000]);res_remove(out);return kind;
}

static void filter_render(id<MTLTexture> src, id<MTLTexture> dst, uint8_t pixels[512], int metal4) {
    if (metal4) EXPECT("filtered capture completes", PRESENT_STANDARD, present_offscreen_wait(src, NULL, dst));
    else {
        id<MTLCommandBuffer> cb = [g_q commandBuffer];
        EXPECT("filtered classic present encodes", 1, present_encode(cb, src, dst, NULL));
        [cb commit]; [cb waitUntilCompleted];
        EXPECT("filtered classic present completes", MTLCommandBufferStatusCompleted, cb.status);
    }
    [dst getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 16, 8) mipmapLevel:0];
}

static void check_filter_editor(void) {
    uint8_t input[256],result[256],rendered[512];
    for (int y=0;y<8;y++) for (int x=0;x<8;x++) {
        int p=4*(y*8+x); input[p]=x*29; input[p+1]=y*31; input[p+2]=40+x*11+y*7; input[p+3]=255;
    }
    CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef original=CGBitmapContextCreate(input,8,8,8,32,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGContextRef decoded=CGBitmapContextCreate(result,8,8,8,32,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGImageRef image=CGBitmapContextCreateImage(original);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead; id<MTLTexture> src=[g_dev newTextureWithDescriptor:d];
    d.width=16; d.usage=MTLTextureUsageRenderTarget; id<MTLTexture> dst=[g_dev newTextureWithDescriptor:d];
    [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:input bytesPerRow:32];
    res_add(src); res_add(dst); res_commit();
    int saved_origin=atomic_load(&g_origin_ll),saved_fx=g_fx_mode; atomic_store(&g_origin_ll,0); g_fx_mode=0;
    for (const char **mode=(const char *[]){"off","vivid","cinematic","warm","cool",NULL};*mode;mode++) {
        for (int step=0;step<3;step++) {
            float strength=step==1 ? .4f : step==2 ? 1 : 0; char value[32]; snprintf(value,sizeof value,"%g",strength);
            setenv("DM_PRESENT_FILTER",*mode,1); setenv("DM_PRESENT_FILTER_STRENGTH",value,1); dm_present_filter_settings_changed();
            filter_render(src,dst,rendered,0);
            CGImageRef preview=dm_launcher_filter_preview(image,*mode,strength,8);
            EXPECT("editor preview produces an image",1,preview!=NULL);
            if (preview) {
                CGContextDrawImage(decoded,CGRectMake(0,0,8,8),preview); int bad=0;
                for (int y=0;y<8;y++) for (int x=0;x<8;x++) for (int c=0;c<4;c++)
                    bad+=abs(result[4*(y*8+x)+c]-rendered[4*(y*16+x+4)+c])>1;
                EXPECT("editor pixels match production shader and orientation",0,bad); CGImageRelease(preview);
            }
        }
    }
    setenv("DM_PRESENT_FILTER","cool",1); setenv("DM_PRESENT_FILTER_STRENGTH",".6",1); dm_present_filter_settings_changed();
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block CGImageRef raw=NULL;
    mtl_grab_next_present_unfiltered(^(CGImageRef frame) { if (frame) raw=CGImageRetain(frame); dispatch_semaphore_signal(done); });
    grab_present(src,NULL,CGSizeMake(16,8));
    EXPECT("editor raw snapshot completes",0,dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC)));
    EXPECT("editor raw snapshot excludes pillarboxes",8,raw ? CGImageGetWidth(raw) : 0);
    if (raw) {
        CGContextDrawImage(decoded,CGRectMake(0,0,8,8),raw); EXPECT("editor base frame is not already graded",0,memcmp(input,result,sizeof input));
        CGImageRelease(raw);
    }
    EXPECT("preview never mutates the live filter choice",0,strcmp(getenv("DM_PRESENT_FILTER"),"cool"));
    CGImageRef small=dm_launcher_filter_preview(image,"off",1,4);
    EXPECT("thumbnail downscales without stretching",4,small ? CGImageGetHeight(small) : 0); CGImageRelease(small);
    EXPECT("invalid preview modes are rejected",1,dm_launcher_filter_preview(image,"invalid",1,8)==NULL);
    atomic_store(&g_origin_ll,saved_origin); g_fx_mode=saved_fx;
    unsetenv("DM_PRESENT_FILTER"); unsetenv("DM_PRESENT_FILTER_STRENGTH"); dm_present_filter_settings_changed();
    res_remove(src); res_remove(dst); CGImageRelease(image); CGContextRelease(original); CGContextRelease(decoded); CGColorSpaceRelease(cs);
}

static void check_custom_luts(void) {
    char folder[]="/tmp/nxnative-lut-gpu-XXXXXX"; if (!mkdtemp(folder)) MDIE("cannot create LUT test directory");
    char identity[512],swap[512],nonlinear[512],invalid[512];
    snprintf(identity,sizeof identity,"%s/identity.cube",folder); snprintf(swap,sizeof swap,"%s/swap.cube",folder);
    snprintf(nonlinear,sizeof nonlinear,"%s/nonlinear.cube",folder); snprintf(invalid,sizeof invalid,"%s/invalid.cube",folder);
    for (int kind=0;kind<3;kind++) {
        FILE *file=fopen(kind==0 ? identity : kind==1 ? swap : nonlinear,"w"); if (!file) MDIE("cannot write LUT fixture");
        int n=kind==2 ? 3 : 2;
        fprintf(file,"LUT_3D_SIZE %d\n",n);
        if (kind==1) fputs("DOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 1 1 1\n",file);
        for (int b=0;b<n;b++) for (int g=0;g<n;g++) for (int r=0;r<n;r++) {
            float x=(float)r/(n-1),y=(float)g/(n-1),z=(float)b/(n-1);
            if (kind==2) fprintf(file,"%.8f %.8f %.8f\n",x*x,y*z,(x+z)*.5f);
            else fprintf(file,"%.8f %.8f %.8f\n",kind==1 ? z : x,y,kind==1 ? x : z);
        }
        fclose(file);
    }
    FILE *bad=fopen(invalid,"w"); fputs("LUT_3D_SIZE 33\n0 0 0\n",bad); fclose(bad);
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:8 height:8 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> src=[g_dev newTextureWithDescriptor:d];
    d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:8 mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> dst=[g_dev newTextureWithDescriptor:d]; res_add(src); res_add(dst); res_commit();
    const uint8_t sample[]={64,128,192,85}; uint8_t input[256],output[512];
    for (int i=0;i<64;i++) memcpy(input+4*i,sample,4);
    [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:input bytesPerRow:32];
    setenv("DM_PRESENT_FILTER","custom",1); setenv("DM_PRESENT_FILTER_STRENGTH","1",1);
    int center=4*(3*16+7),saved_fx=g_fx_mode; g_fx_mode=0;
    const uint8_t expected[][4]={{64,128,192,85},{224,192,160,85},{32,96,128,85}};
    for (int kind=0;kind<3;kind++) {
        EXPECT("custom CUBE parses and applies",DM_CUBE_OK,dm_launcher_lut_apply(kind==0 ? identity : kind==1 ? swap : nonlinear));
        dm_present_filter_settings_changed();
        for (int m4=0;m4<2;m4++) {
            filter_render(src,dst,output,m4);
            int different=0; for (int c=0;c<4;c++) different+=abs(output[center+c]-expected[kind][c])>1;
            EXPECT("custom LUT axis order, domain and trilinear interpolation",0,different);
            EXPECT("custom LUT preserves alpha exactly",sample[3],output[center+3]);
        }
    }
    @autoreleasepool {
        uint8_t tile[256],decoded[256];
        for (int i=0;i<64;i++) { memcpy(tile+4*i,sample,3); tile[4*i+3]=255; }
        CGColorSpaceRef cs=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef source=CGBitmapContextCreate(tile,8,8,8,32,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGContextRef target=CGBitmapContextCreate(decoded,8,8,8,32,cs,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        CGImageRef image=CGBitmapContextCreateImage(source);
        DmPresentLUT *active=g_custom_lut; NSString *active_path=g_custom_lut_path;
        uint64_t active_filter=atomic_load(&g_present_filter_value);
        for (int kind=0;kind<3;kind++) {
            CGImageRef preview=dm_launcher_lut_preview(image,kind==0 ? identity : kind==1 ? swap : nonlinear,1,8);
            EXPECT("each library entry produces its own preview",1,preview!=NULL);
            if (preview) {
                CGContextDrawImage(target,CGRectMake(0,0,8,8),preview); int different=0;
                for (int c=0;c<3;c++) different+=abs(decoded[c]-expected[kind][c])>1;
                EXPECT("library thumbnail uses its own LUT axis/domain/interpolation",0,different);
                CGImageRelease(preview);
            }
        }
        EXPECT("invalid library preview is rejected",1,dm_launcher_lut_preview(image,invalid,1,8)==NULL);
        EXPECT("library previews preserve the selected live table and path",1,g_custom_lut==active && [g_custom_lut_path isEqualToString:active_path] && !strcmp(getenv("DM_PRESENT_LUT"),active_path.UTF8String));
        EXPECT("library previews preserve live mode and strength",1,atomic_load(&g_present_filter_value)==active_filter);
        CGImageRelease(image); CGContextRelease(source); CGContextRelease(target); CGColorSpaceRelease(cs);
    }
    DmPresentLUT *previous=g_custom_lut;
    EXPECT("invalid live import rejected",DM_CUBE_FORMAT,dm_launcher_lut_apply(invalid));
    EXPECT("failed live import retains the previous LUT",1,g_custom_lut==previous);
    previous=nil;
    __weak DmPresentLUT *retired;
    @autoreleasepool {
        EXPECT("identity LUT restored",DM_CUBE_OK,dm_launcher_lut_apply(identity));
        retired=g_custom_lut;
        id<MTLBuffer> uniforms=[g_dev newBufferWithLength:PRESENT_UNIFORM_STRIDE*2 options:MTLResourceStorageModeShared];
        id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> done=[g_dev newSharedEvent]; DmPresentLUT *left=nil,*right=nil;
        res_add(uniforms); res_commit(); [cb beginCommandBufferWithAllocator:allocator];
        EXPECT("first LUT pane recorded",PRESENT_STANDARD,present_encode_m4_region(cb,src,dst,NULL,uniforms,nil,(const float[]){0,0,.5f,1},0,0,&left));
        EXPECT("LUT can change before the first GPU submission",DM_CUBE_OK,dm_launcher_lut_apply(nonlinear));
        EXPECT("second LUT pane recorded",PRESENT_STANDARD,present_encode_m4_region(cb,src,dst,NULL,uniforms,nil,(const float[]){.5f,0,.5f,1},PRESENT_UNIFORM_STRIDE,1,&right));
        EXPECT("LUT removal before GPU execution succeeds",DM_CUBE_OK,dm_launcher_lut_apply("none"));
        EXPECT("in-flight LUT still retained",1,retired!=nil && left!=right);
        [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:done value:1];
        EXPECT("replaced LUT frames complete",1,[done waitUntilSignaledValue:1 timeoutMS:10000]);
        [dst getBytes:output bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,8) mipmapLevel:0];
        int a=4*(3*16+3),b=4*(3*16+11),different=0;
        for (int c=0;c<4;c++) different+=abs(output[a+c]-expected[0][c])>1 || abs(output[b+c]-expected[2][c])>1;
        EXPECT("recorded panes retain their own LUT and domain",0,different);
        res_remove(uniforms); left=nil; right=nil;
    }
    EXPECT("retired LUT released after GPU completion",1,retired==nil);
    unsetenv("DM_PRESENT_FILTER"); unsetenv("DM_PRESENT_FILTER_STRENGTH"); unsetenv("DM_PRESENT_LUT"); dm_present_filter_settings_changed();
    g_fx_mode=saved_fx; res_remove(src); res_remove(dst);
    unlink(identity); unlink(swap); unlink(nonlinear); unlink(invalid); rmdir(folder);
}

static void check_picture_filters(void) {
    // Check actual pixels, including gamma, alpha, black bars, both command
    // paths and intensity interpolation. This uses no extracted game shaders.
    const uint8_t samples[][4] = {{96,96,96,128}, {80,130,180,64}, {0,0,0,0}, {255,255,255,255}};
    const char *modes[] = {"off", "vivid", "cinematic", "warm", "cool"};
    int saved_fx = g_fx_mode; g_fx_mode = 0;
    for (int srgb = 0; srgb < 2; srgb++) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> src = [g_dev newTextureWithDescriptor:d];
        d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:8 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> dst = [g_dev newTextureWithDescriptor:d];
        if (!src || !dst) MDIE("picture filter test texture allocation failed");
        res_add(src); res_add(dst); res_commit();
        for (int sample = 0; sample < 4; sample++) {
            uint8_t input[256], original[512], full[512], output[512];
            for (int i = 0; i < 64; i++) memcpy(input + i * 4, samples[sample], 4);
            [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:input bytesPerRow:32];
            setenv("DM_PRESENT_FILTER", "off", 1); setenv("DM_PRESENT_FILTER_STRENGTH", "1", 1);
            dm_present_filter_settings_changed(); filter_render(src, dst, original, 0);
            int center = 4 * (3 * 16 + 7);
            EXPECT("original keeps display bytes and alpha, including sRGB", 0, memcmp(original + center, samples[sample], 4));
            for (int mode = DM_FILTER_VIVID; mode <= DM_FILTER_COOL; mode++) {
                setenv("DM_PRESENT_FILTER", modes[mode], 1); setenv("DM_PRESENT_FILTER_STRENGTH", "1", 1);
                dm_present_filter_settings_changed(); filter_render(src, dst, full, 0);
                const uint8_t *pixel = full + center;
                if (sample == 0 && mode == DM_FILTER_WARM) EXPECT("warm neutral has red above blue", 1, pixel[0] > pixel[1] && pixel[1] > pixel[2]);
                if (sample == 0 && mode == DM_FILTER_COOL) EXPECT("cool neutral has blue above red", 1, pixel[2] > pixel[1] && pixel[1] > pixel[0]);
                if (sample == 1 && mode == DM_FILTER_VIVID) EXPECT("vivid increases colour separation", 1, pixel[2] - pixel[0] > samples[sample][2] - samples[sample][0]);
                if (sample == 2 && mode == DM_FILTER_CINEMATIC) EXPECT("cinematic LUT keeps black", 0, pixel[0] | pixel[1] | pixel[2]);
                if (sample == 3 && mode == DM_FILTER_CINEMATIC) EXPECT("cinematic LUT keeps white", 255, pixel[0] & pixel[1] & pixel[2]);
                EXPECT("filter preserves source alpha", samples[sample][3], pixel[3]);
                EXPECT("filter leaves letterbox black", 0, full[0] | full[1] | full[2]);
                for (int metal4 = 0; metal4 < 2; metal4++) {
                    filter_render(src, dst, output, metal4);
                    int different = 0;
                    for (int i = 0; i < 512; i++) different += abs(output[i] - full[i]) > 1;
                    EXPECT("classic and M4 filter pixels agree", 0, different);
                    setenv("DM_PRESENT_FILTER_STRENGTH", "0", 1); dm_present_filter_settings_changed();
                    filter_render(src, dst, output, metal4);
                    EXPECT("zero strength restores every original byte", 0, memcmp(output, original, sizeof original));
                    setenv("DM_PRESENT_FILTER_STRENGTH", "0.5", 1); dm_present_filter_settings_changed();
                    filter_render(src, dst, output, metal4);
                    different = 0;
                    for (int i = 0; i < 512; i++) different += abs(2 * output[i] - original[i] - full[i]) > 2;
                    EXPECT("half strength blends original and filtered pixels", 0, different);
                    setenv("DM_PRESENT_FILTER_STRENGTH", "1", 1); dm_present_filter_settings_changed();
                }
            }
        }
        uint8_t gray[256], panes[512];
        for (int i = 0; i < 64; i++) memcpy(gray + i * 4, samples[0], 4);
        [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:gray bytesPerRow:32];
        id<MTLBuffer> uniforms = [g_dev newBufferWithLength:PRESENT_UNIFORM_STRIDE * 2 options:MTLResourceStorageModeShared];
        id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocator];
        id<MTL4CommandBuffer> commands = [g_dev newCommandBuffer];
        id<MTLSharedEvent> done = [g_dev newSharedEvent];
        if (!uniforms || !allocator || !commands || !done) MDIE("picture filter test command allocation failed");
        res_add(uniforms); res_commit();
        [commands beginCommandBufferWithAllocator:allocator];
        setenv("DM_PRESENT_FILTER", "warm", 1); dm_present_filter_settings_changed();
        EXPECT("first filtered pane encodes", PRESENT_STANDARD, present_encode_m4_region(commands, src, dst, NULL, uniforms, nil, (const float[]){0,0,.5f,1}, 0, 0,NULL));
        setenv("DM_PRESENT_FILTER", "cool", 1); dm_present_filter_settings_changed();
        EXPECT("second filtered pane encodes", PRESENT_STANDARD, present_encode_m4_region(commands, src, dst, NULL, uniforms, nil, (const float[]){.5f,0,.5f,1}, PRESENT_UNIFORM_STRIDE, 1,NULL));
        [commands endCommandBuffer]; [g_q4 commit:&commands count:1]; [g_q4 signalEvent:done value:1];
        EXPECT("filtered panes finish", 1, [done waitUntilSignaledValue:1 timeoutMS:10000]);
        [dst getBytes:panes bytesPerRow:64 fromRegion:MTLRegionMake2D(0,0,16,8) mipmapLevel:0];
        int left = 4 * (3 * 16 + 3), right = 4 * (3 * 16 + 11);
        EXPECT("recorded panes keep independent filter constants", 1, panes[left] > panes[left + 2] && panes[right] < panes[right + 2]);
        res_remove(uniforms); res_remove(src); res_remove(dst);
    }
    setenv("DM_PRESENT_FILTER", "unknown", 1); setenv("DM_PRESENT_FILTER_STRENGTH", "nan", 1);
    dm_present_filter_settings_changed(); float params[4];
    EXPECT("invalid startup settings keep original at default strength", 0, present_filter_params(params));
    EXPECT("invalid strength defaults to one", 1, params[1]);
    unsetenv("DM_PRESENT_FILTER"); unsetenv("DM_PRESENT_FILTER_STRENGTH"); dm_present_filter_settings_changed();
    g_fx_mode = saved_fx;
}
#endif

static void check_seated_dock(id<MTLTexture> src) {
    const int w=8,h=20;
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];
    id<MTLBuffer> uv=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    if (!out || !uv) MDIE("Seated dock allocation failed");
    const float values[]={0,0,1,1,.5f/8,.5f/8,1-.5f/8,1-.5f/8}; memcpy(uv.contents,values,sizeof values);
    res_add(src); res_add(out); res_add(uv); res_commit();
    for (int ll=0;ll<2;ll++) {
        uint8_t black_pixels[w*h*4]={0}; for (int i=0;i<w*h;i++) black_pixels[4*i+3]=255;
        [out replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:black_pixels bytesPerRow:w*4];
        atomic_store(&g_origin_ll,ll); float picture[]={0,.7f,1,.3f}; ui_region_to_render(picture);
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent];
        if (!al || !cb || !event) MDIE("map command resource allocation failed");
        [cb beginCommandBufferWithAllocator:al];
        seated_texture_encode(cb,src,out,picture,uv.gpuAddress,SEATED_ALPHA); [cb endCommandBuffer];
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
static void check_seated_map_effect(void) {
    // The heading quad multiplies map colors with zero source alpha outside
    // its fan. The isolated dock must retain coverage across that rectangle.
    NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(i==1 ? 3.0 : -1.0,i==2 ? 3.0 : -1.0,0,1); }\n"
        "fragment float4 f() { return float4(.5,.5,.5,0); }\n" options:nil error:&error];
    EXPECT("Seated map effect fixture compiles",1,library!=nil); if (!library) return;
    NvShader *vs=[NvShader new],*fs=[NvShader new];
    vs->fn=[library newFunctionWithName:@"v"]; fs->fn=[library newFunctionWithName:@"f"];
    fs->rf.color_known=fs->rf.color_mask=1;
    blend_st native={0,NVN_BLEND_FUNC_DST_COLOR,NVN_BLEND_FUNC_SRC_ALPHA,NVN_BLEND_FUNC_DST_COLOR,
        NVN_BLEND_FUNC_SRC_ALPHA,NVN_BLEND_EQUATION_ADD,NVN_BLEND_EQUATION_ADD};
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:8 height:8 mipmapped:NO];
    td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> out=[g_dev newTextureWithDescriptor:td]; res_add(out); res_commit();
    if (!out) MDIE("map effect output allocation failed");
    for (int dock=0;dock<2;dock++) {
        pso_key key={0}; key.samples=1; key.cfmt[0]=td.pixelFormat; key.chmask=15; key.blend_en=1;
        key.blend[0]=dock ? ui_dock_blend(native) : native;
        id<MTLRenderPipelineState> pipeline=[g_dev newRenderPipelineStateWithDescriptor:pso_desc(&key,vs,fs,nil,0) error:&error];
        EXPECT("Seated map multiply pipeline compiles",1,pipeline!=nil); if (!pipeline) continue;
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent];
        if (!al || !cb || !event) MDIE("map effect command resource allocation failed");
        [cb beginCommandBufferWithAllocator:al];
        MTL4RenderPassDescriptor *rp=[MTL4RenderPassDescriptor new];
        rp.colorAttachments[0].texture=out; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
        rp.colorAttachments[0].storeAction=MTLStoreActionStore; rp.colorAttachments[0].clearColor=MTLClearColorMake(.25,.125,.0625,1);
        id<MTL4RenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:pipeline]; [en setViewport:(MTLViewport){2,2,4,4,0,1}];
        [en setScissorRect:(MTLScissorRect){2,2,4,4}]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [en endEncoding]; [cb endCommandBuffer]; [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:1];
        EXPECT("Seated map effect GPU completes",1,[event waitUntilSignaledValue:1 timeoutMS:10000]);
        uint16_t pixels[8*8*4]; memset(pixels,0xff,sizeof pixels);
        [out getBytes:pixels bytesPerRow:8*8 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        int color_bad=0,alpha_bad=0;
        for (int y=0;y<8;y++) for (int x=0;x<8;x++) {
            int inside=x>=2 && x<6 && y>=2 && y<6; const uint16_t *p=pixels+4*(y*8+x);
            color_bad+=p[0]!=(inside ? 0x3000 : 0x3400) || p[1]!=(inside ? 0x2c00 : 0x3000) || p[2]!=(inside ? 0x2800 : 0x2c00);
            alpha_bad+=p[3]!=(!dock && inside ? 0 : 0x3c00);
        }
        EXPECT("Heading multiply retains the native RGB result",0,color_bad);
        EXPECT(dock ? "Seated heading quad keeps map coverage over the reflection" : "Native opaque-canvas alpha still follows the game",0,alpha_bad);
    }
    res_remove(out);
}
static void check_seated_pipeline_cache(void) {
    id<MTLRenderPipelineState> window=seated_texture_pipeline(SEATED_COPY,MTLPixelFormatRGBA8Unorm_sRGB);
    id<MTLRenderPipelineState> small=seated_texture_pipeline(SEATED_COPY,MTLPixelFormatRGBA16Float);
    id<MTLRenderPipelineState> alpha=seated_texture_pipeline(SEATED_ALPHA,MTLPixelFormatRGBA8Unorm_sRGB);
    EXPECT("Seated copy pipelines keep their destination formats",1,
        window!=nil && small!=nil && window!=small);
    EXPECT("Seated copy and alpha pipelines remain distinct",1,alpha!=nil && alpha!=window);
    for (int frame=0;frame<4;frame++) {
        EXPECT("Seated window copy reuses its pipeline across alternating formats",1,
            seated_texture_pipeline(SEATED_COPY,MTLPixelFormatRGBA8Unorm_sRGB)==window);
        EXPECT("Seated downsample reuses its pipeline across alternating formats",1,
            seated_texture_pipeline(SEATED_COPY,MTLPixelFormatRGBA16Float)==small);
        EXPECT("Seated alpha composite reuses its separate pipeline",1,
            seated_texture_pipeline(SEATED_ALPHA,MTLPixelFormatRGBA8Unorm_sRGB)==alpha);
    }
}
static void check_seated_downsample(id<MTLTexture> source) {
    // Compare the compute scaler with the existing raster copy, including
    // a cropped source and destinations smaller than a full threadgroup.
    const int sizes[2][2]={{5,3},{1,1}};
    for (int k=0;k<2;k++) {
        int w=sizes[k][0],h=sizes[k][1]; id<MTLTexture> out[2];
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO];
        d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite|MTLTextureUsageRenderTarget;
        for (int i=0;i<2;i++) { out[i]=[g_dev newTextureWithDescriptor:d]; res_add(out[i]); }
        id<MTLBuffer> uv=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
        const float values[8]={.125f,.125f,.75f,.75f,.5f/8,.5f/8,1-.5f/8,1-.5f/8},full[4]={0,0,1,1};
        memcpy(uv.contents,values,sizeof values); res_add(uv); res_commit();
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent]; [cb beginCommandBufferWithAllocator:al];
        seated_texture_encode(cb,source,out[0],full,uv.gpuAddress,SEATED_COPY);
        seated_downsample_encode(cb,source,out[1],uv.gpuAddress); [cb endCommandBuffer];
        [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:1];
        EXPECT("Compute downsample GPU completes",1,[event waitUntilSignaledValue:1 timeoutMS:10000]);
        __fp16 pixels[2][5*3*4];
        for (int i=0;i<2;i++) [out[i] getBytes:pixels[i] bytesPerRow:w*8 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
        int mismatch=0;
        for (int i=0;i<w*h*4;i++) mismatch+=fabsf((float)pixels[0][i]-(float)pixels[1][i])>1.f/1024;
        EXPECT("Compute downsample matches cropped raster copy",0,mismatch);
        res_remove(out[0]); res_remove(out[1]); res_remove(uv);
    }
}
static void check_seated_reflection(void) {
    // The upper quadrants remain byte-identical; their mirror is blurred and
    // dimmed below the fold, behind a sharp opaque patch in the dock texture.
    const int w=240,h=400;
    for (int ll=0;ll<2;ll++) for (int inset=0;inset<5;inset++) {
        // Handheld rendering can occupy only part of a larger swapchain.
        const int tw=inset==4 ? 360 : w,th=inset==4 ? 600 : h,ox=inset==4 ? 24 : 0,oy=inset==4 ? 40 : 0;
        #define SEATED_PIXEL(x,y) (4*(((oy)+(ll ? h-1-(y) : (y)))*tw+(ox)+(x)))
        const int left=inset==1 ? 40 : 0,right=w-left,top=inset==2 ? 240 : inset==1 ? 120 : 160,bottom=inset==2 ? 320 : inset==3 ? 160 : 240;
        const int axis=(top+bottom)/2,reflected=MIN(top+axis-top,h-top),mirror=MIN(top,h-axis);
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB width:tw height:th mipmapped:NO];
        d.storageMode=MTLStorageModeShared; d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        id<MTLTexture> out=[g_dev newTextureWithDescriptor:d];
        uint8_t before[tw*th*4],pixels[tw*th*4]; memset(before,0,sizeof before);
        for (int y=0;y<h;y++) for (int x=0;x<w;x++) {
            uint8_t *p=before+SEATED_PIXEL(x,y); p[3]=255;
            if (y<top && x>=left && x<right) memcpy(p,colors[(x>=w/2)+2*(y>=top/2)],4);
        }
        [out replaceRegion:MTLRegionMake2D(0,0,tw,th) mipmapLevel:0 withBytes:before bytesPerRow:tw*4];
        id<MTLBuffer> uv=[g_dev newBufferWithLength:208 options:MTLResourceStorageModeShared];
        res_add(out); res_add(uv); res_commit(); atomic_store(&g_origin_ll,ll);
        float picture[4]={(float)left/w,0,(float)(right-left)/w,(float)top/h},dock[4]={0,(float)bottom/h,1,1-(float)bottom/h};
        MTLViewport canvas={ox,oy,w,h,0,1};
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent]; [cb beginCommandBufferWithAllocator:al];
        seated_reflection_encode(cb,out,canvas,picture,dock,(float)(right-left)/top,uv,0); [cb endCommandBuffer];
        [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:1];
        EXPECT("Seated reflection GPU completes",1,[event waitUntilSignaledValue:1 timeoutMS:10000]);
        [out getBytes:pixels bytesPerRow:tw*4 fromRegion:MTLRegionMake2D(0,0,tw,th) mipmapLevel:0];
        int overwritten=0;
        for (int y=0;y<top;y++) for (int x=0;x<w;x++) {
            size_t p=SEATED_PIXEL(x,y); overwritten+=memcmp(before+p,pixels+p,4)!=0;
        }
        EXPECT("Reflection leaves upper picture byte-identical",0,overwritten);
        #define REF(x,y,c) pixels[SEATED_PIXEL(x,y)+(c)]
        int x=left+(right-left)/4,near=axis+mirror/8,far=axis+mirror*2/3;
        if (bottom>top) EXPECT("Fold band contains a continuous decorative background",1,REF(x,top,2)>0 && REF(x,bottom-1,0)+REF(x,bottom-1,2)>0);
        else EXPECT("Zero-width fold keeps a finite visible mirror",1,REF(x,top,2)>0 && REF(x,top,3)==255);
        EXPECT("Reflection mirrors and dims the bottom blue quadrant next to the fold",1,REF(x,near,2)>20 && REF(x,near,2)<255 && REF(x,near,0)==0);
        EXPECT("Reflection keeps horizontal direction",1,REF(w-1-x,near,0)>20 && REF(w-1-x,near,1)>20 && REF(w-1-x,near,2)==0);
        if (far-axis<top/2) EXPECT("Short lower pane crops the mirror without stretching it",1,REF(x,far,2)>5 && REF(x,far,0)==0);
        else EXPECT("Reflection mirrors the top red quadrant further from the fold",1,REF(x,far,0)>5 && REF(x,far,2)==0);
        EXPECT("Reflection blurs the quadrant boundary",1,REF(w/2,near,0)>5 && REF(w/2,near,2)>5);
        EXPECT("Reflection fades completely to black",0,REF(x,top+reflected-1,0)+REF(x,top+reflected-1,1)+REF(x,top+reflected-1,2));
        if (left) EXPECT("Fixed-aspect reflection does not stretch into side bars",0,REF(10,near,0)+REF(10,near,1)+REF(10,near,2));
        if (inset==4) {
            int outside=0;
            for (int y=0;y<th;y++) for (int x=0;x<tw;x++) if (x<ox || x>=ox+w || y<oy || y>=oy+h)
                outside+=memcmp(before+4*(y*tw+x),pixels+4*(y*tw+x),4)!=0;
            EXPECT("Cropped Seated reflection leaves unused swapchain pixels untouched",0,outside);
        }
        #undef REF
        // Draw an opaque 1px-wide green marker after the reflection. Its edge
        // must stay crisp: the native dock is never input to the blur passes.
        MTLTextureDescriptor *mark=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
        mark.storageMode=MTLStorageModeShared; mark.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> overlay=[g_dev newTextureWithDescriptor:mark];
        [overlay replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:colors[1] bytesPerRow:4];
        int mark_y=MAX(bottom+5,near);
        res_add(overlay); res_commit(); float at[4]={(float)x/w,(float)mark_y/h,1.f/w,1.f/h}; ui_region_to_texture(at,canvas,out);
        const float values[8]={0,0,1,1,.5f,.5f,.5f,.5f}; memcpy((uint8_t *)uv.contents+176,values,sizeof values);
        [cb beginCommandBufferWithAllocator:al]; seated_texture_encode(cb,overlay,out,at,uv.gpuAddress+176,SEATED_ALPHA); [cb endCommandBuffer];
        [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:2];
        EXPECT("Seated dock overlay GPU completes",1,[event waitUntilSignaledValue:2 timeoutMS:10000]);
        [out getBytes:pixels bytesPerRow:tw*4 fromRegion:MTLRegionMake2D(0,0,tw,th) mipmapLevel:0];
        EXPECT("Dock overlay stays sharp above the reflection",0,memcmp(pixels+SEATED_PIXEL(x,mark_y),colors[1],4));
        if (!ll && !inset) {
            for (int y=0;y<top;y++) for (int x=0;x<w;x++)
                memset(before+4*(y*w+x),((x^y)&1)*255,3);
            [out replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:before bytesPerRow:w*4];
            [cb beginCommandBufferWithAllocator:al]; seated_reflection_encode(cb,out,canvas,picture,dock,(float)w/top,uv,0); [cb endCommandBuffer];
            [g_q4 commit:&cb count:1]; [g_q4 signalEvent:event value:3];
            EXPECT("Grain-filter GPU completes",1,[event waitUntilSignaledValue:3 timeoutMS:10000]);
            [out getBytes:pixels bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
            int low=255,high=0;
            for (int x=40;x<w-40;x++) { int v=pixels[4*(near*w+x)]; low=MIN(low,v); high=MAX(high,v); }
            EXPECT("Fine source grain becomes a smooth reflection before enlargement",1,low>20 && high<230 && high-low<=1);
        }
        res_remove(out); res_remove(uv); res_remove(overlay);
        #undef SEATED_PIXEL
    }
    atomic_store(&g_origin_ll,0);
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

int main(int argc,char **argv) { @autoreleasepool {
    setenv("DM_ASPECT", "0", 1);
    mtl_init();
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> src=[g_dev newTextureWithDescriptor:d];uint8_t px[8*8*4];
    for(int y=0;y<8;y++)for(int x=0;x<8;x++)memcpy(px+4*(y*8+x),colors[(x>=4)+2*(y>=4)],4);
    [src replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:px bytesPerRow:32];
#ifndef CROP_LEGACY_HEADER
    check_picture_filters();
    check_custom_luts();
    check_filter_editor();
    setenv("DM_PRESENT_FILTER", "warm", 1); dm_present_filter_settings_changed();
#endif
    check_seated_dock(src);
    check_seated_map_effect();
    check_seated_pipeline_cache();
    check_seated_downsample(src);
    check_seated_reflection();
#ifndef CROP_LEGACY_HEADER
    unsetenv("DM_PRESENT_FILTER"); dm_present_filter_settings_changed();
#endif
    if (argc==2 && !strcmp(argv[1],"--seated")) { printf("== %d checks, %d failed ==\n",cases,failed); return failed!=0; }
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
        id<MTLBuffer> uv=[g_dev newBufferWithLength:PRESENT_UNIFORM_STRIDE options:MTLResourceStorageModeShared];
        id<MTL4CommandAllocator> al=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];
        id<MTLSharedEvent> event=[g_dev newSharedEvent]; res_add(src); res_add(out); res_add(uv); res_commit();
        [cb beginCommandBufferWithAllocator:al]; present_encode_m4(cb,src,out,NULL,uv,nil,NULL); [cb endCommandBuffer];
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
        const int crops[6][4]={{0},{8,8,48,48},{8,8,48,48},{8,8,48,48},{8,8,48,48},{8,8,48,48}};
        for (int mode=0;mode<6;mode++) {
            g_fx_mode=mode==3?0:mode==4?2:1;atomic_store(&g_origin_ll,mode==2);
            setenv("DM_PRESENT_FILTER", mode==5 ? "warm" : "off", 1); dm_present_filter_settings_changed();
            EXPECT("offscreen present reports the scaler actually used (scene mode never scales the final picture)",mode==3||mode==4?PRESENT_STANDARD:PRESENT_METALFX,present_offscreen_wait(big,crops[mode],out));
            id<MTLBuffer> rb=[g_dev newBufferWithLength:W*H*4 options:MTLResourceStorageModeShared];id<MTLCommandBuffer> cb=[g_q commandBuffer];id<MTLBlitCommandEncoder> bl=[cb blitCommandEncoder];
            [bl copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,H,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W*4 destinationBytesPerImage:W*H*4];
            [bl endEncoding];[cb commit];[cb waitUntilCompleted];
            const uint8_t *o=rb.contents;   // BGRA
        #define PX(x,y,c) o[4*((y)*W+(x))+(c)]
            int bars=0;for(int y=0;y<H;y++)for(int x=0;x<W;x++)if(x<64||x>=192)bars+=PX(x,y,0)||PX(x,y,1)||PX(x,y,2);
            EXPECT("  black bars beside the square picture, 0 lit pixels",0,bars);
            int bad=0;const int cxs[2]={64+32,64+96},cys[2]={32,96};
            for(int q=0;q<4;q++){int x=cxs[q&1],y=cys[q>>1],sq=mode==2?q^2:q;const uint8_t *want=sq==2?(mode==5?(const uint8_t[4]){142,66,192,255}:(const uint8_t[4]){128,64,200,255}):colors[sq];
                bad+=abs(PX(x,y,2)-want[0])>3||abs(PX(x,y,1)-want[1])>3||abs(PX(x,y,0)-want[2])>3;}
            EXPECT("  quadrant centres keep their colours, raw bytes of the sRGB source (4 checked)",0,bad);
        #undef PX
        }
        unsetenv("DM_PRESENT_FILTER"); dm_present_filter_settings_changed();
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
        EXPECT("native top-left rune stays with the upper picture",0,ui_dock_scope(NVN_UI_RUNE));
        test_relocate_loadout=1;
        EXPECT("relocated rune follows equipment into the control pane",1,ui_dock_scope(NVN_UI_RUNE));
        test_relocate_loadout=0;
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
    EXPECT("weather projection changes only the vertical clip row",1,same_bytes(original,corrected,16) && same_bytes(original+8,corrected+8,sizeof original-32));
    EXPECT("weather y projection preserves its clip center",1,fabs(corrected[5]-(original[5]*.3+original[13]*.125))<.000001);
    EXPECT("weather projection leaves source uniforms untouched",1,same_bytes(original,projection,sizeof original));
    ui_projection_copy(10,projection,corrected,sizeof corrected);
    EXPECT("vertical correction leaves the clip-x driver bank unchanged",1,same_bytes(original,corrected,sizeof original));
    g_ui_clip_y=1; g_ui_clip_bias_y=0;
    g_ui_clip_x = (16.0 / 9) / (21.0 / 10); g_ui_clip_bias = 0;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("UI source uniforms remain unchanged", 1, same_bytes(original, projection, sizeof original));
    EXPECT("UI x projection scaled before clipping", lround(projection[0] * g_ui_clip_x * 10000), lround(corrected[0] * 10000));
    EXPECT("UI y/z/w and material parameters unchanged", 1, same_bytes(projection + 4, corrected + 4, sizeof projection - 16));
    EXPECT("enlarged background reaches clip edge", 10000, lround((21.0 / 10) / (16.0 / 9) * g_ui_clip_x * 10000));
    g_ui_clip_bias = 0.125;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("partial viewport clip center preserved", lround((projection[1] * g_ui_clip_x + projection[13] * g_ui_clip_bias) * 10000), lround(corrected[1] * 10000));
    ui_projection_copy(10, projection, corrected, sizeof corrected);
    EXPECT("UI clip-x offset follows projection", lround(projection[0] * g_ui_clip_x * 10000), lround(corrected[0] * 10000));
    EXPECT("other driver constants unchanged", 1, same_bytes(projection + 1, corrected + 1, sizeof projection - 4));
    g_ui_clip_x = 1; g_ui_clip_bias = 0;
    ui_projection_copy(0, projection, corrected, sizeof corrected);
    EXPECT("16:9 projection remains byte-identical", 1, same_bytes(projection, corrected, sizeof projection));
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
    EXPECT("16:9 capture bank stays byte-identical",1,same_bytes(copy,old_copy,sizeof copy));
    copy[22]=copy[23]=0;copy[24]=copy[25]=1;
    memcpy(old_copy,copy,sizeof copy);
    EXPECT("full-frame and other-menu copies do not borrow map correction",0,ui_capture_projection(copy,bounds,scale,bias));
    EXPECT("unrelated copy stays byte-identical",1,same_bytes(copy,old_copy,sizeof copy));
    printf("== %d checks, %d failed ==\n",cases,failed);return failed!=0;
} }
