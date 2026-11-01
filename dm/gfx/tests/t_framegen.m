// Real MetalFX output and display-link ownership: interpolation must precede
// its real frame without completing the game's swapchain ticket early.
#include "../nvn/nvn_mtl.m"
#include <objc/runtime.h>
@interface FramegenUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@end
@implementation FramegenUpdate
@end
static CAMetalLayer *test_layer;
void *front_metal_layer(void) { return (__bridge void *)test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, condition) do { int ok=!!(condition); checks++; failed+=!ok; printf("%s: %s\n",label,ok?"PASS":"FAIL"); } while(0)
static id<MTLTexture> depth;
static float camera[84];
static tex_t real_texture;
static NSMutableArray *layers;
static NvMetalDisplayLinkDelegate *delegate;
static double tick_time;
static double fixture_age;
static uint64_t fixture_real_ticket;
static BOOL unsupported_framegen(id cls,SEL cmd,id device) { (void)cls; (void)cmd; (void)device; return NO; }
static void wait_present(void) {
    pthread_mutex_lock(&g_pq_mu);
    struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); ts.tv_sec+=10;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv,&g_pq_mu,&ts)!=ETIMEDOUT) {}
    CHECK("display GPU work finishes",!g_pq_inflight);
    pthread_mutex_unlock(&g_pq_mu);
    // Every modeled update owns a fresh layer. Its GPU work has drained, so
    // retire its residency before a long fixture reaches the queue's set limit.
    for (CAMetalLayer *l in layers) [g_q4 removeResidencySet:l.residencySet];
    [layers removeAllObjects];
    // Offscreen layers do not reliably receive nonzero presentedTime. Model
    // confirmation explicitly through the production callback handler. Real
    // cadence is measured separately in the visible game window.
    if (fixture_real_ticket) { framegen_presented(0,fixture_real_ticket,0,tick_time,tick_time,0,0); fixture_real_ticket=0; }
}
static void wait_queue(void) {
    id<MTLSharedEvent> event=[g_dev newSharedEvent];
    [g_q4 signalEvent:event value:1];
    CHECK("frame generation GPU work finishes",[event waitUntilSignaledValue:1 timeoutMS:10000]);
    // Shared-event signals precede feedback; release checks need the feedback too.
    for (int n=0;n<1000;n++) {
        int pending=0;
        for (int i=0;i<3;i++) pending+=dm_fg_slot_refs(i)>1;
        if (!pending) break;
        usleep(1000);
    }
}
static CAMetalLayer *layer(void) {
    CAMetalLayer *l=[CAMetalLayer layer]; l.device=g_dev;
    l.pixelFormat=MTLPixelFormatBGRA8Unorm; l.framebufferOnly=NO;
    l.drawableSize=CGSizeMake(256,256); return l;
}
static id<CAMetalDrawable> tick(double advance) {
    tick_time+=advance;
    CAMetalLayer *l=layer(); [layers addObject:l]; [g_q4 addResidencySet:l.residencySet];
    FramegenUpdate *u=[FramegenUpdate new]; u.drawable=[l nextDrawable]; u.targetPresentationTimestamp=tick_time;
    // Queue age is part of this modeled clock, not the wall time spent waiting
    // for fixture compilation/GPU scheduling on a busy test machine.
    pthread_mutex_lock(&g_pq_mu);
    for (uint64_t k=g_pq_read+1;k<=g_pq_in;k++) g_pq[(k-1)%PQ].t_in=CACurrentMediaTime()-fixture_age;
    pthread_mutex_unlock(&g_pq_mu);
    uint64_t read=g_pq_read,generated=g_fg_displayed;
    [delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u];
    fixture_age=0;
    if (g_pq_read>read && g_fg_displayed==generated) fixture_real_ticket=g_pq_read;
    return u.drawable;
}
static void inputs(int with_camera) {
    id<MTLTexture> scene=dm_fg_scene_target(g_dev,256,256,MTLPixelFormatRGBA8Unorm);
    static int resident;
    if (!resident) { [g_q4 addResidencySet:dm_fg_residency()]; resident=1; }
    if (!depth) {
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:256 height:256 mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
        depth=[g_dev newTextureWithDescriptor:d]; res_add(depth); res_commit();
    }
    // Populate synthetic inputs on a classic queue, completed before MetalFX.
    // This is fixture setup, not a CPU wait in the production interpolation path.
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:scene.pixelFormat width:256 height:256 mipmapped:NO];
    d.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> staging=[g_dev newTextureWithDescriptor:d];
    id<MTLCommandBuffer> cb=[g_q commandBuffer];
    id<MTLTexture> composed=[g_dev newTextureWithDescriptor:d];
    res_add(composed); res_commit();
    id<MTLTexture> textures[]={staging,composed};
    for (int i=0;i<2;i++) {
        MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
        p.colorAttachments[0].texture=textures[i]; p.colorAttachments[0].loadAction=MTLLoadActionClear; p.colorAttachments[0].storeAction=MTLStoreActionStore;
        p.colorAttachments[0].clearColor=i ? MTLClearColorMake(.06,.68,.24,1) : MTLClearColorMake(.15,.2,.6,1);
        if (!i) { p.depthAttachment.texture=depth; p.depthAttachment.loadAction=MTLLoadActionClear; p.depthAttachment.storeAction=MTLStoreActionStore; p.depthAttachment.clearDepth=.5; }
        [[cb renderCommandEncoderWithDescriptor:p] endEncoding];
    }
    id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromTexture:staging toTexture:scene]; [blit endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    CHECK("input setup succeeds",cb.status==MTLCommandBufferStatusCompleted);
    g_framegen_capture_state.composited_canvas=composed;
    g_framegen_capture_state.present_serial=real_texture.serial;
    memcpy(g_framegen_capture_state.present_region,(int[4]){0,0,256,256},4*sizeof(int));
    dm_fg_note_scene(); dm_fg_note_depth(depth); dm_fg_note_ui(composed);
    if (with_camera) dm_fg_note_camera(camera,84);
}
static int output_green(id<MTLTexture> texture) {
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    id<MTLBuffer> out=[g_dev newBufferWithLength:256*256*4 options:MTLResourceStorageModeShared];
    [e copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(256,256,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:1024 destinationBytesPerImage:256*1024];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    const uint8_t *b=out.contents; uint64_t r=0,g=0,bl=0;
    for (int i=0;i<256*256;i++) { r+=b[4*i+2]; g+=b[4*i+1]; bl+=b[4*i]; } // BGRA drawable
    printf("generated drawable mean RGB %.1f %.1f %.1f\n",r/65536.,g/65536.,bl/65536.);
    return cb.status==MTLCommandBufferStatusCompleted && g>r+bl && g>65536*100;
}
static id<MTLBuffer> read_pixels(id<MTLTexture> texture) {
    id<MTLBuffer> out=[g_dev newBufferWithLength:texture.width*texture.height*4 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    [e copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(texture.width,texture.height,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:texture.width*4 destinationBytesPerImage:out.length];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("structured image readback completes",cb.status==MTLCommandBufferStatusCompleted);
    return out;
}
// Closed-form scenes, rather than solid colours: a camera-translated tiled
// background, a moving foreground rectangle and their combined occlusions.
// Motion quality is measured against the known midpoint and current frame.
static void pattern_pixel(int x,int y,int shift,int mode,uint8_t rgba[4],float *z) {
    int world_x=x+(mode==1 ? 0 : shift);
    int tile=((world_x/32)+(y/32))&1;
    rgba[0]=tile?200:35; rgba[1]=tile?70:170; rgba[2]=((world_x/64)&1)?155:45; rgba[3]=255; *z=.8f;
    if (mode && x>=64+shift && x<112+shift && y>=72 && y<184) { rgba[0]=230; rgba[1]=25; rgba[2]=40; *z=.35f; }
}
static int pattern_vertical;
static void pattern_inputs(int shift,int mode) {
    id<MTLTexture> scene=dm_fg_scene_target(g_dev,256,256,MTLPixelFormatRGBA8Unorm_sRGB);
    id<MTLTexture> canvas=[g_dev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:scene.pixelFormat width:256 height:256 mipmapped:NO]];
    res_add(canvas); res_commit();
    NSUInteger bytes=256*256*4;
    id<MTLBuffer> upload=[g_dev newBufferWithLength:2*bytes options:MTLResourceStorageModeShared];
    uint8_t *rgba=upload.contents; float *z=(float *)(rgba+bytes);
    for (int y=0;y<256;y++) for (int x=0;x<256;x++) pattern_pixel(pattern_vertical?y:x,pattern_vertical?x:y,shift,mode,rgba+4*(y*256+x),z+y*256+x);
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    for (id<MTLTexture> t in @[scene,canvas,depth]) {
        [e copyFromBuffer:upload sourceOffset:t==depth?bytes:0 sourceBytesPerRow:1024 sourceBytesPerImage:bytes sourceSize:MTLSizeMake(256,256,1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    CHECK("pattern and depth upload completes",cb.status==MTLCommandBufferStatusCompleted);
    camera[15]=mode==1 || pattern_vertical ? 0 : -2.f*shift/256;
    camera[19]=mode==1 || !pattern_vertical ? 0 : 2.f*shift/256;
    g_framegen_capture_state.composited_canvas=canvas;
    g_framegen_capture_state.present_serial=real_texture.serial;
    memcpy(g_framegen_capture_state.present_region,(int[4]){0,0,256,256},4*sizeof(int));
    dm_fg_note_scene(); dm_fg_note_depth(depth); dm_fg_note_camera(camera,84); dm_fg_note_ui(canvas);
}
static void image_quality_regression(void) {
    dm_fg_wait_idle(); camera[47]=0;
    for (int mode=0;mode<3;mode++) {
        dm_fg_reset(); int slot=-1;
        for (int i=0;i<4;i++) {
            pattern_inputs(i*8,mode); slot=framegen_generate(1./30,1); wait_queue();
            if (i<3 && slot>=0) dm_fg_display_done(slot);
        }
        CHECK("structured scene produces a generated picture",slot>=0); if (slot<0) continue;
        id<MTLBuffer> buffer=read_pixels(dm_fg_output(slot));
        const uint8_t *image=buffer.contents; double midpoint=0,current=0;
        for (int y=16;y<240;y++) for (int x=16;x<240;x++) {
            uint8_t want[4],now[4]; float z;
            pattern_pixel(x,y,20,mode,want,&z); pattern_pixel(x,y,24,mode,now,&z);
            for (int c=0;c<3;c++) { midpoint+=abs(image[4*(y*256+x)+c]-want[c]); current+=abs(image[4*(y*256+x)+c]-now[c]); }
        }
        midpoint/=224.*224*3; current/=224.*224*3;
        printf("QUALITY %s midpoint_MAE=%.3f current_MAE=%.3f (0..255 sRGB)\n",mode==0?"camera-pan":mode==1?"moving-object":"pan-and-occlusion",midpoint,current);
        // This is a quality assertion only for static world reprojection.
        // Dynamic-object results are characterization: no engine velocity is supplied.
        if (!mode) CHECK("camera pan is closer to the true midpoint than the current image",midpoint<12 && midpoint<current*.85);
        dm_fg_display_done(slot);
    }
    camera[15]=0;
}
static void crop_regression(void) {
    dm_fg_wait_idle();
    id<MTLTexture> real=[g_dev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:512 height:512 mipmapped:NO]];
    tex_t texture={.magic=MAGIC('T','E','X',0),.serial=99803}; serial_put(texture.serial,real); res_add(real); res_commit();
    int slot=0; id<MTLTexture> output=dm_fg_output(slot);
    id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    for (id<MTLTexture> t in @[real,output]) {
        NSUInteger w=t.width,h=t.height;
        id<MTLBuffer> b=[g_dev newBufferWithLength:w*h*4 options:MTLResourceStorageModeShared]; uint8_t *p=b.contents;
        for (NSUInteger y=0;y<h;y++) for (NSUInteger x=0;x<w;x++) {
            p[4*(y*w+x)]=x<w/2?255:0; p[4*(y*w+x)+1]=x>=w/2?255:0; p[4*(y*w+x)+2]=y>=h/2?255:0; p[4*(y*w+x)+3]=255;
        }
        [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w*4 sourceBytesPerImage:w*h*4 sourceSize:MTLSizeMake(w,h,1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int crop[4]={256,0,256,256};
    for (int flip=0;flip<2;flip++) {
        atomic_store(&g_origin_ll,flip);
        id<CAMetalDrawable> drawable[2];
        dm_fg_display_retain(slot); // the queued real picture's owner
        for (int generated=1;generated>=0;generated--) {
            CAMetalLayer *l=layer(); [layers addObject:l]; [g_q4 addResidencySet:l.residencySet]; drawable[generated]=[l nextDrawable];
            CHECK("cropped generated/real display submits",present_now(&texture,1./60,0,g_pq_in,crop,drawable[generated],tick_time,generated?slot:-1,generated?-1:slot,NULL));
            wait_present();
        }
        id<MTLBuffer> a=read_pixels(drawable[0].texture),b=read_pixels(drawable[1].texture);
        CHECK(flip?"lower-left crop agrees between differently sized pictures":"non-full window crop agrees between differently sized pictures",!memcmp(a.contents,b.contents,a.length));
        const uint8_t *p=a.contents;
        CHECK("cropped picture contains only the chosen green quadrant",p[0]==0 && p[1]==255 && p[2]==0);
        CHECK("cropped pair releases its output references",!dm_fg_slot_refs(slot));
    }
    // A native 256px canvas copied 1:1 into a larger swapchain, as Handheld
    // BOTW copies its 720p canvas into the top-left of a 1080p allocation.
    cb=[g_q commandBuffer]; e=[cb blitCommandEncoder];
    [e copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(256,256,1) toTexture:real destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int region[4]={0,0,256,256},mapped[4];
    for (int flip=0;flip<2;flip++) {
        atomic_store(&g_origin_ll,flip);
        id<CAMetalDrawable> drawable[2]; dm_fg_display_retain(slot);
        for (int generated=1;generated>=0;generated--) {
            CAMetalLayer *l=layer(); [layers addObject:l]; [g_q4 addResidencySet:l.residencySet]; drawable[generated]=[l nextDrawable];
            CHECK("native-canvas cropped display submits",present_now(&texture,1./60,0,g_pq_in,region,drawable[generated],tick_time,generated?slot:-1,generated?-1:slot,region));
            wait_present();
        }
        id<MTLBuffer> a=read_pixels(drawable[0].texture),b=read_pixels(drawable[1].texture);
        CHECK("native canvas and cropped swapchain display identical pixels",!memcmp(a.contents,b.contents,a.length));
        CHECK("native-canvas pair releases its output references",!dm_fg_slot_refs(slot));
    }
    int outside[4]={0,0,512,512};
    CHECK("unknown pixels outside the captured canvas are never generated",!framegen_present_crop(real,output,outside,region,mapped));
    atomic_store(&g_origin_ll,0);
}
static uint64_t generation_count(void) {
    char stats[256]; dm_fg_stats(stats,sizeof stats); unsigned long long n=0;
    sscanf(strstr(stats,"generated="),"generated=%llu",&n); return n;
}
static void display_backpressure_regression(void) {
    present_drop_for_suspend(); g_link_hold_until=0;
    inputs(1); present_enqueue(&real_texture,1./30,NULL,0); tick(1./30); wait_present();
    inputs(1); uint64_t ticket=present_enqueue(&real_texture,1./30,NULL,0); wait_queue();
    int slot=g_pq[(ticket-1)%PQ].fg_slot;
    CHECK("backpressure fixture has a generated picture",slot>=0);
    int index=(g_fg_present_serial+1)%3;
    pthread_mutex_lock(&g_pq_mu);
    uint64_t fence=g_present_alloc_fence[index],done=g_present_alloc_done[index];
    g_present_alloc_fence[index]=done+1;   // feedback has not returned this allocator
    pthread_mutex_unlock(&g_pq_mu);
    dispatch_semaphore_t returned=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        @autoreleasepool { tick(1./60); dispatch_semaphore_signal(returned); }
    });
    int blocked=dispatch_semaphore_wait(returned,dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC))!=0;
    pthread_mutex_lock(&g_pq_mu);
    int untouched=g_pq_read==ticket-1 && !g_pq[(ticket-1)%PQ].fg_shown;
    g_present_alloc_fence[index]=fence; g_present_alloc_done[index]=done;
    pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    if (blocked) dispatch_semaphore_wait(returned,DISPATCH_TIME_FOREVER);
    CHECK("busy display allocation never blocks the display callback",!blocked);
    CHECK("backpressure leaves the source and generated picture queued",untouched);
    wait_present(); wait_queue();
    tick(1./60); wait_present(); tick(1./60); wait_present(); wait_queue();
    CHECK("display resumes and releases the pair after feedback",g_pq_read==ticket && slot>=0 && !dm_fg_slot_refs(slot));
}
static void fallback_and_deadline_regression(void) {
    for (int rescue=0;rescue<2;rescue++) {
        pthread_mutex_lock(&g_pq_mu);
        g_dm_present_link=rescue?1:0; g_rescue_mode=rescue; g_rescue_back_at=UINT64_MAX;
        g_link_owns_layer=g_link_started=0; pthread_cond_broadcast(&g_pq_cv);
        pthread_mutex_unlock(&g_pq_mu);
        uint64_t made=generation_count(),shown=g_fg_displayed;
        for (int i=0;i<3;i++) {
            inputs(1); uint64_t ticket=present_enqueue(&real_texture,1./30,NULL,0);
            mtl_present_wait(ticket); wait_queue();
        }
        CHECK(rescue?"rescue presenter does not compute unused interpolation":"manual classic presenter does not compute unused interpolation",generation_count()==made && g_fg_displayed==shown);
        pthread_mutex_lock(&g_pq_mu);
        g_dm_present_link=1; g_rescue_mode=0; g_link_owns_layer=g_link_started=1;
        pthread_mutex_unlock(&g_pq_mu);
        present_drop_for_suspend(); g_link_hold_until=0;
        inputs(1); uint64_t ticket=present_enqueue(&real_texture,1./30,NULL,0);
        CHECK("returning to the display link starts with a real picture",!g_pq[(ticket-1)%PQ].fg_valid);
        tick(1./30); wait_present();
        inputs(1); ticket=present_enqueue(&real_texture,1./30,NULL,0); wait_queue();
        tick(1./60); wait_present();
        CHECK("confirmed fresh history resumes displayed interpolation",g_fg_displayed==shown+1 && g_pq_read==ticket-1);
        tick(1./60); wait_present();
    }
    uint64_t made=generation_count();
    mtl_link_pause(1); inputs(1);
    CHECK("paused callback does not compute interpolation",framegen_generate(1./30,1)<0 && generation_count()==made);
    mtl_link_pause(0); inputs(1);
    CHECK("unpausing without intervening presents reseeds history",framegen_generate(1./30,1)<0);

    // Seed and confirm one real picture before exercising each rejection.
    present_drop_for_suspend(); framegen_discard_inputs(); g_link_hold_until=0;
    inputs(1); present_enqueue(&real_texture,1./30,NULL,0); tick(1./30); wait_present();
    pthread_mutex_lock(&g_pq_mu); g_fg_report_ticket=g_pq_in; g_fg_report_time=0; pthread_mutex_unlock(&g_pq_mu);
    made=generation_count(); uint64_t shown=g_fg_displayed;
    inputs(1); uint64_t ticket=present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("known dropped source avoids GPU interpolation at enqueue",generation_count()==made && !g_pq[(ticket-1)%PQ].fg_valid);
    tick(1./60); wait_present();
    CHECK("known dropped source displays the real picture",g_pq_read==ticket && g_fg_displayed==shown);

    inputs(1); ticket=present_enqueue(&real_texture,1./30,NULL,0); wait_queue();
    fixture_age=2./30;
    tick(1./30); wait_present();
    CHECK("an interpolation older than a game interval displays the real picture immediately",g_pq_read==ticket && g_fg_displayed==shown);

    inputs(1); id<MTLSharedEvent> blocker=[g_dev newSharedEvent]; [g_q4 waitForEvent:blocker value:1];
    ticket=present_enqueue(&real_texture,1./30,NULL,0);
    int slot=g_pq[(ticket-1)%PQ].fg_slot;
    CHECK("late GPU fixture has a pending generated output",slot>=0 && dm_fg_slot_refs(slot)==2);
    fixture_age=2./30;
    tick(1./60);
    CHECK("a late interpolation is skipped in favour of its real picture",g_pq_read==ticket && g_fg_displayed==shown);
    blocker.signaledValue=1; wait_present(); wait_queue();
    CHECK("late generated resources are released after real display",slot>=0 && !dm_fg_slot_refs(slot));
    made=generation_count();
    pthread_mutex_lock(&g_pq_mu); g_link_presenting=g_pq_in; pthread_mutex_unlock(&g_pq_mu);
    inputs(1); ticket=present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("taking a real picture does not allow optional GPU work before its display commit",generation_count()==made && !g_pq[(ticket-1)%PQ].fg_valid);
    pthread_mutex_lock(&g_pq_mu); g_link_presenting=0; pthread_mutex_unlock(&g_pq_mu);
    tick(1./30); wait_present();
}
// Synthetic UI shaders have closed-form pixels; they do not reproduce the
// game's font implementation. MetalFX borrows the complete canvas after UI.
// The game's samples-passed query must count only the two original draws.
static void ui_capture_regression(void) {
    NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;vertex float4 ui_vertex(uint i[[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return float4(p[i],.5,1);}\nfragment float4 ui_fragment(){return float4(.8,.1,.2,.5);}\n" options:nil error:&error];
    CHECK("synthetic UI shaders compile",library!=nil); if (!library) return;
    NvProg *program=[NvProg new]; program->sh[0]=[NvShader new]; program->sh[1]=[NvShader new];
    program->sh[0]->fn=[library newFunctionWithName:@"ui_vertex"];
    program->sh[1]->fn=[library newFunctionWithName:@"ui_fragment"];
    program->sh[1]->stage=1; program->sh[1]->rf.color_known=program->sh[1]->rf.color_mask=1;
    snprintf(program->sh[0]->key,sizeof program->sh[0]->key,"fedcba9876543210_b");
    snprintf(program->sh[1]->key,sizeof program->sh[1]->key,"0123456789abcdef_b");
    prog_t pg={.magic=MAGIC('P','R','O','G'),.serial=99801}; serial_put(pg.serial,program);
    tex_t target={.magic=MAGIC('T','E','X',0),.serial=99802};
    target.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D,.format=NVN_FORMAT_RGBA8,.width=256,.height=256,.depth=1,.levels=1,.samples=1};
    id<MTLBuffer> pixels[2]; uint64_t samples[2][2]={{0}};
    id<MTLBuffer> captured=[g_dev newBufferWithLength:256*256*4 options:MTLResourceStorageModeShared]; res_add(captured);
    for (int capture=0;capture<2;capture++) {
        pixels[capture]=[g_dev newBufferWithLength:256*256*4 options:MTLResourceStorageModeShared]; res_add(pixels[capture]);
        mtl_sub_begin(); state_reset(); memset(&R,0,sizeof R); vis_clear();
        g_vis_on=g_vis_counting=1;
        R.has_rt=1; R.rt.n=1; R.rt.color[0]=&target; R.clear_c[0]=1;
        R.cc[0]=MTLClearColorMake(.1,.2,.3,1);
        S.prog=&pg; S.bst[0]=S.bst[1]=&pg; S.ds.dw=0;
        S.has_vp=1; S.vp[0][2]=S.vp[0][3]=256;
        S.color.blend_en=1;
        S.blend[0]=(blend_st){0,NVN_BLEND_FUNC_SRC_ALPHA,NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA,NVN_BLEND_FUNC_ONE,NVN_BLEND_FUNC_ZERO,NVN_BLEND_EQUATION_ADD,NVN_BLEND_EQUATION_ADD};
        p_draw draw={NVN_DRAW_PRIMITIVE_TRIANGLES,0,3}; draw_(&draw,NULL); draw_(&draw,NULL);
        rp_end();
        if (capture) {
            g_framegen_capture_state.composited_canvas=tex_mtl(&target);
            dm_fg_note_ui(g_framegen_capture_state.composited_canvas);
            [blit() copyFromTexture:g_framegen_capture_state.composited_canvas sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(256,256,1) toBuffer:captured destinationOffset:0 destinationBytesPerRow:1024 destinationBytesPerImage:256*1024];
        }
        post((post_op){3,NULL,0,0,(uint64_t)samples[capture],NVN_COUNTER_TYPE_SAMPLES_PASSED,vis_snapshot()});
        [blit() copyFromTexture:tex_mtl(&target) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(256,256,1) toBuffer:pixels[capture] destinationOffset:0 destinationBytesPerRow:1024 destinationBytesPerImage:256*1024];
        CHECK("UI submission completes",mtl_wait(mtl_sub_commit(),5000000000ull));
        CHECK("UI submission has no GPU error",!mtl_last_commit_error());
    }
    CHECK("MetalFX receives the whole composed canvas",!memcmp(captured.contents,pixels[1].contents,256*256*4));
    CHECK("capturing UI preserves original pixels",!memcmp(pixels[0].contents,pixels[1].contents,256*256*4));
    CHECK("capture preserves game occlusion queries",samples[0][0]==2*256*256 && samples[1][0]==samples[0][0]);
    CHECK("original UI draws really wrote colour",((const uint8_t *)pixels[1].contents)[0]>140);
    g_framegen_capture_state.composited_canvas=nil; g_vis_on=g_vis_counting=0;
}
int main(int argc,char **argv) { @autoreleasepool {
    alarm(90); setbuf(stdout,NULL);
    unsetenv("DM_FRAMEGEN");
    CHECK("frame generation is off by default",!dm_framegen_requested());
    CHECK("early launcher lifecycle cannot enable interpolation",!dm_fg_enabled());
    setenv("DM_FRAMEGEN","30",1);
    if (!*DM_GAME_FRAMEGEN_SCENE) {
        CHECK("unconfigured games cannot enable BOTW frame generation",!dm_framegen_requested());
        printf("%d checks, %d failed; MetalFX fixture requires the BOTW profile\n",checks,failed); return !!failed;
    }
    setenv("DM_OPMODE","0",1);
    CHECK("handheld BOTW opt-in selects frame generation",dm_framegen_requested());
    CHECK("docked scene boundary matches its complete key",framegen_scene_key("bd7ffdd435c6c3bc_b"));
    CHECK("handheld scene boundary matches its complete key",framegen_scene_key("f7ee6fe10b925543_b"));
    CHECK("partial shader identities cannot capture a scene",!framegen_scene_key("f7ee6fe10b9255430_b"));
    setenv("DM_OPMODE","1",1);
    CHECK("docked BOTW opt-in selects frame generation",dm_framegen_requested());
    if (argc>1 && !strcmp(argv[1],"--unsupported")) {
        // Exercise the same native capability query as the loader, on a host
        // whose real GPU supports MetalFX. No production test-only flag.
        Method method=class_getClassMethod([MTLFXFrameInterpolatorDescriptor class],@selector(supportsMetal4FX:));
        method_setImplementation(method,(IMP)unsupported_framegen);
        CHECK("unsupported GPU keeps the user's original frame-rate policy",!dm_framegen_active());
        CHECK("unsupported GPU disables capture and display interpolation too",!dm_fg_enabled());
        printf("%d checks, %d failed\n",checks,failed); return !!failed;
    }
    setenv("DM_PRESENT_SNAP","0",1); setenv("DM_PRESENT_HZ","0",1);
    setenv("DM_PSO_PREPARE","0",1); setenv("DM_PSO_PREBUILD","0",1);
    if (!dm_fg_enabled()) { printf("SKIP: this GPU has no MetalFX interpolation\n"); return !!failed; }
    mtl_init();
    int windows=g_xv_npresent; mtl_xv_window_tex(99804);
    for (int i=0;i<256;i++) mtl_xv_window_tex(99804);
    CHECK("repeated window presents retain one texture identity",g_xv_npresent==windows+1 && xv_present(99804));
    CHECK("supported GPU enables the loader's 30-real-frame policy",dm_framegen_active());
    camera[0]=camera[5]=camera[10]=1;
    camera[12]=camera[17]=camera[22]=camera[27]=1;
    camera[56]=.1; camera[57]=100; camera[62]=1; camera[70]=1;
    test_layer=layer(); layers=[NSMutableArray new]; delegate=[NvMetalDisplayLinkDelegate new];
    g_dm_present_link=1; g_link_started=g_link_owns_layer=1; tick_time=CACurrentMediaTime();
    // Only this thread supplies NVN inputs, as QueuePresentTexture does in-game.
    g_sub_thread=pthread_self(); atomic_store(&g_sub_thread_set,1);
    id<MTLTexture> real=[g_dev newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO]];
    real_texture=(tex_t){.magic=MAGIC('T','E','X',0),.serial=99001};
    serial_put(real_texture.serial,real); res_add(real); res_commit();

    inputs(1); present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("first scene is a real frame only",!g_pq[0].fg_valid);
    tick(1./30); wait_present();
    inputs(1); present_enqueue(&real_texture,1./30,NULL,0);
    int slot=g_pq[1].fg_slot;
    CHECK("second scene produces interpolation",g_pq[1].fg_valid && slot>=0);
    wait_queue();
    tick(1./120); CHECK("seed real picture reserves half a game interval before interpolation",g_pq_read==1 && !g_fg_displayed);
    id<CAMetalDrawable> generated=tick(1./120); wait_present(); wait_queue();
    CHECK("generated picture does not consume the real frame",g_pq_read==1 && g_pq_done==1);
    CHECK("pending real frame still owns the output",dm_fg_slot_refs(slot)==1);
    CHECK("generated picture contains the composited UI",output_green(generated.texture));
    tick(1./120); CHECK("120 Hz callback holds the half-frame interval",g_pq_read==1);
    tick(1./120); wait_present();
    CHECK("real picture completes its own ticket",g_pq_read==2 && g_pq_done==2);
    CHECK("real display releases its output slot",!dm_fg_slot_refs(slot));

    inputs(1); present_enqueue(&real_texture,1./30,NULL,0);
    slot=g_pq[2].fg_slot; CHECK("third scene also interpolates",g_pq[2].fg_valid);
    wait_queue(); tick(1./60); wait_present();
    present_drop_for_suspend(); wait_queue();
    CHECK("suspending between generated and real pictures releases the slot",!dm_fg_slot_refs(slot) && g_pq_done==3);

    // There are no game frames while paused: neither boundary may depend on
    // present_enqueue's discard branch to invalidate history.
    mtl_present_discard(1); mtl_present_discard(0);
    inputs(1); present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("first frame after a no-frame pause is real only",!g_pq[3].fg_valid);
    tick(1./30); wait_present();
    camera[47]=20; inputs(1); present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("camera cuts show the real frame only",!g_pq[4].fg_valid);
    tick(1./30); wait_present();
    inputs(0); present_enqueue(&real_texture,1./30,NULL,0);
    CHECK("missing camera input shows the real frame only",!g_pq[5].fg_valid);
    tick(1./30); wait_present();
    inputs(1); CHECK("history restarts after missing input",framegen_generate(1./30,1)<0);
    int held[3];
    for (int i=0;i<3;i++) { inputs(1); held[i]=framegen_generate(1./30,1); CHECK("unpresented output reserves a distinct slot",held[i]>=0); wait_queue(); }
    inputs(1); CHECK("busy output slots are never overwritten",framegen_generate(1./30,1)<0);
    for (int i=0;i<3;i++) dm_fg_display_done(held[i]);
    inputs(1); CHECK("busy history restarts cleanly",framegen_generate(1./30,1)<0);
    inputs(1); int recovered=framegen_generate(1./30,1); wait_queue();
    CHECK("interpolation resumes after slots are released",recovered>=0);
    dm_fg_display_done(recovered);
    ui_capture_regression();
    // Catch a queue merge dropping the real picture used by an interpolation.
    uint64_t base=g_pq_in, displayed=g_fg_displayed;
    g_link_hold_until=0;
    for (int i=0;i<3;i++) { inputs(1); present_enqueue(&real_texture,1./30,NULL,0); wait_queue(); }
    tick(1./30); wait_present();
    CHECK("backlog recovers with a real picture when its predecessor was dropped",g_pq_read==base+2 && g_fg_displayed==displayed);
    tick(1./60); wait_present();
    CHECK("queued frames with unconfirmed sources remain real only",g_pq_read==base+3 && g_fg_displayed==displayed);
    present_drop_for_suspend(); inputs(1); int resumed=framegen_generate(1./30,1); wait_queue();
    CHECK("suspend with no intervening presents resets interpolation history",resumed<0);
    if (resumed>=0) dm_fg_display_done(resumed);
    // Keep a generated display blocked on the GPU, then discard its queued
    // real picture. Its output must remain reserved until GPU feedback.
    g_link_hold_until=0;
    inputs(1); present_enqueue(&real_texture,1./30,NULL,0); tick(1./30); wait_present();
    inputs(1); uint64_t pending=present_enqueue(&real_texture,1./30,NULL,0); wait_queue();
    slot=g_pq[(pending-1)%PQ].fg_slot;
    id<MTLSharedEvent> blocker=[g_dev newSharedEvent]; [g_q4 waitForEvent:blocker value:1];
    tick(1./60);
    pthread_mutex_lock(&g_pq_mu);
    CHECK("generated display is submitted before the forced GPU wait",g_pq_inflight>0 && g_pq_read==pending-1);
    present_drop_item(pending); g_pq_read=g_pq_done=pending;
    pthread_mutex_unlock(&g_pq_mu);
    CHECK("dropping the real picture retains the in-flight generated output",dm_fg_slot_refs(slot)==1);
    blocker.signaledValue=1; wait_present(); wait_queue();
    CHECK("GPU feedback finally releases the dropped pair's output",!dm_fg_slot_refs(slot));
    image_quality_regression();
    crop_regression();
    fallback_and_deadline_regression();
    display_backpressure_regression();
    char stats[256]; dm_fg_stats(stats,sizeof stats); printf("%s; displayed=%llu\n",stats,(unsigned long long)g_fg_displayed);
    printf("%d checks, %d failed\n",checks,failed); return !!failed;
} }
