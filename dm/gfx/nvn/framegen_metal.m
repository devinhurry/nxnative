// Adapted from MacNativeGames, copyright (c) 2026 MacNativeGames contributors (MIT).
// Source: games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx.m at 933b6a0d1438de160208a0a13eb5e8d7a2cb8094.
// License: dm/third_party/macnativegames/LICENSE. Frame inputs are owned by the NVN submit thread.
#import <MetalFX/MetalFX.h>
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "framegen.h"
#define MLOG(...) do { fprintf(stderr, "[dm] [framegen] " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define MDIE(...) do { MLOG("[RED] " __VA_ARGS__); abort(); } while (0)
#define MFX_OUT 3
static FILE *g_profile_file;
static pthread_once_t g_profile_once=PTHREAD_ONCE_INIT;
static pthread_mutex_t g_profile_mu=PTHREAD_MUTEX_INITIALIZER;
static void profile_init(void) {
    const char *path=getenv("DM_FRAMEGEN_PROFILE");
    if (!path || !*path) return;
    g_profile_file=fopen(path,"w");
    if (!g_profile_file) MLOG("[RED] cannot open frame generation profile: %s",path);
}
int dm_fg_profile_on(void) { pthread_once(&g_profile_once,profile_init); return g_profile_file!=NULL; }
void dm_fg_profile_event(NSString *event,NSDictionary *fields) {
    if (!dm_fg_profile_on()) return;
    NSMutableDictionary *row=[fields mutableCopy]; row[@"event"]=event; row[@"host_s"]=@(CACurrentMediaTime());
    NSData *data=[NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
    if (!data) { MLOG("[RED] invalid frame generation profile event"); return; }
    pthread_mutex_lock(&g_profile_mu); fwrite(data.bytes,1,data.length,g_profile_file); fputc('\n',g_profile_file); fflush(g_profile_file); pthread_mutex_unlock(&g_profile_mu);
}
static struct {
    id<MTLDevice> dev;
    id<MTL4FXFrameInterpolator> fi;
    NSUInteger in_w, in_h, out_w, out_h; MTLPixelFormat scene_fmt;
    id<MTLTexture> scene[2], ui, mv, ndepth, flow, flow_fill, out[MFX_OUT], outv[MFX_OUT];
    id<MTLTexture> pdepth; uint64_t pdepth_frame;   // the previous interpolated frame's depth (copied after its motion), and its g.frames
    id<MTLResidencySet> rs;
    id<MTLComputePipelineState> mv_ps, flow_regions_ps, flow_ps, flow_fill_ps, flow_apply_ps;
    id<MTL4ArgumentTable> mv_args[MFX_OUT], flow_regions_args[MFX_OUT], flow_args[MFX_OUT], flow_fill_args[MFX_OUT], flow_apply_args[MFX_OUT];
    id<MTLBuffer> mv_par[MFX_OUT];
    id<MTLFence> fence;
    int cur;                       // scene[cur] is written by this frame
    int scene_ok, cam_ok;          // this frame
    __weak id<MTLTexture> depth;   // this frame's G-buffer depth (owned by the game's texture table)
    double cam[84], prev_cam[84];
    int prev_ok, hist_ok, slot;    // prev_ok: scene[cur ^ 1] / prev_cam hold the previous frame; hist_ok: MetalFX saw it
    double yflip;                  // clip-space y of the game: +1 = top row (DM_FRAMEGEN_YFLIP=-1 tries the other way)
    id<MTLTexture> enc_depth;      // depth of a prepared frame, until it is encoded
    int scene_ok_was, cam_ok_was;
    uint64_t frames, made, skip_input, skip_first, skip_cut, skip_busy, miss[4];   // miss: scene, camera, depth, UI
    double last_prepare_s, dt;      // time of the previous game frame's prepare; this pair's interval (MetalFX deltaTime)
    uint64_t skip_present;
} g;
NSDictionary *dm_fg_profile_frame(void) {
    return @{@"prepare":@(g.frames),@"input_w":@(g.in_w),@"input_h":@(g.in_h),@"output_w":@(g.out_w),@"output_h":@(g.out_h),@"history_reset":@(!g.hist_ok)};
}
/* Flag dm_fg_mv_dyn (default on): pixels that are not still world get no screen motion instead of the camera's. */
static _Atomic int g_mv_dyn = 1;
void dm_fg_set_mv_dyn(int on) { atomic_store(&g_mv_dyn, on != 0); MLOG("[flag] dm_fg_mv_dyn = %d: %s", on != 0, on ? "moving pixels get no camera motion" : "camera motion everywhere"); }

/* Reconstructing identical MetalFX interpolators repeatedly grows device
 * allocations on the tested Mac, even after the old Objective-C object dies.
 * Keep a bounded set of exact configurations without eviction/rebuild churn.
 * In-flight frames retain their own resource payload independently of the
 * cache. Once full, new configurations use the previous uncached path. This does not establish or
 * fix every source of long-session memory growth. Diagnostic opt-out below. */
#define MFX_FI_CACHE 4
static id<MTL4FXFrameInterpolator> g_fi_cache[MFX_FI_CACHE];
static unsigned g_fi_cache_count;
static int fi_cache_on(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("DM_FRAMEGEN_FI_CACHE"); on = !e || strcmp(e, "0"); }
    return on;
}
static id<MTL4FXFrameInterpolator> fi_cached(NSUInteger iw, NSUInteger ih) {
    if (!fi_cache_on()) return nil;
    for (unsigned i = 0; i < g_fi_cache_count; i++) {
        id<MTL4FXFrameInterpolator> fi = g_fi_cache[i];
        if (fi.inputWidth == iw && fi.inputHeight == ih && fi.outputWidth == g.out_w &&
            fi.outputHeight == g.out_h && fi.colorTextureFormat == g.scene_fmt) {
            MLOG("reuse cached interpolator %u: %lux%lu -> %lux%lu; reset history", i,
                 (unsigned long)iw, (unsigned long)ih, (unsigned long)g.out_w, (unsigned long)g.out_h);
            return fi;
        }
    }
    return nil;
}

static _Atomic int g_on;
static _Atomic int g_reset_requested;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void dm_fg_init(void) {
    int value=dm_framegen_requested();
    if (value) {
        // The loader asks before NVN initialization, after launcher settings
        // have been applied. Both NVN and this preflight use the default device.
        id<MTLDevice> device=MTLCreateSystemDefaultDevice();
        value=device && [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:device];
        if (value) MLOG("experimental frame generation available: 30 real + 30 generated frames requested");
        else MLOG("[RED] this GPU does not support Metal 4 frame interpolation; keeping normal rendering and frame rate");
    }
    atomic_store(&g_on,value);
}
int dm_fg_enabled(void) {
    // Lifecycle callbacks can run on the launcher before Play applies settings.
    // Cache device capability, never an early off/default launcher selection.
    if (!dm_framegen_requested()) return 0;
    pthread_once(&g_once,dm_fg_init);
    return atomic_load_explicit(&g_on,memory_order_relaxed);
}
void dm_fg_request_reset(void) { atomic_store(&g_reset_requested,1); }
void dm_fg_reset(void) {
    int profile=dm_fg_profile_on(),had_prev=g.prev_ok,had_hist=g.hist_ok; double t=profile?CACurrentMediaTime():0;
    g.prev_ok=g.hist_ok=g.scene_ok=g.cam_ok=0; g.depth=nil; g.ui=nil; g.last_prepare_s=0; g.pdepth_frame=0;
    if (profile) dm_fg_profile_event(@"history_clear",@{@"prepare":@(g.frames),@"had_prev":@(had_prev),@"had_history":@(had_hist),@"cpu_ms":@((CACurrentMediaTime()-t)*1000)});
}
int dm_fg_available(id<MTLDevice> device) {
    return device && dm_fg_enabled();
}
static _Atomic int g_slot_refs[MFX_OUT];
static pthread_mutex_t g_slots_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_slots_cv=PTHREAD_COND_INITIALIZER;
static void slot_release(int slot) {
    if (slot<0 || slot>=MFX_OUT) return;
    pthread_mutex_lock(&g_slots_mu);
    if (atomic_fetch_sub(&g_slot_refs[slot],1)<=0) MDIE("output slot %d released without an owner",slot);
    pthread_cond_broadcast(&g_slots_cv);
    pthread_mutex_unlock(&g_slots_mu);
}
void dm_fg_generation_done(int slot) { slot_release(slot); }
void dm_fg_display_retain(int slot) { atomic_fetch_add(&g_slot_refs[slot],1); }
void dm_fg_display_done(int slot) { slot_release(slot); }
int dm_fg_slot_refs(int slot) { return slot>=0 && slot<MFX_OUT ? atomic_load(&g_slot_refs[slot]) : 0; }
// Before replacing a configuration, the adapter drains queued display owners.
// Wait for GPU feedback as well: a dropped picture can still be generating.
void dm_fg_wait_idle(void) {
    pthread_mutex_lock(&g_slots_mu);
    for (;;) {
        int busy=0; for (int i=0;i<MFX_OUT;i++) busy+=atomic_load(&g_slot_refs[i]);
        if (!busy) break;
        pthread_cond_wait(&g_slots_cv,&g_slots_mu);
    }
    pthread_mutex_unlock(&g_slots_mu);
}
void dm_fg_gpu_time(double seconds) {
    if (!(seconds>0 && seconds<10)) return;
    static double times[300]; static int count;
    pthread_mutex_lock(&g_slots_mu);
    times[count++]=seconds*1000;
    if (count==300) {
        for (int i=1;i<300;i++) { double x=times[i]; int j=i-1; while (j>=0 && times[j]>x) { times[j+1]=times[j]; j--; } times[j+1]=x; }
        MLOG("generation GPU work over 300 pictures: p50 %.3f ms, p95 %.3f ms, max %.3f ms (motion and interpolation)",times[149],times[284],times[299]);
        count=0;
    }
    pthread_mutex_unlock(&g_slots_mu);
}

static id<MTLTexture> mk(MTLPixelFormat f, NSUInteger w, NSUInteger h, MTLTextureUsage u) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = u; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g.dev newTextureWithDescriptor:d];
    if (!t) MDIE("texture %lux%lu format %lu", (unsigned long)w, (unsigned long)h, (unsigned long)f);
    if (!g.rs) { NSError *e = nil; g.rs = [g.dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&e]; if (!g.rs) MDIE("residency set: %s", e.localizedDescription.UTF8String); }
    [g.rs addAllocation:t]; [g.rs commit];
    return t;
}
static void drop(id<MTLTexture> __strong *t) { if (*t) { [g.rs removeAllocation:*t]; *t = nil; } }

// Scene/output textures follow the canvas size; UI borrows the completed canvas.
static void ensure_out(id<MTLDevice> dev, NSUInteger w, NSUInteger h, MTLPixelFormat fmt) {
    if (!g.dev) g.dev = dev;
    if (g.out_w == w && g.out_h == h && g.scene[0] && (!fmt || fmt == g.scene_fmt)) return;
    if (!fmt) fmt = g.scene_fmt ? g.scene_fmt : MTLPixelFormatRG11B10Float;
    for (int i = 0; i < 2; i++) drop(&g.scene[i]);
    g.ui=nil;
    for (int i = 0; i < MFX_OUT; i++) { drop(&g.out[i]); g.outv[i] = nil; }

    for (int i = 0; i < 2; i++) g.scene[i] = mk(fmt, w, h, MTLTextureUsageShaderRead);   // blit copies of the canvas
    g.scene_fmt = fmt;
    for (int i = 0; i < MFX_OUT; i++) {
        g.out[i] = mk(MTLPixelFormatRGBA8Unorm_sRGB, w, h, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView);
        g.outv[i] = [g.out[i] newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
    }
    g.out_w = w; g.out_h = h; g.fi = nil; g.prev_ok = g.hist_ok = 0;
    MLOG("scene (format %lu) / output textures %lux%lu; UI borrows the completed canvas", (unsigned long)fmt, (unsigned long)w, (unsigned long)h);
}
id<MTLTexture> dm_fg_scene_target(id<MTLDevice> dev, NSUInteger w, NSUInteger h, MTLPixelFormat fmt) { ensure_out(dev, w, h, fmt); return g.scene[g.cur]; }
void dm_fg_note_ui(id<MTLTexture> canvas) {
    g.ui=canvas && canvas.width==g.out_w && canvas.height==g.out_h && canvas.pixelFormat==g.scene_fmt ? canvas : nil;
}
id<MTLResidencySet> dm_fg_residency(void) { return g.rs; }
void dm_fg_note_scene(void) { g.scene_ok = 1; }
void dm_fg_note_depth(id<MTLTexture> d) { if (d && d.pixelFormat == MTLPixelFormatDepth32Float && d.textureType == MTLTextureType2D) g.depth = d; }
void dm_fg_note_camera(const float *c, int n) {
    if (n < 84) return;
    for (int i = 0; i < 84; i++) { if (!isfinite(c[i])) { g.cam_ok=0; return; } g.cam[i] = c[i]; }
    g.cam_ok = c[56] > 0 && c[57] > c[56] && c[62] > 0 && c[70] > 0;   // near, far, aspect, vertical field of view (radians)
}

static void ensure_fi(NSUInteger iw, NSUInteger ih) {
    if (g.fi && g.in_w == iw && g.in_h == ih && g.fi.colorTextureFormat == g.scene_fmt && g.fi.outputWidth == g.out_w && g.fi.outputHeight == g.out_h) return;
    NSError *e = nil;
    int profile=dm_fg_profile_on(); double begin=profile?CACurrentMediaTime():0;
    NSUInteger old_w=g.in_w,old_h=g.in_h;
    g.fi = fi_cached(iw, ih);
    int cache_hit=g.fi!=nil;
    double lookup=profile?CACurrentMediaTime():0,compiler_end=lookup,create_end=lookup;
    if (!g.fi) {
        MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
        d.colorTextureFormat = g.scene_fmt; d.outputTextureFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        d.depthTextureFormat = MTLPixelFormatR32Float; d.motionTextureFormat = MTLPixelFormatRG16Float; d.uiTextureFormat = g.scene_fmt;
        d.inputWidth = iw; d.inputHeight = ih; d.outputWidth = g.out_w; d.outputHeight = g.out_h;
        id<MTL4Compiler> comp = [g.dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (profile) compiler_end=CACurrentMediaTime();
        if (!comp) MDIE("MTL4 compiler: %s", e.localizedDescription.UTF8String);
        if (![MTLFXFrameInterpolatorDescriptor supportsMetal4FX:g.dev]) MDIE("this GPU has no Metal 4 MetalFX frame interpolation");
        g.fi = [d newFrameInterpolatorWithDevice:g.dev compiler:comp];
        if (profile) create_end=CACurrentMediaTime();
        if (!g.fi) MDIE("frame interpolator %lux%lu -> %lux%lu not created", (unsigned long)iw, (unsigned long)ih, (unsigned long)g.out_w, (unsigned long)g.out_h);
        if (fi_cache_on() && g_fi_cache_count < MFX_FI_CACHE) g_fi_cache[g_fi_cache_count++] = g.fi;
    }
    double allocation_begin=profile?CACurrentMediaTime():0;
    drop(&g.mv); g.mv = mk(MTLPixelFormatRG16Float, iw, ih, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
    drop(&g.ndepth); g.ndepth = mk(MTLPixelFormatR32Float, iw, ih, MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead);
    drop(&g.pdepth); g.pdepth = mk(MTLPixelFormatR32Float, iw, ih, MTLTextureUsageShaderRead); g.pdepth_frame = 0;
    drop(&g.flow); g.flow=mk(MTLPixelFormatRGBA16Float,(iw+7)/8,(ih+7)/8,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
    drop(&g.flow_fill); g.flow_fill=mk(MTLPixelFormatRGBA16Float,(iw+7)/8,(ih+7)/8,MTLTextureUsageShaderRead|MTLTextureUsageShaderWrite);
    double allocation_end=profile?CACurrentMediaTime():0;
    if (!g.mv_ps) {
        static const char *src =
            "#include <metal_stdlib>\nusing namespace metal;\n"
            "struct P { float4x4 reproj; float2 size; float2 inv_size; float yflip; float dyn, pad1, pad2; };\n"
            // view distance from a depth value (not reversed, infinite far plane: z = near / (1 - d)), in units of near
            "static float vz(float d) { return 1.0 / max(1.0 - d, 1e-7); }\n"
            // camera motion of each depth pixel: where it was in the previous frame, in pixels of this texture. With dyn, a
            // pixel whose distance at that place in the previous frame is not what a still point would have had moved
            // itself: no motion on screen. Still: within the 3x3 range of the previous depth there (1 % margin) where that
            // depth is continuous (a slope), and within 1 % of one of the nine where it is not (an edge: the range of Link
            // and the land behind him would take in any distance between them)
            "kernel void dm_fg_mv(depth2d<float, access::read> d [[texture(0)]], texture2d<float, access::write> mv [[texture(1)]],\n"
            "                   texture2d<float, access::read> pd [[texture(2)]], texture2d<float, access::write> nd [[texture(3)]], constant P &p [[buffer(0)]], uint2 g [[thread_position_in_grid]]) {\n"
            "  if (g.x >= uint(p.size.x) || g.y >= uint(p.size.y)) return;\n"
            "  float2 uv = (float2(g) + 0.5) * p.inv_size;\n"
            // Nearest depth preserves surfaces when DRS changes the source size.
            "  uint2 ds=uint2(d.get_width(),d.get_height()); float d0 = d.read(min(uint2(uv*float2(ds)),ds-1)); nd.write(d0,g);\n"
            "  float4 c = p.reproj * float4(uv.x * 2.0 - 1.0, p.yflip * (1.0 - uv.y * 2.0), d0 * 2.0 - 1.0, 1.0);\n"
            "  float2 m = 0.0;\n"
            "  if (c.w > 1e-7) {\n"
            "    float2 n = c.xy / c.w, prev = float2(n.x * 0.5 + 0.5, 0.5 - 0.5 * p.yflip * n.y);\n"
            "    m = (prev - uv) * p.size;\n"
            "    int2 q = int2(floor(prev * p.size));\n"
            "    if (p.dyn > 0.5 && d0 < 1.0 && all(q >= 1) && all(q < int2(p.size) - 1)) {\n"
            "      float ze = vz(c.z / c.w * 0.5 + 0.5), zmin = 3.4e38, zmax = 0.0; bool near = false;\n"
            "      for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {\n"
            "        float z = vz(pd.read(uint2(q + int2(x, y))).x); zmin = min(zmin, z); zmax = max(zmax, z); near = near || fabs(z - ze) <= ze * 0.01; }\n"
            "      bool still = zmax <= zmin * 1.05 ? (ze >= zmin * 0.99 && ze <= zmax * 1.01) : near;\n"
            "      if (!still) m = 0.0;\n"
            "    }\n"
            "  }\n"
            "  if (any(isnan(m)) || any(isinf(m))) m = 0.0;\n"
            "  mv.write(float4(m, 0.0, 0.0), g);\n"
            "}\n";
        MTLCompileOptions *o = [MTLCompileOptions new]; o.mathMode = MTLMathModeSafe;
        static const char *flow_src=
            "\n"
            "static bool same_depth(float a,float b) { return fabs(a-b)<max(.0005f,.03f*min(1-a,1-b)); }\n"
            // Each flow sample used to repeat this classification for its 7x7
            // neighborhood. Classify once per tile, then reuse those results.
            // flow_fill is scratch until the later fill pass; no extra image.
            "kernel void dm_fg_flow_regions(texture2d<float,access::read> z[[texture(0)]],texture2d<float,access::read> pd[[texture(1)]],texture2d<float,access::write> mask[[texture(2)]],constant P&p[[buffer(0)]],uint2 xy[[thread_position_in_grid]]) {\n"
            " uint2 size=uint2(mask.get_width(),mask.get_height());if(any(xy>=size))return;bool moving=false;\n"
            " float2 q=(float2(xy)+.5)/float2(size);float d=z.read(min(uint2(q*p.size),uint2(p.size)-1)).x;\n"
            " float4 c=p.reproj*float4(q.x*2-1,p.yflip*(1-q.y*2),d*2-1,1);\n"
            " if(p.pad1>.5 && c.w>1e-7){\n"
            "  float2 pp=float2(c.x/c.w*.5+.5,.5-.5*p.yflip*c.y/c.w);int2 px=int2(floor(pp*p.size));\n"
            "  if(all(px>=1)&&all(px<int2(p.size)-1)){\n"
            "   float expected=vz(c.z/c.w*.5+.5),lo=3.4e38,hi=0;bool near=false;\n"
            "   for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++){float a=vz(pd.read(uint2(px+int2(x,y))).x);lo=min(lo,a);hi=max(hi,a);near=near||fabs(a-expected)<=expected*.01;}\n"
            "   moving=!(hi<=lo*1.05?(expected>=lo*.99&&expected<=hi*1.01):near);\n"
            "  }\n"
            " }\n"
            " mask.write(float4(moving?1.f:0.f,0,0,0),xy);\n"
            "}\n"
            "kernel void dm_fg_flow(texture2d<float> cur[[texture(0)]],texture2d<float> prev[[texture(1)]],texture2d<float,access::read> z[[texture(2)]],texture2d<float,access::read> mv[[texture(3)]],texture2d<float,access::write> field[[texture(4)]],texture2d<float,access::read> pd[[texture(5)]],texture2d<float,access::read> mask[[texture(6)]],constant P&p[[buffer(0)]],uint2 xy[[thread_position_in_grid]]) {\n"
            " uint2 fs=uint2(field.get_width(),field.get_height());if(any(xy>=fs))return;\n"
            " constexpr sampler sm(coord::normalized,address::clamp_to_edge,filter::linear);\n"
            " float2 uv=(float2(xy)+.5)/float2(fs),duv=1.0/float2(fs);\n"
            " uint2 center=min(uint2(uv*p.size),uint2(p.size)-1);float cz=z.read(center).x;\n"
            " float2 base=mv.read(center).xy/p.size, f=base;float before=0,after=0;\n"
            " uint2 old=min(uint2(clamp(uv+base,0.f,1.f)*p.size),uint2(p.size)-1);if(p.pad1>.5 && pd.read(old).x<cz-.003){field.write(float4(base*p.size,cz,0),xy);return;}\n"
            " // Refine non-rigid geometry, not lighting changes on camera-consistent world.\n"
            " if(p.pad1>.5){\n"
            "  bool moving=false;\n"
            "  for(int j=-3;j<=3 && !moving;j++)for(int i=-3;i<=3;i++){\n"
            "   int2 q=int2(xy)+int2(i,j);if(any(q<0)||any(q>=int2(fs)))continue;\n"
            "   if(mask.read(uint2(q)).x>.5){moving=true;break;}\n"
            "  }\n"
            "  if(!moving){field.write(float4(base*p.size,cz,0),xy);return;}\n"
            " }\n"
            " for(int it=0;it<9;it++){\n"
            "  float xx=.01,yy=.01,xyg=0,bx=0,by=0,cost=0,weight=0;\n"
            "  for(int j=-3;j<=3;j++)for(int i=-3;i<=3;i++){\n"
            "   float2 q=uv+float2(i,j)*duv;if(any(q<=duv)||any(q>=1-duv))continue;\n"
            "   uint2 zi=min(uint2(q*p.size),uint2(p.size)-1);if(!same_depth(cz,z.read(zi).x))continue;\n"
            "   float2 v=q+f;if(any(v<=duv)||any(v>=1-duv))continue;\n"
            "   float3 a=cur.sample(sm,q).rgb,b=prev.sample(sm,v).rgb;\n"
            "   float3 gx=(prev.sample(sm,v+float2(duv.x,0)).rgb-prev.sample(sm,v-float2(duv.x,0)).rgb)*.5;\n"
            "   float3 gy=(prev.sample(sm,v+float2(0,duv.y)).rgb-prev.sample(sm,v-float2(0,duv.y)).rgb)*.5;\n"
            "   float3 diff=a-b;xx+=dot(gx,gx);yy+=dot(gy,gy);xyg+=dot(gx,gy);bx+=dot(gx,diff);by+=dot(gy,diff);cost+=dot(diff,diff);weight++;\n"
            "  }\n"
            "  float error=cost/max(weight,1.f);if(!it)before=error;after=error;\n"
            "  if(it==8||(!it && error<.00001))break;\n"
            "  bx-=.01*(f.x-base.x)/duv.x;by-=.01*(f.y-base.y)/duv.y;\n"
            "  float det=xx*yy-xyg*xyg;float2 step=float2(yy*bx-xyg*by,xx*by-xyg*bx)/det;\n"
            "  // Trust region for the local brightness linearization, in field texels.\n"
            "  f+=clamp(step,float2(-1),float2(1))*duv;\n"
            " }\n"
            " uint2 oldpos=min(uint2(clamp(uv+f,0.f,1.f)*p.size),uint2(p.size)-1);\n"
            " bool useful=after<before*.9 && all(isfinite(f)) && (p.pad1<.5 || same_depth(cz,pd.read(oldpos).x));\n"
            " field.write(float4(f*p.size,cz,useful?1.f:0.f),xy);\n"
            "}\n"
            "kernel void dm_fg_flow_fill(texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],uint2 xy[[thread_position_in_grid]]){\n"
            " int2 size=int2(src.get_width(),src.get_height());if(any(xy>=uint2(size)))return;float4 c=src.read(xy);if(c.w>.5){dst.write(c,xy);return;}\n"
            " float2 sum=0;float total=0;\n"
            " for(int j=-3;j<=3;j++)for(int i=-3;i<=3;i++){int2 q=int2(xy)+int2(i,j);if(any(q<0)||any(q>=size))continue;float4 v=src.read(uint2(q));\n"
            "  if(v.w>.5 && same_depth(c.z,v.z)){float w=1.f/(1.f+i*i+j*j);sum+=w*v.xy;total+=w;}}\n"
            " if(total>0)c=float4(sum/total,c.z,1);dst.write(c,xy);\n"
            "}\n"
            "kernel void dm_fg_flow_apply(texture2d<float,access::read> field[[texture(0)]],texture2d<float,access::read> z[[texture(1)]],texture2d<float,access::write> mv[[texture(2)]],constant P&p[[buffer(0)]],uint2 xy[[thread_position_in_grid]]){\n"
            " if(any(xy>=uint2(p.size)))return;int2 fs=int2(field.get_width(),field.get_height());\n"
            " float2 q=(float2(xy)+.5)/p.size*float2(fs)-.5;int2 b=int2(floor(q));float2 t=fract(q),sum=0;float total=0,cz=z.read(xy).x;\n"
            " for(int j=0;j<2;j++)for(int i=0;i<2;i++){\n"
            "  float4 v=field.read(uint2(clamp(b+int2(i,j),int2(0),fs-1)));float w=(i?t.x:1-t.x)*(j?t.y:1-t.y);\n"
            "  if(v.w>.5 && same_depth(cz,v.z)){sum+=v.xy*w;total+=w;}\n"
            " }\n"
            // Unrefined pixels keep the motion already written by dm_fg_mv.
            " if(total>.001)mv.write(float4(sum/total,0,0),xy);\n"
            "}\n";
        id<MTLLibrary> lib = [g.dev newLibraryWithSource:[@(src) stringByAppendingString:@(flow_src)] options:o error:&e];
        id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"dm_fg_mv"] : nil;
        g.mv_ps = fn ? [g.dev newComputePipelineStateWithFunction:fn error:&e] : nil;
        if (!g.mv_ps) MDIE("motion vector kernel: %s", e.localizedDescription.UTF8String);
        MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 1; ad.maxTextureBindCount = 7;
        for (int i = 0; i < MFX_OUT; i++) {
            g.mv_args[i] = [g.dev newArgumentTableWithDescriptor:ad error:&e]; if (!g.mv_args[i]) MDIE("argument table: %s", e.localizedDescription.UTF8String);
            g.flow_regions_args[i]=[g.dev newArgumentTableWithDescriptor:ad error:&e];
            g.flow_args[i]=[g.dev newArgumentTableWithDescriptor:ad error:&e]; g.flow_fill_args[i]=[g.dev newArgumentTableWithDescriptor:ad error:&e]; g.flow_apply_args[i]=[g.dev newArgumentTableWithDescriptor:ad error:&e];
            if (!g.flow_regions_args[i] || !g.flow_args[i] || !g.flow_fill_args[i] || !g.flow_apply_args[i]) MDIE("optical-flow argument table: %s",e.localizedDescription.UTF8String);
            g.mv_par[i] = [g.dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; [g.rs addAllocation:g.mv_par[i]];
        }
        [g.rs commit];
        g.flow_regions_ps=[g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"dm_fg_flow_regions"] error:&e];
        g.flow_ps=[g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"dm_fg_flow"] error:&e];
        g.flow_fill_ps=[g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"dm_fg_flow_fill"] error:&e];
        g.flow_apply_ps=[g.dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"dm_fg_flow_apply"] error:&e];
        if (!g.flow_regions_ps || !g.flow_ps || !g.flow_fill_ps || !g.flow_apply_ps) MDIE("optical-flow kernels: %s",e.localizedDescription.UTF8String);
        g.fence = [g.dev newFence];
        const char *yf = getenv("DM_FRAMEGEN_YFLIP"); g.yflip = yf ? atof(yf) : 1.0;   // diagnostic: -1 tries the other clip-space y convention
    }
    g.in_w = iw; g.in_h = ih; g.prev_ok = g.hist_ok = 0;
    if (profile) dm_fg_profile_event(@"configuration",@{@"prepare":@(g.frames),@"old_w":@(old_w),@"old_h":@(old_h),@"input_w":@(iw),@"input_h":@(ih),@"cache_hit":@(cache_hit),@"lookup_ms":@((lookup-begin)*1000),@"compiler_ms":@((compiler_end-lookup)*1000),@"interpolator_ms":@((create_end-compiler_end)*1000),@"motion_depth_allocation_ms":@((allocation_end-allocation_begin)*1000),@"total_cpu_ms":@((CACurrentMediaTime()-begin)*1000),@"motion_depth_bytes":@(g.mv.allocatedSize+g.ndepth.allocatedSize+g.pdepth.allocatedSize+g.flow.allocatedSize+g.flow_fill.allocatedSize),@"process_gpu_allocated_bytes":@(g.dev.currentAllocatedSize),@"history_invalidated":@YES});
    MLOG("frame interpolator: depth / motion %lux%lu -> %lux%lu (scene format %lu, output RGBA8 sRGB, UI composited, format %lu)", (unsigned long)iw, (unsigned long)ih, (unsigned long)g.out_w, (unsigned long)g.out_h, (unsigned long)g.scene_fmt, (unsigned long)g.scene_fmt);
}

// 4x4 inverse (Gauss-Jordan, partial pivoting) and product, row-major, in double: the view-projection matrices hold
// world coordinates in the thousands, and only the combined reprojection goes to the GPU in float.
static int inv4(const double a_[16], double r[16]) {
    double a[16]; memcpy(a, a_, sizeof a);
    for (int i = 0; i < 16; i++) r[i] = i % 5 == 0;
    for (int c = 0; c < 4; c++) {
        int p = c; for (int k = c + 1; k < 4; k++) if (fabs(a[k * 4 + c]) > fabs(a[p * 4 + c])) p = k;
        if (fabs(a[p * 4 + c]) < 1e-12) return 0;
        if (p != c) for (int k = 0; k < 4; k++) { double t = a[c * 4 + k]; a[c * 4 + k] = a[p * 4 + k]; a[p * 4 + k] = t; t = r[c * 4 + k]; r[c * 4 + k] = r[p * 4 + k]; r[p * 4 + k] = t; }
        double s = 1.0 / a[c * 4 + c];
        for (int k = 0; k < 4; k++) { a[c * 4 + k] *= s; r[c * 4 + k] *= s; }
        for (int q = 0; q < 4; q++) if (q != c) { double f = a[q * 4 + c]; if (f != 0) for (int k = 0; k < 4; k++) { a[q * 4 + k] -= f * a[c * 4 + k]; r[q * 4 + k] -= f * r[c * 4 + k]; } }
    }
    return 1;
}
static void mul4(const double a[16], const double b[16], double r[16]) {
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) { double s = 0; for (int k = 0; k < 4; k++) s += a[i * 4 + k] * b[k * 4 + j]; r[i * 4 + j] = s; }
}
// A camera jump (teleport, cutscene cut) or a turn of more than 25 degrees in one game frame is not interpolated.
static int camera_cut(void) {
    double dx = g.cam[47] - g.prev_cam[47], dy = g.cam[51] - g.prev_cam[51], dz = g.cam[55] - g.prev_cam[55];
    double f = g.cam[8] * g.prev_cam[8] + g.cam[9] * g.prev_cam[9] + g.cam[10] * g.prev_cam[10];   // view z axes
    return sqrt(dx * dx + dy * dy + dz * dz) > 8.0 || f < cos(25.0 * M_PI / 180.0);
}

int dm_fg_frame_prepare(double frame_s,int interpolate) {
    // Suspend/resume can happen without any guest presents. Never touch the
    // submit-thread-owned camera/texture state from the front-end callback.
    // Keep this frame's inputs, but seed history again before interpolation.
    if (atomic_exchange(&g_reset_requested,0)) {
        g.prev_ok=g.hist_ok=0; g.last_prepare_s=0; g.pdepth_frame=0;
        if (dm_fg_profile_on()) dm_fg_profile_event(@"history_boundary",@{@"prepare":@(g.frames)});
    }
    g.frames++;
    id<MTLTexture> depth = g.depth;
    int ok = g.scene_ok && g.cam_ok && depth && g.ui;
    /* MetalFX deltaTime is the interval between real frames, not the display
       interval that also counts inserted frames. */
    double now = CACurrentMediaTime(), dt = g.last_prepare_s > 0 ? now - g.last_prepare_s : frame_s;
    g.last_prepare_s = now; g.dt = dt > 1.0 / 250 && dt < 0.1 ? dt : frame_s > 0 ? frame_s : 1.0 / 30;
    g.scene_ok_was = g.scene_ok; g.cam_ok_was = g.cam_ok; g.scene_ok = g.cam_ok = 0; g.depth = nil;
    if (!ok) {
        g.skip_input++; g.miss[0] += !g.scene_ok_was; g.miss[1] += !g.cam_ok_was; g.miss[2] += !depth; g.miss[3] += !g.ui;
        g.prev_ok = g.hist_ok = 0; return -1;
    }
    // MetalFX's input size is the depth/motion grid, not the upscaled color.
    // Normalize game depth to the first valid grid until the canvas changes;
    // DRS then needs no drain, reallocation or temporal-history reset. Keep
    // one current/previous depth pair, never old histories keyed by DRS size.
    NSUInteger iw=g.in_w, ih=g.in_h;
    if (!g.fi) {
        // Bound auxiliary depth/motion work; full-resolution scene/UI/output
        // textures are unchanged. This is not lower-resolution interpolation.
        double scale=fmin(1.0,sqrt((1280.0*720.0)/(depth.width*depth.height)));
        iw=fmax(1,floor(depth.width*scale)); ih=fmax(1,floor(depth.height*scale));
    }
    ensure_fi(iw,ih);
    if (!g.prev_ok || camera_cut() || !interpolate) {
        if (!interpolate) g.skip_present++; else if (g.prev_ok) g.skip_cut++; else g.skip_first++;
        memcpy(g.prev_cam, g.cam, sizeof g.cam); g.cur ^= 1; g.prev_ok = 1; g.hist_ok = 0;
        return -1;
    }
    double vc[16], vp[16], ic[16], m[16];
    for (int i = 0; i < 16; i++) { vc[i] = g.cam[12 + i]; vp[i] = g.prev_cam[12 + i]; }
    if (!inv4(vc, ic)) { g.skip_input++; g.prev_ok = g.hist_ok = 0; return -1; }
    mul4(vp, ic, m);
    int s=-1;
    for (int i=1;i<=MFX_OUT;i++) {
        int candidate=(g.slot+i)%MFX_OUT;
        if (!atomic_load(&g_slot_refs[candidate])) { s=candidate; break; }
    }
    if (s<0) { g.skip_busy++; dm_fg_reset(); return -1; }
    g.slot=s; atomic_store(&g_slot_refs[s],2);
    float *par = g.mv_par[s].contents;
    for (int c = 0; c < 4; c++) for (int r = 0; r < 4; r++) par[c * 4 + r] = (float)m[r * 4 + c];   // float4x4 is column-major
    par[16] = (float)g.in_w; par[17] = (float)g.in_h; par[18] = 1.0f / g.in_w; par[19] = 1.0f / g.in_h; par[20] = (float)g.yflip;
    par[21] = atomic_load(&g_mv_dyn) && g.pdepth_frame && g.pdepth_frame == g.frames - 1 ? 1.0f : 0.0f;   // the previous game frame's depth is there
    par[22]=g.pdepth_frame && g.pdepth_frame==g.frames-1;
    g.enc_depth = depth;
    return s;
}
NSArray *dm_fg_frame_encode(id<MTL4CommandBuffer> cb, int s, id<MTL4CounterHeap> heap, NSUInteger stamp) {
    id<MTLTexture> depth = g.enc_depth; g.enc_depth = nil;
    [g.mv_args[s] setTexture:depth.gpuResourceID atIndex:0]; [g.mv_args[s] setTexture:g.mv.gpuResourceID atIndex:1]; [g.mv_args[s] setAddress:g.mv_par[s].gpuAddress atIndex:0];
    [g.mv_args[s] setTexture:g.pdepth.gpuResourceID atIndex:2];
    [g.mv_args[s] setTexture:g.ndepth.gpuResourceID atIndex:3];
    id<MTL4ComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageDispatch | MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];   // the game's frame is done
    [e setComputePipelineState:g.mv_ps]; [e setArgumentTable:g.mv_args[s]];
    [e dispatchThreads:MTLSizeMake(g.in_w, g.in_h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    // ponytail: local Lucas-Kanade refinement; fast/ambiguous motion needs engine
    // vectors or multiscale flow. Stay on this queue without CPU readback.
    // Depth-aware filling keeps foreground estimates out of distant background;
    // uninformative patches retain the camera/depth estimate.
    id<MTL4ArgumentTable> ra=g.flow_regions_args[s], fa=g.flow_args[s], sa=g.flow_fill_args[s], aa=g.flow_apply_args[s];
    [ra setTexture:g.ndepth.gpuResourceID atIndex:0]; [ra setTexture:g.pdepth.gpuResourceID atIndex:1]; [ra setTexture:g.flow_fill.gpuResourceID atIndex:2]; [ra setAddress:g.mv_par[s].gpuAddress atIndex:0];
    [fa setTexture:g.scene[g.cur].gpuResourceID atIndex:0]; [fa setTexture:g.scene[g.cur^1].gpuResourceID atIndex:1];
    [fa setTexture:g.ndepth.gpuResourceID atIndex:2]; [fa setTexture:g.mv.gpuResourceID atIndex:3]; [fa setTexture:g.flow.gpuResourceID atIndex:4]; [fa setTexture:g.pdepth.gpuResourceID atIndex:5]; [fa setTexture:g.flow_fill.gpuResourceID atIndex:6]; [fa setAddress:g.mv_par[s].gpuAddress atIndex:0];
    [sa setTexture:g.flow.gpuResourceID atIndex:0]; [sa setTexture:g.flow_fill.gpuResourceID atIndex:1];
    [aa setTexture:g.flow_fill.gpuResourceID atIndex:0]; [aa setTexture:g.ndepth.gpuResourceID atIndex:1]; [aa setTexture:g.mv.gpuResourceID atIndex:2]; [aa setAddress:g.mv_par[s].gpuAddress atIndex:0];
    [e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:g.flow_regions_ps]; [e setArgumentTable:ra];
    [e dispatchThreads:MTLSizeMake(g.flow.width,g.flow.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:g.flow_ps]; [e setArgumentTable:fa];
    [e dispatchThreads:MTLSizeMake(g.flow.width,g.flow.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:g.flow_fill_ps]; [e setArgumentTable:sa];
    [e dispatchThreads:MTLSizeMake(g.flow.width,g.flow.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    [e setComputePipelineState:g.flow_apply_ps]; [e setArgumentTable:aa];
    [e dispatchThreads:MTLSizeMake(g.in_w,g.in_h,1) threadsPerThreadgroup:MTLSizeMake(16,16,1)];
    [e updateFence:g.fence afterEncoderStages:MTLStageDispatch];
    // this frame's depth for the next one's still-world test, once the motion has read the previous one
    if (heap) {
        [e endEncoding]; [cb writeTimestampIntoHeap:heap atIndex:stamp+1];
        e=[cb computeCommandEncoder];
        [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    } else [e barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:g.ndepth toTexture:g.pdepth];
    [e endEncoding];
    if (heap) [cb writeTimestampIntoHeap:heap atIndex:stamp+2];
    g.pdepth_frame = g.frames;
    id<MTL4FXFrameInterpolator> fi = g.fi;
    fi.colorTexture = g.scene[g.cur]; fi.prevColorTexture = g.scene[g.cur ^ 1]; fi.depthTexture = g.ndepth; fi.motionTexture = g.mv;
    fi.uiTexture = g.ui; fi.uiTextureComposited = YES; fi.outputTexture = g.out[s]; fi.fence = g.fence;
    fi.motionVectorScaleX = 1; fi.motionVectorScaleY = 1; fi.jitterOffsetX = 0; fi.jitterOffsetY = 0;
    fi.deltaTime = (float)g.dt; fi.nearPlane = (float)g.cam[56]; fi.farPlane = (float)g.cam[57];
    fi.fieldOfView = (float)(g.cam[70] * 180.0 / M_PI); fi.aspectRatio = (float)g.cam[62]; fi.depthReversed = NO;
    fi.shouldResetHistory = !g.hist_ok;
    [fi encodeToCommandBuffer:cb];
    // Metal 4 work needs explicit resource lifetime. Hold this exact frame's
    // bindings through completion, while the configuration cache retains only
    // the interpolator, not old scene/pool textures between configurations.
    NSArray *resources = @[fi, fi.colorTexture, fi.prevColorTexture, depth,
                           g.mv, g.ndepth, g.flow, g.flow_fill, g.ui, g.out[s], g.mv_par[s], g.pdepth];
    fi.colorTexture = nil; fi.prevColorTexture = nil; fi.depthTexture = nil;
    fi.motionTexture = nil; fi.uiTexture = nil; fi.outputTexture = nil;
    if (heap) [cb writeTimestampIntoHeap:heap atIndex:stamp+3];
    memcpy(g.prev_cam, g.cam, sizeof g.cam); g.cur ^= 1; g.hist_ok = 1; g.made++;
    return resources;
}

id<MTLTexture> dm_fg_output(int slot) { return slot>=0 && slot<MFX_OUT ? g.outv[slot] : nil; }
int dm_fg_has_history(void) { return g.prev_ok; }
void dm_fg_stats(char *out,size_t n) {
    snprintf(out,n,"prepared=%llu generated=%llu missing=%llu (scene/camera/depth/UI=%llu/%llu/%llu/%llu) first=%llu cuts=%llu busy=%llu real_only=%llu",
        (unsigned long long)g.frames,(unsigned long long)g.made,(unsigned long long)g.skip_input,
        (unsigned long long)g.miss[0],(unsigned long long)g.miss[1],(unsigned long long)g.miss[2],(unsigned long long)g.miss[3],
        (unsigned long long)g.skip_first,(unsigned long long)g.skip_cut,(unsigned long long)g.skip_busy,(unsigned long long)g.skip_present);
}
