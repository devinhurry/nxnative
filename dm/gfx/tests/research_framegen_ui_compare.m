// Compare MetalFX's composited and separate HUD inputs over one synthetic
// moving background. This does not model BOTW's actual HUD or device behavior.
#define main original_framegen_fixture_main
#include "t_framegen.m"
#undef main
#undef MLOG
#undef MDIE
#include "../nvn/framegen_metal.m"

static float lin(float v) { return v<=0.04045f ? v/12.92f : powf((v+0.055f)/1.055f,2.4f); }
static float srgb(float v) { return v<=0.0031308f ? 12.92f*v : 1.055f*powf(v,1.0f/2.4f)-0.055f; }
static void ui(int x,int y,float rgb[3],float *a) {
    *a=0; rgb[0]=rgb[1]=rgb[2]=0;
    if (x<24 || x>=232 || y<24 || y>=232) return;
    int band=(y-24)/52;
    *a=band==0 ? 1.f : band==1 ? .5f : band==2 ? .25f : .75f;
    float t=((x/12+y/7)&1) ? .9f : .1f;
    rgb[0]=t; rgb[1]=.2f; rgb[2]=1.f-t;
}
static void set_ui_inputs(int shift,int separate) {
    pattern_inputs(shift,0);
    id<MTLTexture> canvas=g_framegen_capture_state.composited_canvas;
    id<MTLTexture> layer=dm_fg_ui_target(g_dev,256,256);
    id<MTLBuffer> source=[g_dev newBufferWithLength:256*256*12 options:MTLResourceStorageModeShared];
    uint8_t *canvas_pixels=source.contents;
    __fp16 *layer_pixels=(__fp16 *)(canvas_pixels+256*256*4);
    for (int y=0;y<256;y++) for (int x=0;x<256;x++) {
        int i=y*256+x; uint8_t under[4]; float z,rgb[3],a;
        pattern_pixel(x,y,shift,0,under,&z); ui(x,y,rgb,&a);
        for (int c=0;c<3;c++) {
            float value=srgb(rgb[c]*a + lin(under[c]/255.f)*(1-a));
            canvas_pixels[4*i+c]=(uint8_t)lrintf(fmaxf(0,fminf(1,value))*255);
            layer_pixels[4*i+c]=(__fp16)(rgb[c]*a);
        }
        canvas_pixels[4*i+3]=255; layer_pixels[4*i+3]=(__fp16)a;
    }
    id<MTLCommandBuffer> cb=[g_q commandBuffer];
    id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];
    MTLSize size=MTLSizeMake(256,256,1);
    [e copyFromBuffer:source sourceOffset:0 sourceBytesPerRow:1024 sourceBytesPerImage:256*1024 sourceSize:size toTexture:canvas destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e copyFromBuffer:source sourceOffset:256*256*4 sourceBytesPerRow:2048 sourceBytesPerImage:256*2048 sourceSize:size toTexture:layer destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status!=MTLCommandBufferStatusCompleted) { fprintf(stderr,"input upload failed\n"); exit(1); }
    g_framegen_capture_state.width=256; g_framegen_capture_state.height=256;
    g_framegen_capture_state.ui_ready=separate;
}
int main(void) { @autoreleasepool {
    alarm(120); setbuf(stdout,NULL);
    setenv("DM_FRAMEGEN","30",1); setenv("DM_OPMODE","1",1);
    setenv("DM_PSO_PREPARE","0",1); setenv("DM_PSO_PREBUILD","0",1);
    if (!dm_fg_enabled()) { fprintf(stderr,"MetalFX interpolation unsupported\n"); return 1; }
    mtl_init(); test_layer=layer(); g_dm_present_link=g_link_started=g_link_owns_layer=1;
    g_sub_thread=pthread_self(); atomic_store(&g_sub_thread_set,1);
    camera[0]=camera[5]=camera[10]=1; camera[12]=camera[17]=camera[22]=camera[27]=1;
    camera[56]=.1; camera[57]=100; camera[62]=camera[70]=1;
    inputs(1); dm_fg_frame_prepare(1./30,1);
    uint8_t output[2][256*256*4];
    for (int separate=0;separate<=1;separate++) {
        dm_fg_wait_idle(); dm_fg_reset(); int slot=-1;
        for (int frame=0;frame<4;frame++) {
            set_ui_inputs(frame*8,separate); g.last_prepare_s=0;
            slot=framegen_generate(1./30,1); wait_queue();
            if ((g.ui==g.ui_layer)!=separate || !g.fi || g.fi.uiTextureFormat!=g.ui.pixelFormat ||
                (slot>=0 && g.fi.uiTextureComposited==(BOOL)separate)) {
                fprintf(stderr,"Unexpected HUD input: requested=%d actual_separate=%d format=%lu\n",separate,g.ui==g.ui_layer,(unsigned long)g.ui.pixelFormat); return 1;
            }
            if (frame==3) printf("UI_MODE separate=%d format=%lu composited_flag=%d\n",separate,(unsigned long)g.ui.pixelFormat,g.fi.uiTextureComposited);
            if (frame<3 && slot>=0) dm_fg_display_done(slot);
        }
        if (slot<0) { fprintf(stderr,"No interpolated output, mode=%d\n",separate); return 1; }
        id<MTLBuffer> pixels=read_pixels(dm_fg_output(slot));
        memcpy(output[separate],pixels.contents,sizeof output[separate]);
        dm_fg_display_done(slot);
    }
    double err[2][5]={{0}}, different[5]={0}; long count[5]={0};
    for (int y=24;y<232;y++) for (int x=24;x<232;x++) {
        int i=y*256+x,band=(y-24)/52; uint8_t under[4]; float z,rgb[3],a;
        pattern_pixel(x,y,20,0,under,&z); ui(x,y,rgb,&a);
        for (int c=0;c<3;c++) {
            int want=(int)lrintf(srgb(rgb[c]*a+lin(under[c]/255.f)*(1-a))*255);
            for (int mode=0;mode<2;mode++) err[mode][band]+=abs((int)output[mode][4*i+c]-want);
            different[band]+=abs((int)output[0][4*i+c]-(int)output[1][4*i+c]); count[band]++;
        }
    }
    const char *name[]={"opaque","half","quarter","three-quarter"};
    for (int j=0;j<4;j++) printf("UI_RESULT %s composited_MAE=%.3f separate_MAE=%.3f difference=%.3f (0..255)\n",name[j],err[0][j]/count[j],err[1][j]/count[j],different[j]/count[j]);
    dm_fg_wait_idle(); return failed?1:0;
} }
