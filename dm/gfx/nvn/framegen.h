// Experimental MetalFX frame generation. Camera/depth/scene inputs are submitted once per real game frame.
#pragma once
#include "framegen_policy.h"
#ifdef __OBJC__
#import <Metal/Metal.h>
int dm_fg_enabled(void);
int dm_fg_available(id<MTLDevice> device);
void dm_fg_reset(void);
// Front-end threads request a history reset; the submit thread applies it.
void dm_fg_request_reset(void);
id<MTLTexture> dm_fg_scene_target(id<MTLDevice> device,NSUInteger width,NSUInteger height,MTLPixelFormat format);
// Borrow the completed canvas on the game's queue; encode retains it through GPU completion.
void dm_fg_note_ui(id<MTLTexture> canvas);
id<MTLResidencySet> dm_fg_residency(void);
void dm_fg_note_scene(void);
void dm_fg_note_depth(id<MTLTexture> depth);
void dm_fg_note_camera(const float *camera,int count);
int dm_fg_frame_prepare(double frame_seconds,int interpolate);
int dm_fg_has_history(void);   // submit thread only: this real picture can precede an interpolated midpoint
NSArray *dm_fg_frame_encode(id<MTL4CommandBuffer> cb,int slot,id<MTL4CounterHeap> heap,NSUInteger stamp);
id<MTLTexture> dm_fg_output(int slot);
void dm_fg_generation_done(int slot);
void dm_fg_display_retain(int slot);
void dm_fg_display_done(int slot);
int dm_fg_slot_refs(int slot);
void dm_fg_wait_idle(void);
void dm_fg_gpu_time(double seconds);
void dm_fg_stats(char *out,size_t n);
// Opt-in diagnostic JSONL. No counters or event dictionaries on the normal path.
int dm_fg_profile_on(void);
void dm_fg_profile_event(NSString *event,NSDictionary *fields);
NSDictionary *dm_fg_profile_frame(void);
#endif
