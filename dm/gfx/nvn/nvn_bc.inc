// BC1->ASTC and BC2/3/7->ASTC, BC4/5->EAC kernels adapted from
// MacNativeGames 92ec79bd (MIT; dm/third_party/macnativegames/LICENSE).
#include "../tex/nvn_bc1astc_msl.h"
#include "../tex/nvn_bctc_msl.h"
static int g_bc_transcode_on = -1;
static id<MTLComputePipelineState> bc_transcode_pipeline(int bc1) {
    static id<MTLComputePipelineState> ps[2]; static int failed[2];
    if (!ps[bc1] && !failed[bc1]) {
        NSError *error = nil;
        id<MTLLibrary> lib = [g_dev newLibraryWithSource:bc1 ? @(k_bc1astc_msl) : @(k_bctc_msl) options:nil error:&error];
        id<MTLFunction> fn = [lib newFunctionWithName:bc1 ? @"bc1astc" : @"bctc"];
        ps[bc1] = fn ? [g_dev newComputePipelineStateWithFunction:fn error:&error] : nil;
        if (!ps[bc1]) { failed[bc1] = 1; MLOG("[RED] BC transcoder compilation failed: %s; using decompressed textures", error.localizedDescription.UTF8String); }
    }
    return ps[bc1];
}
static MTLPixelFormat bc_transcode_format(uint32_t f) {
    switch (f) {
        case 0x41: case 0x42: case 0x43: case 0x44: case 0x4d: return MTLPixelFormatASTC_4x4_LDR;
        case 0x45: case 0x46: case 0x47: case 0x48: case 0x4e: return MTLPixelFormatASTC_4x4_sRGB;
        case 0x49: return MTLPixelFormatEAC_R11Unorm;
        case 0x4b: return MTLPixelFormatEAC_RG11Unorm;
        default: return MTLPixelFormatInvalid;
    }
}
static int bc_transcoded_format(MTLPixelFormat f) {
    return f == MTLPixelFormatASTC_4x4_LDR || f == MTLPixelFormatASTC_4x4_sRGB || f == MTLPixelFormatEAC_R11Unorm || f == MTLPixelFormatEAC_RG11Unorm;
}
static int bc_sampled_format(const tex_t *t, uint32_t *pf) {
    if (!g_no_bc) return 0;   // Native BC needs neither conversion nor extra storage.
    if (g_bc_transcode_on < 0) {
        // Re-compression is lossy: use it only under the low-memory preset.
        const char *e = getenv("DM_NVN_BC_TRANSCODE"); g_bc_transcode_on = dm_low_memory_enabled() && (!e || strcmp(e, "0"));
        MLOG("BC fallback transcoding: %s (low-memory preset; DM_NVN_BC_TRANSCODE=0 disables; ASTC/EAC may be lossy)", g_bc_transcode_on ? "on" : "off");
    }
    if (!g_bc_transcode_on || t->d.samples > 1 || (t->d.flags & (NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET))) return 0;
    unsigned target = t->d.target;
    if (target != 1 && target != 4 && target != 8 && target != 9) return 0;
    MTLPixelFormat f = bc_transcode_format(t->d.format);
    int bc1 = t->d.format == 0x41 || t->d.format == 0x42 || t->d.format == 0x45 || t->d.format == 0x46;
    if (!f || !bc_transcode_pipeline(bc1)) return 0;
    *pf = (uint32_t)f; return 1;
}
// BC fallback, used only when the device has no native BC formats. Keep the
// original blocks beside the sampled image: copies and block render targets
// operate on those bytes, then decode on the same GPU timeline. Native BC never
// allocates these objects or compiles these kernels.
#include <objc/runtime.h>
#include "../tex/nvn_bcdec_msl.h"

@interface NvBC : NSObject {
@public
    id<MTLBuffer> blocks;
    uint32_t format, bpb;
    NSUInteger offset[16], row[16], image[16];
}
@end
@implementation NvBC
- (void)dealloc {
    // Metal validation can release the root texture during a residency commit,
    // under g_res_mu. Remove its block allocation outside that critical section.
    id<MTLBuffer> retired = blocks;
    dispatch_async(g_bc_retire_q, ^{ res_remove(retired); });
}
@end
static char g_bc_key;
static NvBC *bc_info(id<MTLTexture> t) {
    __strong id<MTLTexture> root = t;
    while (root.parentTexture) root = root.parentTexture;
    return root ? objc_getAssociatedObject(root, &g_bc_key) : nil;
}
static int bc_block(id<MTLTexture> t) { NvBC *info = g_no_bc ? bc_info(t) : nil; return info ? (int)info->bpb : 0; }
static int bc_unpacked(uint32_t f, uint32_t *pf) {
    if (!g_no_bc || f < 0x41 || f > 0x50) return 0;
    switch (f) {
        case 0x49: *pf = MTLPixelFormatR8Unorm; break;
        case 0x4a: *pf = MTLPixelFormatR8Snorm; break;
        case 0x4b: *pf = MTLPixelFormatRG8Unorm; break;
        case 0x4c: *pf = MTLPixelFormatRG8Snorm; break;
        case 0x4f: case 0x50: *pf = MTLPixelFormatRGBA16Float; break;
        case 0x45: case 0x46: case 0x47: case 0x48: case 0x4e: *pf = MTLPixelFormatRGBA8Unorm_sRGB; break;
        default: *pf = MTLPixelFormatRGBA8Unorm; break;
    }
    return 1;
}
static void bc_register(id<MTLTexture> t, uint32_t format) {
    uint32_t pf;
    if (!t || !bc_unpacked(format, &pf) || bc_info(t)) return;
    NvBC *info = [NvBC new]; info->format = format;
    int bw, bh; info->bpb = nvn_fmt_bpb(format, &bw, &bh);
    NSUInteger total = 0;
    for (NSUInteger lv = 0; lv < t.mipmapLevelCount; lv++) {
        NSUInteger w = MAX(t.width >> lv, 1u), h = MAX(t.height >> lv, 1u);
        NSUInteger planes = t.textureType == MTLTextureType3D ? MAX(t.depth >> lv, 1u) : t.arrayLength;
        info->offset[lv] = total; info->row[lv] = ((w + 3) / 4) * info->bpb; info->image[lv] = info->row[lv] * ((h + 3) / 4);
        total += info->image[lv] * planes;
    }
    info->blocks = [g_dev newBufferWithLength:MAX(total, 16u) options:MTLResourceStorageModeShared];
    if (!info->blocks) MDIE("cannot allocate %lu bytes of BC texture blocks", (unsigned long)total);
    memset(info->blocks.contents, 0, info->blocks.length); res_add(info->blocks);
    objc_setAssociatedObject(t, &g_bc_key, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// Linear BC storage is already arranged in block rows. It cannot back a Metal
// BC texture on this GPU, so use the same sampled-image cache and dirty tracking
// as block-linear data, retaining its original row stride at the CPU boundary.
static int bc_linear_bytes(const tex_t *t, unsigned lv, unsigned layer, const NVNcopyRegion *r, uint8_t *bytes, size_t row, size_t image, int write) {
    uint32_t pf;
    if (!(t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET)) || !bc_unpacked(t->d.format, &pf)) return 0;
    if (!t->mem || lv || layer || r->zoffset || r->depth > 1 || r->xoffset < 0 || r->yoffset < 0 || r->width <= 0 || r->height <= 0
        || (uint64_t)r->xoffset + r->width > t->d.width || (uint64_t)r->yoffset + r->height > t->d.height) return -1;
    int bw, bh, bb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    size_t pitch = t->d.stride ? t->d.stride : (((size_t)(t->d.width + 3) / 4 * bb + t->L.align - 1) & ~(t->L.align - 1));
    size_t wb = (size_t)(r->width + 3) / 4 * bb, rows = (size_t)(r->height + 3) / 4;
    size_t off = (size_t)(r->yoffset / 4) * pitch + (size_t)(r->xoffset / 4) * bb;
    if (row < wb || off + (rows - 1) * pitch + wb > t->L.size || (image && image < row * rows)) return -1;
    if (write) dm_guest_write_prepare(t->mem, t->L.size);
    for (size_t y = 0; y < rows; y++) {
        if (write) memcpy((uint8_t *)t->mem + off + y * pitch, bytes + y * row, wb);
        else memcpy(bytes + y * row, (const uint8_t *)t->mem + off + y * pitch, wb);
    }
    return 1;
}

static const char k_bc_write_msl[] =
"struct BCP { ulong src; uint row, image, w, h, depth, fmt, x, y, z; };\n"
"static void bc_pixels(device const uchar *src, uint f, thread float4 *o) {\n"
"  uint4 bits=uint4(0); uint bb=(f==0x41||f==0x42||f==0x45||f==0x46||f==0x49||f==0x4a)?8:16;\n"
"  thread uchar *b=(thread uchar *)&bits; for(uint i=0;i<bb;i++)b[i]=src[i];\n"
"  if(f==0x49||f==0x4a||f==0x4b||f==0x4c) { float a[32]; bool rg=f>=0x4b, sn=f==0x4a||f==0x4c;\n"
"    if(rg)bcdec_bc5_float(b,a,8,sn);else bcdec_bc4_float(b,a,4,sn);\n"
"    for(uint i=0;i<16;i++)o[i]=float4(a[i*(rg?2:1)],rg?a[i*2+1]:0,0,1); return; }\n"
"  if(f==0x4f||f==0x50) { ushort rgb[48];bcdec_bc6h_half(b,rgb,12,f==0x4f);\n"
"    for(uint i=0;i<16;i++)o[i]=float4(float(as_type<half>(rgb[i*3])),float(as_type<half>(rgb[i*3+1])),float(as_type<half>(rgb[i*3+2])),1);return; }\n"
"  uchar rgba[64]; if(f==0x43||f==0x47)bcdec_bc2(b,rgba,16);else if(f==0x44||f==0x48)bcdec_bc3(b,rgba,16);\n"
"  else if(f==0x4d||f==0x4e)bcdec_bc7(b,rgba,16);else bcdec_bc1(b,rgba,16);\n"
"  for(uint i=0;i<16;i++)o[i]=float4(rgba[i*4],rgba[i*4+1],rgba[i*4+2],rgba[i*4+3])/255.0f;\n"
"}\n"
"kernel void bc2d(constant BCP &p[[buffer(0)]],texture2d<float,access::write> dst[[texture(0)]],uint2 g[[thread_position_in_grid]]) {\n"
"  if(g.x*4>=p.w||g.y*4>=p.h)return;float4 o[16];bc_pixels((device const uchar *)p.src+g.y*p.row+g.x*((p.fmt==0x41||p.fmt==0x42||p.fmt==0x45||p.fmt==0x46||p.fmt==0x49||p.fmt==0x4a)?8:16),p.fmt,o);\n"
"  for(uint i=0;i<16;i++){uint2 q=g*4+uint2(i&3,i>>2);if(q.x<p.w&&q.y<p.h)dst.write(o[i],q+uint2(p.x,p.y));}\n"
"}\n"
"kernel void bc3d(constant BCP &p[[buffer(0)]],texture3d<float,access::write> dst[[texture(0)]],uint3 g[[thread_position_in_grid]]) {\n"
"  if(g.x*4>=p.w||g.y*4>=p.h||g.z>=p.depth)return;float4 o[16];bc_pixels((device const uchar *)p.src+g.z*p.image+g.y*p.row+g.x*((p.fmt==0x41||p.fmt==0x42||p.fmt==0x45||p.fmt==0x46||p.fmt==0x49||p.fmt==0x4a)?8:16),p.fmt,o);\n"
"  for(uint i=0;i<16;i++){uint2 q=g.xy*4+uint2(i&3,i>>2);if(q.x<p.w&&q.y<p.h)dst.write(o[i],uint3(q+uint2(p.x,p.y),g.z+p.z));}\n"
"}\n";
static id<MTLComputePipelineState> bc_pipeline(int is3d) {
    static id<MTLComputePipelineState> ps[2]; static id<MTLLibrary> lib;
    NSError *error = nil;
    if (!lib) {
        NSString *source = [@(k_bcdec_msl) stringByAppendingString:@(k_bc_write_msl)];
        lib = [g_dev newLibraryWithSource:source options:nil error:&error];
        if (!lib) MDIE("BC decoder Metal compilation failed: %s", error.localizedDescription.UTF8String);
    }
    if (!ps[is3d]) {
        ps[is3d] = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:is3d ? @"bc3d" : @"bc2d"] error:&error];
        if (!ps[is3d]) MDIE("BC decoder pipeline failed: %s", error.localizedDescription.UTF8String);
    }
    return ps[is3d];
}
// Coordinates of a view are relative to that view; the block buffer belongs to
// the root texture and includes every level, array face and depth plane.
static NSUInteger bc_offset(id<MTLTexture> t, NSUInteger lv, NSUInteger slice, MTLOrigin o, NvBC *info) {
    __strong id<MTLTexture> root = t;
    while (root.parentTexture) { lv += root.parentRelativeLevel; slice += root.parentRelativeSlice; root = root.parentTexture; }
    return info->offset[lv] + (slice + o.z) * info->image[lv] + (o.y / 4) * info->row[lv] + (o.x / 4) * info->bpb;
}
static NSUInteger bc_level(id<MTLTexture> t, NSUInteger lv) {
    __strong id<MTLTexture> root = t;
    while (root.parentTexture) { lv += root.parentRelativeLevel; root = root.parentTexture; }
    return lv;
}
// One scratch block per upload slot, reused after each ordered copy. Allocation
// during up_flush cannot call up_alloc (which could recursively flush the batch).
// Growing a slot retires its previous block with this batch, not the game frame.
static id<MTLBuffer> g_bc_scratch[3];
static void bc_transcode(id<MTL4ComputeCommandEncoder> encoder, id<MTLTexture> dst, NSUInteger slice, NSUInteger lv,
                         MTLOrigin origin, MTLSize size, NvBC *info) {
    int upload = encoder == g_up_ce;
    NSUInteger bb = dst.pixelFormat == MTLPixelFormatEAC_R11Unorm ? 8 : 16;
    NSUInteger row = ((size.width + 3) / 4) * bb, bytes = row * ((size.height + 3) / 4);
    id<MTLBuffer> scratch, params; size_t off = 0, po;
    if (upload) {
        id<MTLBuffer> old = g_bc_scratch[g_up_cur_slot];
        if (!old || old.length < bytes) {
            scratch = [g_dev newBufferWithLength:MAX(bytes, 256u) options:MTLResourceStorageModePrivate];
            if (!scratch) MDIE("cannot allocate %lu bytes of BC transcoding scratch", (unsigned long)bytes);
            res_add(scratch); if (old) [g_up_keep addObject:old]; g_bc_scratch[g_up_cur_slot] = scratch;
        } else scratch = old;
        params = up_param_alloc(&po);
    } else { off = arena_alloc(bytes, &scratch); po = arena_alloc(64, &params); }
    NSUInteger source = bc_offset(dst, lv, slice, origin, info), source_row = info->row[bc_level(dst, lv)];
    if (source > UINT32_MAX || source_row > UINT32_MAX || off > UINT32_MAX) MDIE("BC transcoding offset exceeds the kernel ABI");
    int bc1 = info->format == 0x41 || info->format == 0x42 || info->format == 0x45 || info->format == 0x46;
    uint32_t p[6] = {(uint32_t)source, (uint32_t)source_row, (uint32_t)size.width, (uint32_t)size.height,
        bc1 ? (info->format == 0x42 || info->format == 0x46) : info->format, (uint32_t)off};
    memcpy((uint8_t *)params.contents + po, p, sizeof p);
    static id<MTL4ArgumentTable> table;
    if (!upload && !table) {
        MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new]; d.maxBufferBindCount = 3;
        NSError *error = nil; table = rec_table([g_dev newArgumentTableWithDescriptor:d error:&error]);
        if (!table) MDIE("BC transcoder argument table failed: %s", error.localizedDescription.UTF8String);
    }
    id<MTL4ArgumentTable> at = upload ? g_up_ct : table;
    [encoder barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:resource_vis()];
    [encoder setArgumentTable:at]; [at setAddress:info->blocks.gpuAddress atIndex:0];
    [at setAddress:params.gpuAddress + po atIndex:1]; [at setAddress:scratch.gpuAddress atIndex:2];
    [encoder setComputePipelineState:bc_transcode_pipeline(bc1)];
    [encoder dispatchThreadgroups:MTLSizeMake((size.width + 31) / 32, (size.height + 31) / 32, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageBlit visibilityOptions:resource_vis()];
    // These are output ASTC/EAC blocks, so bypass the BC-input copy wrapper.
    [encoder copyFromBuffer:scratch sourceOffset:off sourceBytesPerRow:row sourceBytesPerImage:bytes sourceSize:size toTexture:dst
          destinationSlice:slice destinationLevel:lv destinationOrigin:origin];
    [encoder barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:resource_vis()];
    if (!upload) [encoder setArgumentTable:g_ct];
}
static void bc_decode(id<MTL4ComputeCommandEncoder> encoder, id<MTLTexture> dst, NSUInteger slice, NSUInteger lv, MTLOrigin origin, MTLSize size) {
    NvBC *info = bc_info(dst); if (!info) return;
    if (bc_transcoded_format(dst.pixelFormat)) { bc_transcode(encoder, dst, slice, lv, origin, size, info); return; }
    int is3d = dst.textureType == MTLTextureType3D;
    MTLPixelFormat pf = dst.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ? MTLPixelFormatRGBA8Unorm : dst.pixelFormat;
    __strong id<MTLTexture> root = dst; NSUInteger root_lv = lv, root_slice = slice;
    while (root.parentTexture) { root_lv += root.parentRelativeLevel; root_slice += root.parentRelativeSlice; root = root.parentTexture; }
    // Views take residency from their direct parent. Make the write view from
    // the resident root even when a sparse mip range or another view was bound.
    id<MTLTexture> view = [root newTextureViewWithPixelFormat:pf textureType:is3d ? MTLTextureType3D : MTLTextureType2D levels:NSMakeRange(root_lv, 1) slices:NSMakeRange(is3d ? 0 : root_slice, 1)];
    if (!view) MDIE("cannot create a BC decoder write view");
    int upload = encoder == g_up_ce;
    if (upload) { if (!g_up_views) g_up_views = [NSMutableArray new]; [g_up_views addObject:view]; }
    else defer_obj_unref(view);
    size_t po; id<MTLBuffer> params;
    if (upload) params = up_param_alloc(&po); else po = arena_alloc(64, &params);
    struct { uint64_t src; uint32_t row, image, w, h, depth, fmt, x, y, z; } p = {
        info->blocks.gpuAddress + bc_offset(dst, lv, slice, origin, info), (uint32_t)info->row[bc_level(dst, lv)], (uint32_t)info->image[bc_level(dst, lv)],
        (uint32_t)size.width, (uint32_t)size.height, (uint32_t)size.depth, info->format, (uint32_t)origin.x, (uint32_t)origin.y, (uint32_t)origin.z};
    memcpy((uint8_t *)params.contents + po, &p, sizeof p);
    static id<MTL4ArgumentTable> table;
    if (!upload && !table) {
        MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new]; d.maxBufferBindCount = d.maxTextureBindCount = 1;
        NSError *error = nil; table = rec_table([g_dev newArgumentTableWithDescriptor:d error:&error]);
        if (!table) MDIE("BC decoder argument table failed: %s", error.localizedDescription.UTF8String);
    }
    id<MTL4ArgumentTable> at = upload ? g_up_ct : table;
    [encoder barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:resource_vis()];
    [encoder setArgumentTable:at]; [at setAddress:params.gpuAddress + po atIndex:0]; [at setTexture:view.gpuResourceID atIndex:0];
    [encoder setComputePipelineState:bc_pipeline(is3d)];
    [encoder dispatchThreadgroups:MTLSizeMake((size.width + 31) / 32, (size.height + 31) / 32, size.depth) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [encoder barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:resource_vis()];
    if (!upload) [encoder setArgumentTable:g_ct];
}
static int bc_copy_to(id encoder, id<MTLBuffer> src, NSUInteger off, NSUInteger row, NSUInteger image, MTLSize size,
                      id<MTLTexture> dst, NSUInteger slice, NSUInteger lv, MTLOrigin origin) {
    NvBC *info = bc_info(dst); if (!info) return 0;
    NSUInteger root_lv = bc_level(dst, lv);
    NSUInteger ro = bc_offset(dst, lv, slice, origin, info), bytes = ((size.width + 3) / 4) * info->bpb, rows = (size.height + 3) / 4;
    for (NSUInteger z = 0; z < size.depth; z++) for (NSUInteger y = 0; y < rows; y++)
        [encoder copyFromBuffer:src sourceOffset:off + z * image + y * row toBuffer:info->blocks destinationOffset:ro + z * info->image[root_lv] + y * info->row[root_lv] size:bytes];
    bc_decode(encoder, dst, slice, lv, origin, size); return 1;
}
static int bc_copy_from(id encoder, id<MTLTexture> src, NSUInteger slice, NSUInteger lv, MTLOrigin origin, MTLSize size,
                        id<MTLBuffer> dst, NSUInteger off, NSUInteger row, NSUInteger image) {
    NvBC *info = bc_info(src); if (!info) return 0;
    NSUInteger root_lv = bc_level(src, lv);
    NSUInteger ro = bc_offset(src, lv, slice, origin, info), bytes = ((size.width + 3) / 4) * info->bpb, rows = (size.height + 3) / 4;
    for (NSUInteger z = 0; z < size.depth; z++) for (NSUInteger y = 0; y < rows; y++)
        [encoder copyFromBuffer:info->blocks sourceOffset:ro + z * info->image[root_lv] + y * info->row[root_lv] toBuffer:dst destinationOffset:off + z * image + y * row size:bytes];
    return 1;
}
static int bc_copy_texture(id encoder, id<MTLTexture> src, NSUInteger sl, NSUInteger lv, MTLOrigin so, MTLSize size,
                           id<MTLTexture> dst, NSUInteger dl, NSUInteger dv, MTLOrigin to) {
    NvBC *a = bc_info(src), *b = bc_info(dst); if (!a || !b) return 0;
    NSUInteger al = bc_level(src, lv), bl = bc_level(dst, dv);
    if (a->bpb != b->bpb) MDIE("BC texture copy changes the block size");
    NSUInteger ao = bc_offset(src, lv, sl, so, a), bo = bc_offset(dst, dv, dl, to, b), bytes = ((size.width + 3) / 4) * a->bpb, rows = (size.height + 3) / 4;
    for (NSUInteger z = 0; z < size.depth; z++) for (NSUInteger y = 0; y < rows; y++)
        [encoder copyFromBuffer:a->blocks sourceOffset:ao + z * a->image[al] + y * a->row[al] toBuffer:b->blocks destinationOffset:bo + z * b->image[bl] + y * b->row[bl] size:bytes];
    bc_decode(encoder, dst, dl, dv, to, size); return 1;
}
