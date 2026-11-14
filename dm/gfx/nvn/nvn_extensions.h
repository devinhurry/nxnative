// Optional compile-time graphics extension; native builds are self-contained.
#pragma once
#ifdef NX_GFX_EXTENSION
#include NX_GFX_EXTENSION
#endif
#ifndef NX_GFX_PRESENT_FLOATS
#define NX_GFX_PRESENT_FLOATS 8
#endif
#ifndef NX_GFX_PRESENT_TEXTURES
#define NX_GFX_PRESENT_TEXTURES 1
#endif
#ifndef NX_GFX_PRESENT_LEGACY
#define NX_GFX_PRESENT_LEGACY(cb,en,src,dst,uv) ((void)0)
#endif
#ifndef NX_GFX_PRESENT_METAL4
#define NX_GFX_PRESENT_METAL4(args,en,src,dst,uv,buffer) ((void)0)
#endif
#ifndef NX_GFX_CAPTURE_BEGIN
#define NX_GFX_CAPTURE_BEGIN() ((void)0)
#define NX_GFX_CAPTURE_END() ((void)0)
#endif
#ifndef NX_GFX_PRESENT_VIEWPORT
#define NX_GFX_PRESENT_VIEWPORT(pw,ph,dw,dh) ((void)0)
#endif

#ifndef NX_GFX_DRAW
#define NX_GFX_DRAW(dw,di) draw_(dw,di)
#endif
#ifndef NX_GFX_BEGIN_DRAW
#define NX_GFX_BEGIN_DRAW() ((void)0)
#endif
#ifndef NX_GFX_PREPARE_DRAW
#define NX_GFX_PREPARE_DRAW(pr,dw,di) ((void)0)
#endif
#ifndef NX_GFX_UNIFORM_SLOT
#define NX_GFX_UNIFORM_SLOT(stage,reg,size,gpu,use) ((void)0)
#endif
#ifndef NX_GFX_TRANSFORM_TEXTURE
#define NX_GFX_TRANSFORM_TEXTURE(stage,reg,texture,rid) ((void)0)
#endif

#ifndef NX_GFX_RECORD_DRAW
#define NX_GFX_RECORD_DRAW(record) ((void)0)
#endif
#ifndef NX_GFX_DRAW_TAGGED
#define NX_GFX_DRAW_TAGGED(record) 0
#endif
