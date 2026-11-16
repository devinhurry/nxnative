// Real pool preparation at either side of the configurable chunk threshold.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void){return NULL;}
module_t *module_of(const void *p){(void)p;return NULL;}
module_t *g_mod;int g_nmod;
void svc_thread_dump(void){}
uint64_t now_ns(void){return bp_now();}
int main(int argc,char **argv){@autoreleasepool{
    if(argc<2)return 2;mtl_init();
    uint64_t want=strtoull(argv[1],NULL,10)<<20,min=pool_chunk_min();int disabled=argc>2;
    if(min!=want){fprintf(stderr,"threshold %llu, expected %llu\n",(unsigned long long)min,(unsigned long long)want);return 1;}
    for(int delta=-1;delta<=1;delta++){
        size_t size=(size_t)(min+(int64_t)delta*(1<<20));void *mem=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);if(mem==MAP_FAILED)return 3;
        int ok;
        @autoreleasepool{pool_new p;pool_new_prep(&p,mem,size);ok=!!p.buf==(disabled||delta<0);p.buf=nil;}
        munmap(mem,size);
        if(!ok){fprintf(stderr,"wrong pool preparation at threshold %+d MB\n",delta);return 1;}
    }
    // Exercise GPU mappings in the range affected by the new default.
    const size_t size=384u<<20;uint8_t *mem=mmap(NULL,size,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);if(mem==MAP_FAILED)return 4;
    mtl_pool_add(mem,size);int chunked=!disabled && size>=min;
    if((big_of((uintptr_t)mem)>=0)!=chunked)return 5;
    id<MTLCommandBuffer>cb=[g_q commandBuffer];id<MTLBlitCommandEncoder>bl=[cb blitCommandEncoder];
    const size_t offsets[]={0,192u<<20,size-4096};
    for(unsigned i=0;i<3;i++){
        void *raw;uint64_t off,gpu;
        if(!mtl_gpu_addr((uintptr_t)(mem+offsets[i]),4096,&raw,&off,&gpu))return 6;
        id<MTLBuffer>b=(__bridge id<MTLBuffer>)raw;
        if((chunked && b.length>=size)||(!chunked && b.length<size))return 7;
        [bl fillBuffer:b range:NSMakeRange(off,4096) value:(uint8_t)(0x40+i)];
    }
    [bl endEncoding];res_commit();[cb useResidencySet:g_res];[cb commit];[cb waitUntilCompleted];if(cb.error)return 8;
    for(unsigned i=0;i<3;i++)for(unsigned j=0;j<4096;j++)if(mem[offsets[i]+j]!=(uint8_t)(0x40+i))return 9;
    mtl_pool_del(mem);res_commit();   // mapping remains alive until the process exits and deferred buffers retire
    printf("pool threshold %llu MB: below/at/above and 384 MB GPU access%s passed\n",(unsigned long long)(min>>20),disabled?", chunking disabled":"");return 0;
}}
