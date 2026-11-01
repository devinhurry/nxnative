// Compare the fallback with native hardware decoding, then exercise GPU-written
// blocks, partial copies, mip/array views and BC4 render targets (including 3D).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label,c) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s (line %d)\n",label,__LINE__); } } while (0)
static void finish(void) { CHECK("submission completed",mtl_wait(mtl_sub_commit(),5000000000ull)); CHECK("GPU has no error",!mtl_last_commit_error()); }
static id<MTLBuffer> pixels(id<MTLTexture> t, unsigned lv) {
    static id<MTLLibrary> lib; static id<MTLComputePipelineState> ps[2]; NSError *error=nil;
    int is3=t.textureType==MTLTextureType3D;
    if (!lib) lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void a(texture2d_array<float> t[[texture(0)]],device float4 *o[[buffer(0)]],constant uint4 &p[[buffer(1)]],uint3 g[[thread_position_in_grid]]){if(g.x<p.x&&g.y<p.y&&g.z<p.w)o[(g.z*p.y+g.y)*p.x+g.x]=t.read(g.xy,g.z,p.z);}\nkernel void b(texture3d<float> t[[texture(0)]],device float4 *o[[buffer(0)]],constant uint4 &p[[buffer(1)]],uint3 g[[thread_position_in_grid]]){if(g.x<p.x&&g.y<p.y&&g.z<p.w)o[(g.z*p.y+g.y)*p.x+g.x]=t.read(g,p.z);}" options:nil error:&error];
    if (!ps[is3]) ps[is3]=[g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:is3?@"b":@"a"] error:&error];
    CHECK("pixel probe compiled",ps[is3]!=nil);
    uint32_t p[4]={(uint32_t)MAX(t.width>>lv,1u),(uint32_t)MAX(t.height>>lv,1u),lv,(uint32_t)(is3?MAX(t.depth>>lv,1u):t.arrayLength)};
    id<MTLBuffer> out=[g_dev newBufferWithLength:(size_t)p[0]*p[1]*p[3]*16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=q_cb(); id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
    [e setComputePipelineState:ps[is3]];[e setTexture:t atIndex:0];[e setBuffer:out offset:0 atIndex:0];[e setBytes:p length:sizeof p atIndex:1];
    [e dispatchThreads:MTLSizeMake(p[0],p[1],p[3]) threadsPerThreadgroup:MTLSizeMake(4,4,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted];
    CHECK("pixel probe completed",cb.status==MTLCommandBufferStatusCompleted); return out;
}
static void compare(id<MTLTexture> a,id<MTLTexture> b,const char *label) {
    for(unsigned lv=0;lv<a.mipmapLevelCount;lv++){
        id<MTLBuffer> ab=pixels(a,lv),bb=pixels(b,lv); const float *x=ab.contents,*y=bb.contents;
        // BC1-5 interpolation differs slightly across hardware; decoded R8/RG8
        // also quantize to 8 bits (signed channels have 127 positive steps).
        float tolerance=b.pixelFormat>=130&&b.pixelFormat<=143?.018f:.0041f;
        int bad=0;for(size_t i=0;i<ab.length/4;i++){
            if(isnan(x[i])&&isnan(y[i]))continue;if(x[i]==y[i])continue;
            if(fabsf(x[i]-y[i])<=tolerance+.002f*fabsf(y[i]))continue;
            if(bad++<3)fprintf(stderr,"%s mip %u value %zu: %.8g vs %.8g\n",label,lv,i,x[i],y[i]);
        } CHECK(label,!bad);
    }
}
static void formats(void) {
    uint32_t seed=0x5ac13719;
    for(int f=0x41;f<=0x50;f++){@autoreleasepool{
        void *mem=NULL;CHECK("aligned pool",!posix_memalign(&mem,getpagesize(),65536));memset(mem,0,65536);
        pool_t pool={.mem=mem,.size=65536,.flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
        tex_t t={.magic=MAGIC('T','E','X',0),.serial=9800+f,.pool=&pool,.mem=mem,.has_layout=1};
        t.d=(nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D_ARRAY,.format=f,.width=12,.height=8,.depth=2,.levels=4,.samples=1};nvn_tex_layout(&t.d,&t.L);mtl_pool_add(mem,65536);
        uint32_t pf;nvn_fmt_to_mtl(f,&pf,NULL);MTLTextureDescriptor *d=[MTLTextureDescriptor new];d.textureType=MTLTextureType2DArray;d.pixelFormat=pf;d.width=12;d.height=8;d.arrayLength=2;d.mipmapLevelCount=4;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead;
        id<MTLTexture> native=[g_dev newTextureWithDescriptor:d];CHECK("native reference created",native!=nil);
        id<MTLCommandBuffer> cb=q_cb();id<MTLBlitCommandEncoder> e=[cb blitCommandEncoder];NSMutableArray *keep=[NSMutableArray new];
        for(unsigned lv=0;lv<4;lv++)for(unsigned sl=0;sl<2;sl++){
            int bw,bh,bpb=nvn_fmt_bpb(f,&bw,&bh);unsigned w=MAX(12u>>lv,1u),h=MAX(8u>>lv,1u);size_t row=((w+3)/4)*bpb,n=row*((h+3)/4);
            id<MTLBuffer> data=[g_dev newBufferWithLength:n options:MTLResourceStorageModeShared];uint8_t *p=data.contents;
            for(size_t i=0;i<n;i++){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;p[i]=(uint8_t)seed;}[keep addObject:data];
            CHECK("fixture swizzled",!nvn_swizzle(&t.d,lv,sl,data.contents,row,mem));
            [e copyFromBuffer:data sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(w,h,1) toTexture:native destinationSlice:sl destinationLevel:lv destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [e endEncoding];[cb commit];[cb waitUntilCompleted];CHECK("native reference uploaded",cb.status==MTLCommandBufferStatusCompleted);
        mtl_tex_init(&t);mtl_sub_begin();id<MTLTexture> actual=tex_mtl(&t);CHECK("texture uploaded",actual!=nil);CHECK("native capability selects native storage",!!bc_block(actual)==!!g_no_bc);finish();
        char label[64];snprintf(label,sizeof label,"BC format %#x agrees with native",f);compare(actual,native,label);
        if(g_no_bc){
            id<MTLTexture> view=[actual newTextureViewWithPixelFormat:actual.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(1,2) slices:NSMakeRange(1,1)];
            int bw,bh,bpb=nvn_fmt_bpb(f,&bw,&bh);size_t row=2*bpb;uint8_t expected[32];
            CHECK("view fixture deswizzles",!nvn_deswizzle(&t.d,1,1,mem,expected,row));
            id<MTLBuffer> raw=[g_dev newBufferWithLength:row options:MTLResourceStorageModeShared];res_add(raw);
            mtl_sub_begin();enc_b_copy_texture_buffer(blit(),view,0,0,MTLOriginMake(0,0,0),MTLSizeMake(6,4,1),raw,0,row,row);finish();
            CHECK("a mip/layer view reads its original compressed bytes",!memcmp(expected,raw.contents,row));
            // Mode 0/1 is valid in both BC6H and BC7; all-zero BC7 is reserved
            // and hardware is not required to match a software decoder there.
            id<MTLBuffer> zero=[g_dev newBufferWithLength:row options:MTLResourceStorageModeShared];memset(zero.contents,0,row);for(size_t i=0;i<row;i+=bpb)((uint8_t *)zero.contents)[i]=1;res_add(zero);
            mtl_sub_begin();enc_b_copy_buffer_texture(blit(),zero,0,row,row,MTLSizeMake(6,4,1),view,0,0,MTLOriginMake(0,0,0));finish();
            id<MTLCommandBuffer> update=q_cb();id<MTLBlitCommandEncoder> ue=[update blitCommandEncoder];
            [ue copyFromBuffer:zero sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:row sourceSize:MTLSizeMake(6,4,1) toTexture:native destinationSlice:1 destinationLevel:1 destinationOrigin:MTLOriginMake(0,0,0)];[ue endEncoding];[update commit];[update waitUntilCompleted];
            snprintf(label,sizeof label,"BC %#x mip/layer view writes selected subresource",f);compare(actual,native,label);res_remove(raw);res_remove(zero);
        }
        mtl_tex_release(&t);mtl_pool_del(mem);mtl_drain();free(mem);
    }}
}
static tex_t texture(unsigned target,unsigned depth,uint64_t serial) {
    tex_t t={.magic=MAGIC('T','E','X',0),.serial=serial,.off=serial*65536};
    t.d=(nvn_texdesc){.target=target,.format=0x49,.width=12,.height=8,.depth=depth,.levels=1,.samples=1};
    nvn_tex_layout(&t.d,&t.L);mtl_tex_init(&t);return t;
}
static void copies(void) {
    void *mem=NULL;CHECK("copy source pool",!posix_memalign(&mem,getpagesize(),65536));memset(mem,0,65536);mtl_pool_add(mem,65536);
    tex_t a=texture(NVN_TEXTURE_TARGET_2D_ARRAY,2,9991),b=texture(NVN_TEXTURE_TARGET_2D_ARRAY,2,9992);
    mtl_sub_begin();id<MTLTexture> at=tex_mtl(&a),bt=tex_mtl(&b);
    void *source;uint64_t source_off;CHECK("copy pool resolves",mtl_addr((uint64_t)mem,96,&source,&source_off));
    for(unsigned sl=0;sl<2;sl++){
        enc_b_copy_buffer_texture(blit(),(__bridge id<MTLBuffer>)source,source_off,24,48,MTLSizeMake(12,8,1),at,sl,0,MTLOriginMake(0,0,0));
        enc_b_copy_buffer_texture(blit(),(__bridge id<MTLBuffer>)source,source_off,24,48,MTLSizeMake(12,8,1),bt,sl,0,MTLOriginMake(0,0,0));
    }
    mtl_sub_fill((uint64_t)mem,16,0xffffffffu);
    p_copy_b2t put={.tex=&a,.src=(uint64_t)mem,.r={4,0,1,4,4,1}};copy_b2t(&put);
    p_copy_t2t cp={.src=&a,.dst=&b,.sr={4,0,1,4,4,1},.dr={0,4,0,4,4,1}};copy_t2t(&cp);
    p_copy_b2t get={.tex=&b,.src=(uint64_t)mem+64,.r={0,4,0,4,4,1}};copy_t2b(&get);finish();
    CHECK("GPU-written compressed bytes survive copies",!memcmp((uint8_t *)mem+64,mem,8));
    id<MTLBuffer> ar=pixels(at,0),br=pixels(bt,0);const float *ap=ar.contents,*bp=br.contents;
    int good=1,bad=0;for(int sl=0;sl<2;sl++)for(int y=0;y<8;y++)for(int x=0;x<12;x++){
        int ac=fabsf(ap[((sl*8+y)*12+x)*4]-(sl==1&&x>=4&&x<8&&y<4))<.001f;
        int bc=fabsf(bp[((sl*8+y)*12+x)*4]-(sl==0&&x<4&&y>=4))<.001f;
        if((!ac||!bc)&&bad++<3)fprintf(stderr,"copy (%d,%d,%d): %g %g\n",x,y,sl,ap[((sl*8+y)*12+x)*4],bp[((sl*8+y)*12+x)*4]);good&=ac&&bc;
    }CHECK("partial copies decode only their destination regions",good);
    mtl_tex_release(&a);mtl_tex_release(&b);mtl_pool_del(mem);mtl_drain();free(mem);
}
static void render_blocks(unsigned target,unsigned depth,uint64_t serial) {
    tex_t t=texture(target,depth,serial);view_t v={.set_format=1,.format=NVN_FORMAT_RGBA16UI};
    mtl_sub_begin();id<MTLTexture> image=tex_mtl(&t);
    id<MTLBuffer> zero=zero_buf(48);for(unsigned z=0;z<depth;z++)enc_b_copy_buffer_texture(blit(),zero,0,24,48,MTLSizeMake(12,8,1),image,target==NVN_TEXTURE_TARGET_3D?0:z,0,MTLOriginMake(0,0,target==NVN_TEXTURE_TARGET_3D?z:0));
    for(int pass=0;pass<2;pass++){
        MTL4RenderPassDescriptor *rp=[MTL4RenderPassDescriptor new];MTLRenderPassColorAttachmentDescriptor *a=rp.colorAttachments[0];a.texture=image;
        if(target==NVN_TEXTURE_TARGET_3D)a.depthPlane=1;else a.slice=1;
        CHECK("BC raw block target gets a shadow",bcrt_attach(a,image,&v,1));
        if(g_blit){enc_b_end(g_blit);g_blit=nil;}
        a.loadAction=pass?MTLLoadActionLoad:MTLLoadActionClear;a.storeAction=MTLStoreActionStore;a.clearColor=MTLClearColorMake(255,0,0,0);
        id<MTL4RenderCommandEncoder> e=[g_cb renderCommandEncoderWithDescriptor:rp];[e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:resource_vis()];m4_end(e);bcrt_flush();
    }finish();
    id<MTLBuffer> out=pixels(image,0);const float *p=out.contents;int good=1;
    for(unsigned z=0;z<depth;z++)for(int i=0;i<12*8;i++)good&=fabsf(p[(z*12*8+i)*4]-(z==1))<.001f;
    CHECK("rendered BC4 blocks decode and survive a loaded pass",good);mtl_tex_release(&t);mtl_drain();
}
static void linear_blocks(void) {
    if(!g_no_bc)return;
    void *mem=NULL;CHECK("linear pool",!posix_memalign(&mem,getpagesize(),65536));memset(mem,0,65536);mtl_pool_add(mem,65536);
    pool_t pool={.mem=mem,.size=65536,.flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    tex_t t=texture(NVN_TEXTURE_TARGET_2D,1,9995);t.pool=&pool;t.mem=mem;t.d.flags=NVN_TEXTURE_FLAGS_LINEAR;t.d.stride=64;nvn_tex_layout(&t.d,&t.L);
    mtl_sub_begin();id<MTLTexture> image=tex_mtl(&t);CHECK("linear BC uses decoded storage",image&&bc_block(image));finish();
    id<MTLTexture> view=[image newTextureViewWithPixelFormat:image.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
    id<MTLBuffer> first=pixels(view,0);CHECK("initial linear block is zero",((float *)first.contents)[0]==0);
    dm_guest_write_prepare(mem,t.L.size);memset(mem,255,t.L.size);
    mtl_sub_begin();image=tex_mtl(&t);finish();view=[image newTextureViewWithPixelFormat:image.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
    id<MTLBuffer> second=pixels(view,0);CHECK("CPU writes to linear BC are re-uploaded",((float *)second.contents)[0]==1);
    mtl_sub_begin();p_copy_b2t put={.tex=&t,.src=(uint64_t)mem+4096,.r={4,0,0,4,4,1}};copy_b2t(&put);finish();
    uint8_t block[8];NVNcopyRegion r={4,0,0,4,4,1};mtl_read_texels(&t,0,0,&r,block,8,8);
    int same=1;for(unsigned i=0;i<8;i++)same&=!block[i];CHECK("GPU writes to linear BC reach CPU ReadTexels",same);
    CHECK("linear GPU mirror keeps neighboring blocks",((uint8_t *)mem)[0]==255&&((uint8_t *)mem)[8]==0);
    mtl_tex_release(&t);mtl_pool_del(mem);mtl_drain();free(mem);
}
int main(void){@autoreleasepool{mtl_init();if(!g_dev.supportsBCTextureCompression){puts("native BC differential reference unavailable");return 77;}
    formats();copies();render_blocks(NVN_TEXTURE_TARGET_2D_ARRAY,2,9993);render_blocks(NVN_TEXTURE_TARGET_3D,3,9994);linear_blocks();
    printf("t_bc (%s): %d checks, %d failed\n",g_no_bc?"fallback":"native",checks,failed);return failed!=0;
}}
