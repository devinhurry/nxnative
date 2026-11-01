// Controlled motion inputs use the production encoder. The oracle replaces
// only the motion compute pipeline, and its actual GPU output is read back.
#define main unused_framegen_fixture_main
#include "t_framegen.m"
#undef main
#undef MLOG
#undef MDIE
#include "../nvn/framegen_metal.m"
#include <spawn.h>
#include <sys/wait.h>
extern char **environ;

static void dynamic_resolution_regression(void) {
    dm_fg_wait_idle(); dm_fg_reset();
    id<MTLTexture> raw[3],color[3];
    const int sizes[]={256,192,128};
    for (int i=0;i<3;i++) {
        int n=sizes[i];
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:n height:n mipmapped:NO];
        d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
        raw[i]=[g_dev newTextureWithDescriptor:d]; res_add(raw[i]);
        d.pixelFormat=MTLPixelFormatRGBA8Unorm; color[i]=[g_dev newTextureWithDescriptor:d]; res_add(color[i]);
        id<MTLBuffer> upload=[g_dev newBufferWithLength:n*n*4 options:MTLResourceStorageModeShared];
        float *z=upload.contents; for (int j=0;j<n*n;j++) z[j]=.8f;
        id<MTLCommandBuffer> cb=[g_q commandBuffer]; id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
        [e copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:n*4 sourceBytesPerImage:n*n*4 sourceSize:MTLSizeMake(n,n,1) toTexture:raw[i] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    }
    res_commit(); id<MTL4FXFrameInterpolator> prior=g.fi;
    NSArray *prior_textures=@[g.mv,g.ndepth,g.pdepth,g.flow,g.flow_fill];
    for (int frame=0;frame<32;frame++) {
        int i=frame<16 ? 0 : frame%3;
        pattern_inputs(frame*4,0);
        MTL4RenderPassDescriptor *pd=[MTL4RenderPassDescriptor new];
        for (int k=0;k<3;k++) pd.colorAttachments[k].texture=color[i];
        pd.depthAttachment.texture=raw[i]; framegen_note_pass(pd);
        g.last_prepare_s=0; int slot=framegen_generate(1./30,1); wait_queue();
        if (frame>=16) {
            CHECK("DRS retains the same interpolator and motion grid",g.fi==prior && g.in_w==256 && g.in_h==256);
            CHECK("DRS reuses current textures without reviving a cached history",([prior_textures isEqual:@[g.mv,g.ndepth,g.pdepth,g.flow,g.flow_fill]]));
            CHECK("DRS does not discard a continuous frame",slot>=0);
            if (slot>=0) {
                id<MTLBuffer> p=read_pixels(dm_fg_output(slot)); const uint8_t *image=p.contents; double mae=0;
                for (int y=16;y<240;y+=4) for (int x=16;x<240;x+=4) {
                    uint8_t want[4]; float z; pattern_pixel(pattern_vertical?y:x,pattern_vertical?x:y,frame*4-2,0,want,&z);
                    for (int c=0;c<3;c++) mae+=abs(image[4*(y*256+x)+c]-want[c]);
                }
                mae/=56.*56*3;
                printf("DRS frame=%d depth=%d midpoint_MAE=%.3f\n",frame,sizes[i],mae);
                CHECK("DRS generated pixels keep the correct midpoint",mae<1);
            }
        }
        if (slot>=0) dm_fg_display_done(slot);
    }
}

static void partial_flow_tile_regression(void) {
    dm_fg_wait_idle(); ensure_fi(256,252); dm_fg_reset();
    int slot=-1;
    for (int frame=0;frame<32;frame++) {
        pattern_inputs(frame*4,0); g.last_prepare_s=0;
        slot=framegen_generate(1./30,1); wait_queue();
        if (frame<31 && slot>=0) dm_fg_display_done(slot);
    }
    CHECK("partial flow tiles retain the requested motion grid",g.in_w==256 && g.in_h==252);
    CHECK("partial flow tiles produce interpolation",slot>=0);
    if (slot>=0) {
        id<MTLBuffer> pixels=read_pixels(dm_fg_output(slot)); const uint8_t *image=pixels.contents; double mae=0;
        for (int y=16;y<240;y+=4) for (int x=16;x<240;x+=4) {
            uint8_t want[4]; float z; pattern_pixel(pattern_vertical?y:x,pattern_vertical?x:y,122,0,want,&z);
            for (int c=0;c<3;c++) mae+=abs(image[4*(y*256+x)+c]-want[c]);
        }
        mae/=56.*56*3;
        CHECK("partial flow tiles preserve the known camera midpoint",mae<1);
        dm_fg_display_done(slot);
    }
}

int main(int argc,char **argv) { @autoreleasepool {
    alarm(90); setbuf(stdout,NULL);
    if (argc<4) {
        int failures=0;
        for (int vertical=0;vertical<2;vertical++) for (int mode=0;mode<3;mode++) for (int oracle=0;oracle<2;oracle++) {
            char m[16],o[16],v[16]; snprintf(m,sizeof m,"%d",mode); snprintf(o,sizeof o,"%d",oracle); snprintf(v,sizeof v,"%d",vertical);
            char *args[]={argv[0],argc>1?argv[1]:"-",m,o,"reuse","4",v,NULL}; pid_t pid; int status=0;
            int error=posix_spawn(&pid,argv[0],NULL,NULL,args,environ);
            if (error || waitpid(pid,&status,0)<0 || !WIFEXITED(status) || WEXITSTATUS(status)) failures++;
        }
        printf("twelve isolated motion controls: %d failed processes\n",failures); return !!failures;
    }
    setenv("DM_FRAMEGEN","30",1); setenv("DM_OPMODE","1",1);
    setenv("DM_PSO_PREPARE","0",1); setenv("DM_PSO_PREBUILD","0",1);
    if (!dm_fg_enabled()) { puts("SKIP: profile/device has no frame interpolation"); return 0; }
    mtl_init(); g_dm_present_link=g_link_started=g_link_owns_layer=1;
    pattern_vertical=argc>6?atoi(argv[6]):0;
    g_sub_thread=pthread_self(); atomic_store(&g_sub_thread_set,1);
    camera[0]=camera[5]=camera[10]=1; camera[12]=camera[17]=camera[22]=camera[27]=1;
    camera[56]=.1; camera[57]=100; camera[62]=camera[70]=1;
    inputs(1); CHECK("initial camera-only setup is a real seed",dm_fg_frame_prepare(1./30,1)<0);
    id<MTLComputePipelineState> camera_pipeline=g.mv_ps;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;struct P{float4x4 reproj;float2 size,inv_size;float yflip,dyn,pad1,pad2;};kernel void oracle(depth2d<float,access::read>d[[texture(0)]],texture2d<float,access::write>mv[[texture(1)]],texture2d<float,access::write>nd[[texture(3)]],constant P&p[[buffer(0)]],uint2 xy[[thread_position_in_grid]]){if(any(xy>=uint2(p.size)))return;float z=d.read(xy);nd.write(z,xy);float2 m=float2(p.reproj[3].x*p.size.x*.5,-p.reproj[3].y*p.size.y*.5);if(z<.5)m=float2(-8,0);mv.write(float4(m,0,0),xy);}";
    if (pattern_vertical) source=[source stringByReplacingOccurrencesOfString:@"m=float2(-8,0)" withString:@"m=float2(0,-8)"];
    NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> oracle_pipeline=library?[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"oracle"] error:&error]:nil;
    CHECK("analytic motion kernel compiles",oracle_pipeline!=nil); if (!oracle_pipeline) return 1;
    int only_mode=argc>2?atoi(argv[2]):-1,only_oracle=argc>3?atoi(argv[3]):-1;
    int frames=argc>5?atoi(argv[5]):4;
    if (frames<4 || frames>128) return 2;
    for (int mode=0;mode<3;mode++) for (int oracle=0;oracle<2;oracle++) {
        if ((only_mode>=0 && mode!=only_mode) || (only_oracle>=0 && oracle!=only_oracle)) continue;
        dm_fg_wait_idle(); dm_fg_reset(); g.mv_ps=oracle?oracle_pipeline:camera_pipeline;
        if (argc>4 && !strcmp(argv[4],"fresh-interpolator")) { g.fi=nil; g_fi_cache_count=0; }
        int slot=-1;
        for (int frame=0;frame<frames;frame++) {
            pattern_inputs((frame-frames+4)*8,mode);
            id<MTLTexture> ui=g_framegen_capture_state.composited_canvas;
            // A fixed 30 Hz source sequence, independent of test GPU speed.
            g.last_prepare_s=0;
            slot=framegen_generate(1./30,1); wait_queue();
            if (frame==frames-1) CHECK("UI borrows the completed canvas without a second full-size texture",g.ui==ui);
            if (frame<frames-1 && slot>=0) dm_fg_display_done(slot);
        }
        CHECK("controlled sequence produces interpolation",slot>=0); if (slot<0) continue;
        id<MTLBuffer> pixels=read_pixels(dm_fg_output(slot)),motion=read_pixels(g.mv);
        id<MTLBuffer> current=read_pixels(g.scene[g.cur^1]),previous=read_pixels(g.scene[g.cur]);
        const uint8_t *image=pixels.contents;
        const __fp16 *vectors=motion.contents;
        int fg=pattern_vertical?112*256+120:120*256+112,bg=pattern_vertical?32*256+40:40*256+32;
        float fgx=vectors[2*fg],fgy=vectors[2*fg+1];
        float bgx=vectors[2*bg],bgy=vectors[2*bg+1];
        CHECK("previous and current scene inputs differ",memcmp(current.contents,previous.contents,current.length)!=0);
        if (oracle) {
            CHECK("oracle GPU motion matches the known background shift",fabsf((pattern_vertical?bgy:bgx)-(mode==1?0:8))<.02 && fabsf(pattern_vertical?bgx:bgy)<.02);
            if (mode) CHECK("oracle GPU motion matches the known object shift",fabsf((pattern_vertical?fgy:fgx)+8)<.02 && fabsf(pattern_vertical?fgx:fgy)<.02);
        }
        double midpoint=0,current_error=0,roi_midpoint=0,roi_current=0;
        for (int y=16;y<240;y++) for (int x=16;x<240;x++) {
            uint8_t a[4],b[4]; float z;
            pattern_pixel(pattern_vertical?y:x,pattern_vertical?x:y,20,mode,a,&z); pattern_pixel(pattern_vertical?y:x,pattern_vertical?x:y,24,mode,b,&z);
            for (int c=0;c<3;c++) {
                double m=abs(image[4*(y*256+x)+c]-a[c]),n=abs(image[4*(y*256+x)+c]-b[c]); midpoint+=m; current_error+=n;
                if (pattern_vertical ? (y>=56 && y<152 && x>=64 && x<192) : (x>=56 && x<152 && y>=64 && y<192)) { roi_midpoint+=m; roi_current+=n; }
            }
        }
        midpoint/=224.*224*3; current_error/=224.*224*3;
        printf("MOTION scene=%d oracle=%d vertical=%d fg_x=%.3f fg_y=%.3f bg_x=%.3f bg_y=%.3f midpoint_MAE=%.3f current_MAE=%.3f roi_midpoint_MAE=%.3f roi_current_MAE=%.3f dt=%.6f\n",mode,oracle,pattern_vertical,fgx,fgy,bgx,bgy,midpoint,current_error,roi_midpoint/(96.*128*3),roi_current/(96.*128*3),g.dt);
        if (!mode) CHECK("camera-only positive control interpolates the midpoint",midpoint<12 && midpoint<current_error*.85);
        if (mode) {
            CHECK("moving foreground is closer to the midpoint than the current pose",roi_midpoint<roi_current*.75);
            CHECK("foreground follows its motion axis and opposes the camera",(pattern_vertical?fgy:fgx)<-2 && fabsf(pattern_vertical?fgx:fgy)<.25);
        }
        if (argc>1 && strcmp(argv[1],"-")) { char path[1024]; snprintf(path,sizeof path,"%s/motion-%d-%d-%d.png",argv[1],mode,oracle,pattern_vertical); shot(dm_fg_output(slot),path,0,NULL); }
        dm_fg_display_done(slot);
    }
    g.mv_ps=camera_pipeline;
    dm_fg_wait_idle();
    if (only_mode==0 && only_oracle==0) dynamic_resolution_regression();
    id<MTL4FXFrameInterpolator> prior=g.fi;
    g.prev_ok=g.hist_ok=1; ensure_fi(128,128);
    CHECK("changing input dimensions invalidates temporal history",!g.prev_ok && !g.hist_ok);
    g.prev_ok=g.hist_ok=1; ensure_fi(256,256);
    CHECK("returning to a cached size reuses only the interpolator",!fi_cache_on() || g.fi==prior);
    CHECK("cached dimensions never revive old frame history",!g.prev_ok && !g.hist_ok && !g.pdepth_frame);
    if (only_mode==0 && only_oracle==0) partial_flow_tile_regression();
    printf("%d controlled-motion checks, %d failed; motion quality is reported separately\n",checks,failed);
    return !!failed;
} }
