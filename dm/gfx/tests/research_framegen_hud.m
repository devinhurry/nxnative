#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <string.h>
static int once(id<MTLDevice> dev, id<MTLLibrary> lib, int opaque) {
    NSError *error=nil; MTLFunctionConstantValues *cv=[MTLFunctionConstantValues new];
    for (int i=0;i<8;i++) { bool f=false; [cv setConstantValue:&f type:MTLDataTypeBool atIndex:32+i]; }
    for (int i=0;i<8;i++) { bool f=i==0 || i==7; [cv setConstantValue:&f type:MTLDataTypeBool atIndex:64+i]; }
    id<MTLFunction> fn=[lib newFunctionWithName:@"main0_f" constantValues:cv error:&error];
    if(!fn) { fprintf(stderr,"function: %s\n",error.description.UTF8String); return 1; }
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new]; pd.vertexFunction=[lib newFunctionWithName:@"vert"]; pd.fragmentFunction=fn;
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm; pd.colorAttachments[7].pixelFormat=MTLPixelFormatRGBA8Unorm; pd.alphaToOneEnabled=opaque;
    id<MTLRenderPipelineState> pipe=[dev newRenderPipelineStateWithDescriptor:pd error:&error];
    if(!pipe) { fprintf(stderr,"pipeline: %s\n",error.description.UTF8String); return 1; }
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared;
    id<MTLTexture> hud=[dev newTextureWithDescriptor:td], scene=[dev newTextureWithDescriptor:td];
    id<MTLBuffer> count=[dev newBufferWithLength:4 options:MTLResourceStorageModeShared]; *(uint32_t *)count.contents=0;
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=hud; rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.colorAttachments[7].texture=scene; rp.colorAttachments[7].loadAction=MTLLoadActionClear; rp.colorAttachments[7].storeAction=MTLStoreActionStore;
    id<MTLCommandBuffer> cb=[[dev newCommandQueue] commandBuffer]; id<MTLRenderCommandEncoder> enc=[cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:pipe]; [enc setFragmentBuffer:count offset:0 atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if(cb.error) { fprintf(stderr,"GPU: %s\n",cb.error.description.UTF8String); return 1; }
    uint8_t h[4]={0},s[4]={0}; [hud getBytes:h bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0]; [scene getBytes:s bytesPerRow:4 fromRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0];
    unsigned n=*(uint32_t*)count.contents; printf("alphaToOne=%d HUD=%u,%u,%u,%u scene=%u,%u,%u,%u fragment-count=%u\n",opaque,h[0],h[1],h[2],h[3],s[0],s[1],s[2],s[3],n);
    const uint8_t rgb[3]={255,128,64};
    return !(memcmp(h,rgb,3)==0 && memcmp(s,rgb,3)==0 && h[3]==(opaque?255:64) && s[3]==64 && n==65536);
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 2) { fprintf(stderr, "usage: research_framegen_hud <shader source>\n"); return 2; }
    NSError *error=nil; id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); if(!dev) return 2;
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    id<MTLLibrary> lib=[dev newLibraryWithSource:source options:nil error:&error]; if(!lib) { fprintf(stderr,"library: %s\n",error.description.UTF8String); return 2; }
    printf("GPU: %s\n",dev.name.UTF8String); int failures=once(dev,lib,0)+once(dev,lib,1); printf("failures=%d\n",failures); return failures?1:0;
} }
