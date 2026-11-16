// Reuse a shader's last argument block by the bindings it consumes. No shader ABI change.
enum { ARGS_KEY_MAX=NVN_REFL_MAXB+DMSH_CBSIZE_SLOTS+12 };
static int g_args_key=-1,g_args_check=-1;
static int args_key_on(void) {
    if(g_args_key<0) {
        const char *e=getenv("DM_NVN_ARGS_KEY");g_args_key=!(e && !strcmp(e,"0"));
        MLOG("argument blocks reused by content: %s (DM_NVN_ARGS_KEY)",g_args_key?"on":"off");
    }
    return g_args_key;
}
static int args_key_check_on(void) {
    if(g_args_check<0) {const char *e=getenv("DM_NVN_ARGS_CHECK");g_args_check=e && atoi(e)>0;}
    return g_args_check;
}
static int args_keyable(NvShader *sh) {
    if(sh->ab_keyable)return sh->ab_keyable==1;
    int ok=1;
    for(int i=0;i<sh->rf.nb && ok;i++) {
        const nvn_rbind *b=&sh->rf.b[i];
        if(b->n>1 || b->aid>=NVN_REFL_MAXARG){ok=0;break;}
        switch(b->kind) {
        case NVN_RB_CBUF: case NVN_RB_SAMP: case NVN_RB_SAMPT: case NVN_RB_SAMPI:
        case NVN_RB_SUPPORT: case NVN_RB_C1: case NVN_RB_BORDER: case NVN_RB_CBSIZE: break;
        case NVN_RB_TEX: ok=b->reg<NTEX && !b->f1d && b->dtt!=MTLTextureTypeTextureBuffer;break;
        case NVN_RB_DRV0: case NVN_RB_DRV2: ok=!sh->rf.drv_read[b->kind==NVN_RB_DRV2?2:0];break;
        // Writes, uniform-data handles, pool tables and new kinds keep full encoding.
        default: ok=0;break;
        }
    }
    sh->ab_keyable=ok?1:2;return ok;
}
static unsigned args_key_make(NvShader *sh,int stage,int vertex,uint64_t key[ARGS_KEY_MAX]) {
    if(!args_key_on() || stage<0 || stage>1 || passdump() || g_res_check_on ||
       !NX_GFX_ARGS_KEY_ALLOWED(stage) || !args_keyable(sh) ||
       sh->arg_len>NVN_REFL_MAXARG*sizeof(uint64_t) ||
       (stage==1 && g_fb_n && g_fb_seq==g_draw_seq))return 0;
    unsigned n=0;
    #define AK_ADD(v) do {if(n==ARGS_KEY_MAX)return 0;key[n++]=(uint64_t)(v);} while(0)
    AK_ADD(stage);AK_ADD(vertex);AK_ADD(g_arena_life);AK_ADD(g_reg_gen);
    AK_ADD(g_ser_gen);AK_ADD(nvn_dirty_now());AK_ADD(g_pool_gen);AK_ADD(g_psnap_gen);
    for(int i=0;i<sh->rf.nb;i++) {
        const nvn_rbind *b=&sh->rf.b[i];
        switch(b->kind) {
        case NVN_RB_TEX: AK_ADD(tex_slot_h(S.tex[stage],S.img[stage],b->reg)&0xfffff);break;
        case NVN_RB_SAMP: case NVN_RB_SAMPT: case NVN_RB_SAMPI: {
            int sid=bind_sid(stage,b);
            if(b->bw && sid>0 && sid<g_nsreg && g_sreg_ok[sid]) {
                const samp_par *p=&g_sreg[sid];int bn,bw;float k[4];const uint8_t wrap[3]={p->ws,p->wt,p->wr};
                if(nvn_border(p->border,wrap,p->reduction,&bn,&bw,k))return 0;
            }
            AK_ADD(sid);break;
        }
        case NVN_RB_CBSIZE:
            // The cached size table stays valid only while all bound sizes do.
            // CBUF addresses are refreshed through the production cbuf_slot.
            for(int r=0;r<DMSH_CBSIZE_SLOTS;r++)AK_ADD(cbsize_value(stage,r));
            break;
        default: break;   // a dynamic CBUF, or a shader/process constant
        }
    }
    #undef AK_ADD
    return n;
}
static void args_key_save(NvShader *sh,const uint64_t *key,unsigned n,uint8_t *cpu) {
    sh->ab_nkey=0;sh->ab_cpu=cpu;
    if(!n)return;
    if(sh->ab_key_cap<n) {
        uint64_t *p=realloc(sh->ab_key,n*sizeof *p);if(!p)return;
        sh->ab_key=p;sh->ab_key_cap=n;
    }
    memcpy(sh->ab_key,key,n*sizeof *key);sh->ab_nkey=n;
}
static void args_key_bind(id<MTLCommandEncoder> en,NvShader *sh,int stage,int vertex,const uint64_t *slots,size_t bytes) {
    if(memcmp(sh->ab_cpu,slots,bytes)) {
        id<MTLBuffer> ab;size_t off=arena_alloc(bytes,&ab);uint8_t *cpu=g_cur_arena->cpu+off;
        memcpy(cpu,slots,bytes);sh->ab_buf=ab;sh->ab_gpu=g_cur_arena->gpu+off;sh->ab_off=off;sh->ab_cpu=cpu;
        g_stat_args_patch++;g_stat_args_key_patch++;
    } else {g_stat_args_reuse++;g_stat_args_key_reuse++;}
    bind_args(en,stage,vertex,sh->ab_buf,sh->ab_gpu,sh->ab_off,sh->rf.abi);
    sh->ab_pass=g_pass.serial;sh->ab_binst=g_draw_binst;sh->ab_pgen=g_psnap_gen;
    g_args_dirty[stage]=g_args_ubo[stage]=0;
}
static void args_key_report(void) {
    static uint64_t frame,previous[3];uint64_t f=atomic_load(&g_cur_frame);
    if(f<frame+300)return;frame=f;
    uint64_t now[3]={g_stat_args_key_reuse,g_stat_args_key_patch,g_stat_args_key_check};
    if(now[0] || now[1] || now[2])MLOG("argument-block content keys: reused %llu, patched %llu, checked %llu (since last report)",
        (unsigned long long)(now[0]-previous[0]),(unsigned long long)(now[1]-previous[1]),(unsigned long long)(now[2]-previous[2]));
    memcpy(previous,now,sizeof now);
}
