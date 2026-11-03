# BOTW performance

## Frame rate

#### The frame step (current)

- **60 fps at normal speed (30 on the Switch).** The game steps its time by the frame interval its framework picks (`ksys::VFR`: interval / 2 of a 30 fps tick). With the profile's `fps_target` (60) the host picks it instead, in whole vsyncs (`FRAME_STEP` in `patches.py`, `hle_nvn.c` `fstep_tick`, `nvn_fstep.h`, the same frame step as Tears of the Kingdom's): a stub at the framework's `setWaitVsyncInterval` hands the game the host's step once a frame, and the host keeps each frame on screen that many vsyncs.
- It holds 1 (60 fps). Three late frames in a row (the frame or its GPU work more than 1.7 ms over) step up to the cost, 2 (30 fps) as a rule: no 40 fps on 120 Hz screens. 30 frames that would fit the shorter hold try it again, and each failed try doubles the wait before the next (1 → 8 s). After a hitch, a cost at 30 like the one that held 60 tries it too (probes, below).
- Real time lost to a late frame or a hitch is paid back one vsync per frame (at most 15; the rest of a long load is dropped), so game time = real time. The log line `frame step: game time 30.00 s in 30.00 s (1.000 of real time)` checks it every 1,800 presents, with the frames held 1 / 2 / 3 vsyncs, late frames, paid-back vsyncs and hold changes.
- **Resolved: movies at twice their speed at 60 fps (issue #636).** The game's movie player takes one picture per frame (34 s of its 30 fps movie in about 1,250 presents). While the host's movie decoder hands out pictures, the frame step holds 30: [Movies hold 30 fps under the frame step](../../../../docs/reference/frame-rate.md#movies-hold-30-fps-under-the-frame-step).
- Scenes that fix the game's step themselves (the VFR's override: 2 at `main+0xc3b588` / `+0xc5ebf8`, 1 at `main+0xc609d8`) keep it, and the host holds frames that long (log line `the game fixes its own step`; not reached on the Mac yet).
- The stubs: `setWaitVsyncInterval` (`main+0x11269b8`, called once a frame at `main+0x11267c0`; the framework keeps the interval at fw+0x244, getter vtable +0x138, read by both callers of `VFR::updateInterval` and directly in 43 places, and passes it to `nvnWindowSetPresentInterval`) takes the host's step unless the VFR override (+0x29 flag, +0x2c interval) is set. `ksys::VFR::updateInterval` (`main+0x151d3d0`, x0 = the VFR at `[main+0x1e93890]`, called from `GameScene::calc` and the per-frame delegate `main+0x1280f80`) takes the framework's interval in the next frame (ratio = step / 2, base interval 2, and the int interval 16 pieces of logic read); its stub publishes the override at state +0x24 so the host holds frames that long. The step is not written into the VFR call itself, because the game presents on its own thread and the step can change between the two VFR calls of a frame.
- Mac (M4 Pro), from the title into the save's scene: 1.000 of real time at 60; with 12 ms added to every frame (`DM_TEST_PRESENT_LAG=1,12`) it drops to 30 and stays at 1.000. `DM_FPS_TARGET=30` holds 30 (saves power, also from `Documents/env.txt`); `0` runs the game's own interval controller.
- **Frame-step probes (iPhone).** The GPU clock follows the hold: on an iPhone the game went from 14.4 to about 25 ms of GPU time a frame at 30 fps with the same 4,900 draws, its CPU still on the performance cores, and never tried 60 again; a GPU time at the longer hold of at least 1.3 times its time at 60 that alone does not fit 60 (`nvn_fstep_gpu_slowed`) now allows probes. Stepped up by pipeline compiles after a cutscene, it took 12.8–15.2 ms of GPU time a frame at 30 fps (p50) where 60 had held for minutes, and stayed at 30 for 36 and 46 s until the player switched out and back (the same 4,900 draws took 5.8 ms right after a trip to the background and 13.5 ms half a minute later); a step up after 8 s or more at 60 now keeps that run's cost, and a cost at the longer hold of at most 1.1 times it allows a probe (`nvn_fstep_same`). Log lines: `frame step: hold 2 → 1 … (probe, …)`, `the probe held / failed`, `hold 1 held at 0.86`. Details: [development.md, Power](../../../../docs/development.md#power).
- **Screens whose rate is not a multiple of 60 (from PR #27).** A cheap 50 ms frame shows 54.5 ms at 165 Hz; counted as late it kept the game at 20 fps for good, so the frame step lets a frame on time show one refresh longer than its hold (`shown_slack`, `nvn_fstep.h`).
- **Resolved: menu repeat twice as fast at 60 fps (2026-10-26).** `sead::ControllerBase::updateDerivativeParams_` (`main+0xeb0ef0`) adds a constant 1.0 (`main+0xeb0f78`..`88`) to each held button's count and repeats when `fmod(count - delay, pulse)` falls below that step, so delays and pulses were counted in frames: holding Down in the System menu for 0.3 s went 5 entries at 60 and 2 at 30 (found by MacNativeGames, `866beb9`). A `FRAME_STEP` stub at `main+0xeb0f88` takes the VFR's ratio (`+0x3c`, interval / 2) instead, keeping 1.0 when there is no VFR or the ratio is not positive. Mac, 60 fps: 0.2 / 0.3 / 0.4 s now move 1 / 2 / 3 entries, as the game does at 30. The pause menu's fast-repeat countdown (`main+0xe67d00`) already reads the VFR's delta.
- `DM_NVN_CUT` growing segments (64, 128, 256 … draws) were tried for fewer commits: the game fell from 60 to 30 fps in the same scene (GPU idle while the long last segments were encoded).

#### The game's own interval controller

Used at `DM_FPS_TARGET=0` and for the interval the framework keeps while the VFR override holds. DM_FRAME_STEP=legacy, which ran this method on its own, was removed in 79d82f7b.

- `sead::GameFrameworkNx`'s main loop (`main+0x112660c`, framework +0x267 = 1) runs a dynamic interval: from the last frame's time it computes how many vsyncs were needed (rounded up), clamps that to [2, 3] (the maximum from the interval controller +0xc, built at `main+0x1126c04`), steps up after three overrunning frames and down one level every six frames, and sets the result through `setWaitVsyncInterval` (vtable +0x130, `main+0x11269b8`). `ksys::VFR` is initialized with a constant base interval of 2 (`main+0x127e740` → `VFR::init` `main+0x151d2d0`) and every frame `VFR::updateInterval` (`main+0x151d3d0`, called at `main+0xcf9ad4` / `main+0x1281044`) takes the framework's interval, a frame ratio of interval / 2. The game's time step follows its frame interval, so the speed is right at a steady 60, 30 or 20.
- Five cuts lift its floor from 2 to 1: the candidate floor (`main+0x112670c` `fmov s0,s11` → `fmov s0,s10`, `main+0x1126710` `cmp w27,#2` → `#1`), the step-down target recorded when stepping up (`main+0x112665c` `mov w24,#3` → `#2`, `main+0x1126748` `cmp w8,#3` → `#2`) and the step-down stop (`main+0x1126794` `cmp w9,#3` → `#2`). Probes confirmed it: interval 1 with ratio 0.5, and back to 2 with ratio 1 on a long frame. The zeldaret/botw decompilation (`VFR.cpp`) gave the semantics; 1.9.0's addresses were found by the constants (`60 / interval`, the `fmov s11, #2.0` floor).
- **Resolved: slow motion when the GPU is the bottleneck (GitHub issue #9).** The controller measured a frame as framework +0x250, the main thread's CPU span from the start of `procFrame` to before its draw step (`main+0x1126cec` → `main+0x1126d20`): about 2.7 ms in the shrine (probe at `main+0x11266a4`, `@x19+0x250`; "about 3 ms" in development.md). Only while the object at `[main+0x1e3a638] + 0x1d2b8` exists did it take max(CPU span, GPU time), in 64 of 6,046 shrine frames. An iPhone 16 Pro Max in handheld mode at a 25 ms frame p50 never left interval 1 in 4,800 frames: at 40 fps, about two thirds of the normal speed. The GPU time (framework +0x220) is the difference between the frame's two timestamp reports, `TIMESTAMP_TOP` at the start of its command buffer (`main+0xe94584`) and `TIMESTAMP` at its end (`main+0xe94664`), read after the draw step waited for the frame's fence (`main+0xe949bc`); it read 0–6 ticks, because the host wrote all 5 reports of the frame's one submission with one time. Two cuts (`main+0x112691c`, `main+0x1126974`: `cbz` → `b`) make the controller always take the GPU path, and `gpu_timestamps segment` gives each report the GPU start or end of its `sub_cut` segment (`rep_ticks` in `nvn_mtl.m`).
- Measured on the Mac with two runs sharing the GPU under a heavy CPU load (load average about 75): GPU time p50 16–23 ms; the fixed run stayed at interval 2 (3 while the GPU time passed 1.9 vsyncs, 1 for under 2% of the frames) at 0.93–0.98 of real time (Σ VFR ratio / 30 per wall second, probe `main+0x151d3e0` `@x0+0x30`: +0x30 ratio, +0x34 interval). A run with the old timestamps (`DM_NVN_GPU_TS=submission`) spent 10–70% of its frames at interval 1 and ran at 0.78–0.95.
- The same GPU time drives the dynamic resolution (`main+0x1267070`): a running average as a percentage of a 60 Hz frame scales the resolution down above 175% (29 ms) and back up below 150% (25 ms). With 0 it always sat at its maximum, and it still does whenever the game holds 30.
- **Resolved: Link's move pace speeding up when pressing B (iPhone).** Sprinting flaps between interval 1 and 2 for runs of 6 or more frames, and the VFR step at interval 2 is a whole 30 fps tick. The acquire waited one display-link tick per frame whatever the interval, so the game kept producing frames every 16.7 ms while the screen held each interval-2 frame for 33 ms and dropped the one between (`old frames dropped by merging`): those runs went at double speed. `mtl_link_wait_tick` now waits as many ticks as the present interval.

#### Render scale

- `DM_RENDER_SCALE=0.5`–`1.0` (also from `Documents/env.txt`) fixes the 3D views at that fraction of 1600×900 docked (1280×720 handheld) and turns the game's dynamic resolution off; 1.0, the default, keeps it. Factors above 1.0 are refused by the loader (the per-frame texture pool's size is unknown).
- The dynamic-resolution method (`main+0x12666e4`) keeps its scale in s8 (0.8–1.0 in 0.05 steps, `+0x1218`, `main+0x1266818`, or the forced 0.75 / 0.5 of `+0x284 & 0x1800`) and applies it from `main+0x1266880`: the views' scale (`+0x28a0` / `+0x28a4` = s8 × base width (`+0x1214`: 1600 docked, 1280 handheld) / output width), from which the size function (`main+0x106340c`) sizes the scene buffers each frame, the shader ratio `uking_dynamic_resolution_ratio` and the other readers (`main+0xc3c3f4`, an LOD check at `main+0x14126b4`). That block runs only when the dynamic path has just recomputed the scale (`+0x280` bit 4, set at `main+0x1266830`) or in a forced mode, else `main+0x126686c` skips it. The stub sets s8 at the block and, for a factor other than 1.0, takes the block every frame. A multiply in the size function (Tears of the Kingdom's way) would leave the ratio and those readers at the old scale.
- At 0.5 the 1600×900 passes become 800×450 and the 800×450, 400×225, 200×112 and 100×56 chains halve too, while the shadow maps and the 1920×1080 output keep their size and the HUD stays sharp. It holds in handheld mode (960×540 at 0.75). On the Mac (M4 Pro) the GPU time does not change (about 13 ms in the first shrine at 1.0 and at 0.5): a frame has about 650 passes, most of them tiny. Whether it helps an iPhone, whose GPU loads and stores each pass's attachments, is what the setting is for.

#### Optional thermal frame cap (current, 2026-11-01)

The iOS Performance setting **Reduce to 30 fps when hot** is optional and defaults
off. It no longer lowers the selected frame-rate cap solely because the system
reports a serious thermal state. Explicitly enabling it restores the existing
30 fps cap and cooling recovery. Movie limits, late-frame holds and their return
to 60 fps are unchanged; iOS still controls hardware frequencies. See
[the thermal-cap mechanism](../../../../docs/reference/frame-rate.md#a-thermally-serious-iphone-holds-30-fps).
Validation: the production cap tests cover unset, explicit off and explicit on,
including concurrent readers under ThreadSanitizer; all 64 frame-step checks,
963 Python tool tests (17 skips), 53 iOS tool tests, launcher persistence,
localization parsing and the Mac host build pass. Python lint has no baseline
growth. Targeted C lint has no findings above its baseline, but uses LLVM 19
rather than CI's LLVM 23. The full regression selects BOTW, the only locally
prepared game, and stops during shader preparation because installed Metal
`32023.883` differs from the locked `32023.922.4`; its report is
`thermal-opt-in-20261101/regress/report.md` in the game's work folder.
Physical iPhone sustained-performance acceptance remains pending.

#### CPU

- **Resolved: CPU hitches (Mac).** In steady play, frames with 30–210 ms of CPU work came every 1–10 s (Zora's Domain, M2 Max): the main thread and the two workers spinning in one job queue poll (`main+0xef62dc`). The first item of some of its jobs is for the thread of core 0; the threads of cores 1 and 2 wait until it is taken (the queue's flag at +0x98, its cursor at +0x94), taking and releasing the queue's lock (+0x1c) on every pass. Polled at full speed by the two workers, the lock went back and forth between their cores, and the main thread lost nearly every exclusive store: in 40 s of a Time Profiler trace it never held the lock while each worker held it about 750 times, and the three spun for 30–210 ms at a time. The spin-wait rule's lock case takes that loop: the workers leave the lock a moment between passes. Zora's Domain on an M2 Max at 120 Hz (42 s of steady play, three runs each, before → after): standing still, frames over 30 ms of CPU work 2.8 / 6.3 / 3.5 → 0 per 30 s, the frame's work p99 20–21 → 8.3–8.4 ms, late frames 2.8 / 5.6 / 2.8 → 2.1 / 0.7 / 2.1 per 30 s; turning the camera, CPU hitches 11.9 / 13.3 / 6.3 → 0, p99 21–25 → 9–15 ms, late frames 12.6 / 13.3 / 7.7 → 1.4 each. Found with `DM_HITCH_DUMP` (the main thread and two workers in one guest loop with no SVC; x0 held the item index) and an `xctrace` Time Profiler trace.
- The spin-wait search takes 310 loops in `main` (308 before the lock and store rules; the new two are the job queue and a state setter at `main+0xf82230` that stores its state and returns on the second pass unless another thread changed it) and widens one in `subsdk0` (`0x27804`, the movie library's thread loop, 6 → 23 instructions). Rewriting `main` takes 26 s of CPU instead of 19.
- `PlacementMgr` and `RadarMgr` yield once per item of their batches (the back-off stretched a 94,263-item radar batch to about 30 s). A yield whose caller's x19–x28 moved now returns at once: outdoors on the Mac, CPU energy went from 0.35–0.74 to 0.21–0.34 W at 60 fps, CPU from 76–83% to 96–106% of a core, and the frame interval's p99 from 19 to 20–21 ms. A `sched_yield` on each of their 200,000 yields a second cost a third of a core more than the back-off had.
- **Address → memory pool lookups**: the game keeps about 1,760 memory pools alive, and `mtl_addr` / `mtl_gpu_addr` scanned them all for every buffer binding of every draw (about 1,000 samples of a submit-thread profile). Last hit, then a binary search (`pool_find`): host submit time in the shrine 21 → 7 ms a frame (p50), the median frame 38 → 21 ms.
- Upload staging blocks are reused: the game used to allocate, make resident and free a 32 MB block for each re-upload of a small CPU-written texture, about 3 GB/s.

#### Experimental resolution and scene upscaling

Both options default off. `DM_DYNAMIC_RESOLUTION=1` retargets the verified
1.9.0 native controller to the effective frame-rate cap. Its original GPU-time
normalization at `main+0x12670ac` becomes 200 at 60 fps, 100 at 30 fps, through
state `+0x38`; zero keeps the original instruction. This preserves the native
averaging, 0.05 steps and 0.8 floor. The 175/150 thresholds then correspond to
14.58/12.5 ms at 60 fps, and retain their original 29.17/25 ms at 30 fps.
Movies and the thermal cap publish the same effective 30 fps budget. A fixed
`DM_RENDER_SCALE` takes precedence; target 0 retains the original budget.

`DM_PRESENT_UPSCALE=scene` uses [scene upscaling before the HUD](../../../../docs/reference/rendering.md#scene-upscaling-before-the-hud).
An outdoor pass trace confirms vertex `5e9f57168d89a543` and fragment
`bd7ffdd435c6c3bc` are the native scene FXAA/upscale from the tone-mapped
1600x900 image into the 1920x1080 UI canvas, before its layout draws. Their
vertex constants already describe the output texel grid, including when the
native controller lowers the input to 1280x720. Only that draw's input is
substituted; the native FXAA, output alpha/channel mask, and all later HUD,
inventory and map draws retain their original state. The single **Upscaling**
choice offers **Standard**, **Scene MetalFX** and
**Full-screen MetalFX** (`DM_PRESENT_UPSCALE=off|scene|metalfx`); the MetalFX
modes cannot run together. MetalFX adds GPU work; neither
option is a measured frame-rate improvement on every scene or device.

Initial validation (`39585d4e`, 2026-10-31, Apple M2): 64 Python checks, the emitted ARM64 budget
stub, 31 scene-scaling GPU checks in each encoding mode, 168 existing present
checks, the present snapshot cases, and 188 iOS source files pass. World,
inventory, map, and return-to-world camera/movement checks retain their HUD.
The BOTW-only `regress.py check --quick` comparison against `3ae8e2b9` is
`PASS`: 19,592/19,592 shaders in both, identical MSL and no new red lines.
Both builds miss the reference machine's 2,500 frames by 60 s gate on this
M2 (baseline 1,744, candidate 1,770 by the end of the 70 s runs); screenshots
confirm both reach the outdoor scene. Other games are not runtime-checked:
only this verified controller and scene pair opt in, and the shared present
path has the focused GPU coverage above.

The unified selector (2026-10-31) removes the independent scene toggle.
Settings generation and the shared iOS/Mac storage check cover one choice,
all three values, applying to the game environment, and reopening saved choices.
Scene GPU tests pass 36 checks in each encoding mode, including refusal in
Standard and Full-screen modes; the 171 present checks confirm Scene mode
keeps final presentation on its standard path. Both localization tables
validate, and all 188 iOS source files compile. The BOTW-only quick regression against
`39585d4e` is `PASS`, with identical 19,592-shader outputs and no new red
lines; both runs still miss the reference-machine frame gate (1,834 and
1,844 at 70 s). Other games retain their existing Standard / Full-screen
choices; scene mode requires the verified profile pair.

Exploratory `scripts/bench.py` comparison, using its existing runner with the
copied post-pickup outdoor save, 60 fps target, the same host and warm pipeline
archive: two 20 s windows per variant, at 60–80 s after launch. No red lines;
the source save's digest is unchanged. Medians over the two runs:

| Variant | fps | GPU p50 (ms) |
|---|---:|---:|
| Original budget and scaling | 21.40 | 25.72 |
| Retargeted native budget | 21.25 | 26.15 |
| Retargeted budget + scene MetalFX | 21.25 | 27.26 |

Other tasks compiled on the same Mac during these runs, so these are not
isolated performance acceptance numbers. They show no frame-rate improvement
in this scene. The native controller's 0.8 floor is unchanged; MetalFX has its
own cost. The two options stay opt-in pending idle-machine and device testing.

Artifacts, including native disassembly, GPU tests and game traces, are in
`dynres-scene-experiment-20261031/` in the game's NSP work folder. Local shader
libraries use chain `715bb867230c` and the explicitly experimental Metal
`32023.883`, rather than the pinned `32023.921`. Physical iPhone acceptance
remains pending.


## GPU work

- **Submissions in segments.** The game does not submit frame N+1 until frame N's GPU work is done: in the shrine the main thread sat in `nvnSyncWait` 59% of the time and the render thread in `nvnQueueSubmitCommands` 40%. That submit is the host's translation (about 3,600 draws and 347 passes, 7 ms), so the GPU ran 13–14 ms and then sat idle 7.7 ms a frame. The replay now commits every 64 draws between two passes (`sub_cut`, `DM_NVN_CUT`): GPU idle 7.7 → 3.8 ms, most of the rest the game's own work between its fence wait and the next submit (about 2.5 ms).
- **Shrine of Resurrection on the Mac (M4 Pro)**, after the above: docked (1600×900) GPU about 13 ms, frame p50 16.7 ms (60 fps; p90 17.6 ms), was 20.8 ms before segmenting; handheld (`DM_OPMODE=0`, 1280×720) GPU p50 9.3 ms and a steady 60. Host translation is 8 ms a frame (22,000 instructions per draw), spread over Metal's encoder creation and draw calls, argument encoding, retain / release and pool lookups. `DM_NVN_PASSGPU` is off under Metal 4, so GPU time cannot be attributed to passes. The frame loaded 376 MB and stored 432 MB of render-target data (325 of 347 passes load and store everything).
- **Outdoors (2026-10-21, the user's Great Plateau save, Mac M4 Pro).** A frame had about 386 render passes and loaded and stored about 900 MB of attachments (on an iPhone at 60 fps about 55 GB/s, near the memory's bandwidth). 220 passes ended only because the game updates the first 64 bytes of a 64 KB vertex uniform block (`0x70c38c0000`) before each draw group while its shaders read up to 544 bytes of it (the terrain pixel shader `eb0afe555b86da79` indexes the whole block). Partial-cover uniform shadows (`ubp_get`, `DM_NVN_UB_PARTIAL`) and `cb_extent.tsv` keep those passes open: 386 → about 165 passes, GPU p50 about 9.3 → 6.5 ms, submit 5.7 → 4.9 ms; `DM_NVN_UBP_CHECK=1` found every shadow equal to the GPU's memory (968,000 checked). Lazy clears fold the four clear-only passes before the G-buffer into its first pass (about 30 MB less a frame at 1600x900). The frame still loads and stores about 800 MB: the NintendoWare VFX GPU particles run one compute dispatch per emitter between draws (ten 800x450 half-resolution passes and two G-buffer passes, about 190 MB a frame; the G-buffer ones read the depth being drawn), and decals sample the G-buffer right after the game sets it again. Tried and dropped: `DM_NVN_TBDR=1` (10–15% fewer stores, more CPU, red ledger lines, deferred uniform updates off), `DM_NVN_BARRIER=game` (no gain), same-target continuation outside TBDR mode.
- **Cube map filter every tenth frame (current, resolved).** Every tenth frame starts by filtering the environment cube map: 132 one-draw passes into 64x64 to 8x8 faces (22 levels of 6 faces, `f8d9bbda1e0ebb0a` with `2ab186d450f5b32c` / `cfc85e532ccf8dd2`, game barrier `0x12` only between levels), so the G-buffer started 7–9 ms into that frame instead of 1.5 ms and the frame took about 5 ms more GPU time: the regular spike in the Metal HUD's frame-time line. The faces of a level now run as one layered pass ([passes into other layers of one texture level](../../../../docs/reference/rendering.md#passes-into-other-layers-of-one-texture-level-run-as-one-layered-pass)): 284 → 173 passes in that frame; Zora's Domain at 900p, FPS 120 (M2 Max), frame p50 10.51 → 10.23 ms, p95 13.16 → 11.11 ms, mean window max 15.6 → 12.1 ms, GPU p95 13.0 → 8.7 ms, 95 → 98 fps.
- **Particle dispatches between effect draws (resolved).** The NintendoWare VFX GPU particles' one dispatch per emitter ended the G-buffer's and the half-resolution passes' effect draws into about 20 extra passes and compute encoders a frame. They now run ahead of the pass ([compute dispatches between the draws of a pass run ahead of it](../../../../docs/reference/rendering.md#compute-dispatches-between-the-draws-of-a-pass-run-ahead-of-it)): 28 → 8 compute encoders, 149 → 132 render passes; same scene and switches as the cube map filter above, frame p50 9.92 → 8.97 ms, p95 10.70 → 9.98 ms, GPU p50 7.69 → 6.70 ms, 101 → 111 fps.
- Same-pass feedback: over a thousand draws a frame sample the G-buffer of their own pass (`4d3d5a4408c2e8d9`, `753d0169ae3ce4f0` and others on the 1600×900 G-buffer), and outdoors about 460 of them also write the target they sample (decals reading and blending the normals). A fresh snapshot for each (`DM_NVN_FB_SNAP=all`) takes the Mac's GPU time from about 4 to 28 ms a frame; none has shown magenta blocks on the iPhone so far. The host now snapshots only draws that write what they sample and reuses a snapshot until the game's next barrier: about ten snapshots a frame, each reused by about 50 draws, GPU time within the runs' noise of no snapshots (3.7–4.5 against 3.5–4.1 ms p50, four runs each on the Apple M6). See [Same-pass feedback read through a snapshot](../../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot).

- **Shrines at 20–27 fps (GitHub issues #534 and #598; current, the fix not yet seen in a shrine).** The reporters' shrines (Oman Au on a MacBook Air M2; every shrine on an M3) run at 20–27 fps where the open world holds 60. In the #598 log the slow stretches have about 1,000 draws a frame, as the fast ones, but a GPU time of about 36 ms against 9–13 ms. They have about 240 `passes ended to land them for a read` a frame, all `refused … other GPU writes`, and 280–330 `load-all store-all passes` against about 100. The probe on the Shrine of Resurrection save found the one write behind that refusal there: the GPU particle dispatch `9f8116baffddaf81` binds its three outputs with size 0, which counted as a write anywhere ([A storage buffer bound with size 0 counted as a write anywhere](../../../../docs/reference/rendering.md#a-storage-buffer-bound-with-size-0-counted-as-a-write-anywhere)). With the fix, that save's world-load burst (1,200 refusals) is gone. Opening Oman Au's final gate ends the slowdown even out of view (#534): an emitter that stops with the gate would fit, but no shrine save was here to show it.
- **Present snapshots (Mac).** The game's two swapchain textures held its CPU work to display ticks and the GPU at 444 MHz on an M2 Max ([present snapshots](../../../../docs/reference/frame-rate.md#present-snapshots-the-games-swapchain-texture-free-at-once)). Judged by cost, the frame step stepped to 30 at a GPU time of 0.75 vsyncs. Zora's Domain from a Cemu save (120 Hz), frames on screen longer than 1/60 s by a quarter: 64 of 8,684 with neither, 41 with the GPU filler alone, 4 of 10,800 with snapshots alone (no step to 30 in 3 minutes, at 444 MHz throughout).

#### Render-pass cost audit (2026-11-01)

The Game Overlay exposes these local render-pass, store and snapshot-allocation
policies as **Memory transfer optimization**, on by default. It is independent
of the off-by-default **Skip feedback snapshots (experimental)** option; both
choices are saved and applied at Play. See [settings](../../../../docs/settings.md#memory-transfer-optimization).

Overlay follow-up (2026-11-01): settings checks cover all four combinations of
the two switches, persistence, Reset and explicit environment overrides on both
platforms. The production iOS launcher compiles. After integrating main
`c197cc6c`, the current `run_mac.py --test` path completes world, inventory,
map and return-to-world checks with memory optimization on, automatic feedback
snapshots and frame generation off. Screenshots render correctly and the log
contains no `[RED]` lines or crash. Artifacts are in
`01007EF00011E000-work/memory-transfer-toggle-20261101/`. No performance
benchmark was run; physical-iPhone acceptance remains separate.

Device baseline (`log2.txt`): iPhone Air, `eb3bc99ccd83`, frame generation and upscaling off,
handheld with fixed scale 0.8. The actual feedback source is 1024x576. At
about 54 s the frame step starts dropping from 60; at 60 s thermal state 2
explicitly caps it at 30. The same 2,773 draws take GPU p50 8.87 ms before
and 28.71 ms after the drop. Fixed scale takes precedence over the enabled
dynamic-resolution setting. These device observations establish a thermal
cap, not an optimization acceptance result.

The current-checkout Mac test path was checked fresh, then used with matching
chain `715bb867230c` and disposable save copies. Three captured frames were
replayed through both policies in the same build, four times each, with the
encode thread both off and on. All 24 corresponding image digests are
identical; draw counts are unchanged. Warm render-pass counts and mean
attachment-traffic savings over replays 2-4 agree in both encoding modes:

| Frame | Draws | Passes before / after | Attachment traffic saved (MiB/frame) |
|---|---:|---:|---:|
| Forest, camera turning | 3,653 | 149 / 147 | 9.32 |
| Ruins save, landscape | 4,423 | 137 / 134 | 16.06 |
| Same save, portrait preview | 2,151 | 133 / 130 | 16.07 |

These are attachment-size ledger estimates, not measured DRAM traffic. Cold
pipeline/cache order affects replay timings, so these runs do not establish
an FPS percentage. The frame captures already differ from their live image
under the reference policy; the before/after policy comparison is exact,
while capture/live equality remains open. The existing matching shader cache
uses experimental Metal `32023.883`, as in the resolution experiment above.

Validation: the complete graphics `make run` passes (88 test targets plus
the pull/budget checks); feedback readback passes 105 checks in each of five
configurations, unwritten stores pass 90 checks in each policy, and the
exact-target tests retain colors, depth, stencil and occlusion counts with
attachment-read and resource-registration fallbacks. The tools suite passes
760 tests (7 skipped), the iOS tools pass 50, and the iOS compile check passes
190 source files. The five-game `regress.py check` selection was BOTW, Tears
of the Kingdom (same engine), Super Mario 3D World (masked G-buffer outputs),
Age of Calamity (compute/draw interleaving) and Xenoblade Chronicles 2
(ordering barriers); only BOTW has a local prepared Mac build. Its separate
static check is blocked by Metal `32023.883` versus required `32023.921`.
Cross-game runtime acceptance remains open.

The final host also completes a portrait `run_mac.py --test --touch-preview`
route from a disposable copy of the ruins save: world, inventory, world,
map, world. All five screenshots render and the log has no `[RED]` lines.
This is Mac preview coverage, not physical-iPhone acceptance.

Open: the phone reached snapshot #100,000 around frame 2,235. The Mac samples
retain 6-10 copies per frame, refreshed by barriers and submission boundaries.
In the final portrait scene's 300-frame windows there are 1,800 copies
(13.5 MiB per frame): 600 barrier refreshes and 1,200 submission refreshes,
with no cache misses or shape refreshes once warm.
The phone's high copy rate has not been reproduced, so it is not
claimed fixed. The new per-window refresh-cause counters distinguish barrier,
submission, shape and cache-miss causes without a full device pass dump.

The general fixes and GPU proofs are described in
[Render-pass reuse with local write proofs](../../../../docs/reference/rendering.md#render-pass-reuse-with-local-write-proofs).
Artifacts, source-save digests, iPhone logs, captures and policy comparisons
stay in `01007EF00011E000-work/render-pass-audit-20261101/`. The source saves
are unchanged; physical iPhone acceptance remains pending.

Follow-up (`log3.txt`, 2026-11-01): the phone runs `1983d2d3cc44` with chain
`715bb867230c`, handheld, native starting scale 1.0, dynamic resolution on,
frame buffering and the encoding thread on. This differs from the baseline's
fixed 0.8 scale, so the thermal onset times are not an A/B performance result.
Thermal state becomes fair at 54 s and serious at 69 s; present 2,736 logs
the explicit 60-to-30 cap. At frame 2,700, before that cap, GPU p50 is already
13.72 ms, versus 9.02 ms at frame 1,800. Pipeline and library compilation
are zero in these steady windows. Later snapshots include 1024x576 sources.

The new counters isolate the high-copy path: the 300-frame window ending at
frame 1,800 makes 27,637 snapshots (92.12/frame), representing 323.87 MiB/frame
of texture-copy payload; 26,154 refresh because of barriers (94.63%), 1,483
because of submission boundaries, and none because of cache misses, shape
changes or forced-copy mode. These are logical texture bytes, not measured
DRAM traffic. The first optimization has not resolved sustained phone FPS;
increasing cache capacity would not address this window's cause.

A current-source Mac portrait run at native starting scale with the same
dynamic-resolution setting still has six copies in its captured frame,
despite 135 barriers with bits 0x12. Thus barrier counts alone do not prove
redundant copying: the writes and sampling between barriers must be traced
on the phone. Collect one steady gameplay frame using
`DM_NVN_PASSDUMP=1500` and `DM_NVN_PASSDUMP_ALL=1` in Documents/env.txt. Its
attachment serials, channel masks, shader keys and cache epochs distinguish
real feedback dependencies from invalidation caused by unrelated work.
No further snapshot-invalidation change is accepted from the summary
counters alone. The follow-up logs and capture stay in
`01007EF00011E000-work/feedback-barrier-audit-20261101/`.

Further device evidence (`log4.txt`, same build): before the cap, frames
900-3,300 consistently make 11 snapshots/frame, falling from 38.67 to
24.75 MiB/frame as source sizes decrease. Frame 3,300 still presents at
60 fps with GPU p50 13.59 ms; thermal serious then caps present 3,402 to
30 fps. High snapshot frequency is therefore not a necessary condition
for this thermal slowdown, although the separate log3 cost remains open.
This launch starts already serious, cools to nominal at 117 s, and logs
frame 5 at 176.84 s; the cap at app age 247 s is about 70 s into frame-loop
execution, not a 247 s cold-gameplay result. There are no pass-dump lines
or environment-load confirmations in log4, so it is not the requested
per-draw trace. Environment files are read once by `boot_env` before the
launcher; a successful load prints `boot: env DM_NVN_PASSDUMP=1500 (env.txt)`
and the corresponding `_ALL=1` line. A build with the optional
`DM_PLAYER_BUILD=1` ignores these diagnostic keys. Confirm startup loading
before another gameplay trace; summary counters alone cannot identify
redundant barriers or attribute all heat to feedback copies.

Device draw trace (`log5.txt`, same build): both environment settings load,
and frame 1,500 contains 93 snapshot copies. Two 1280x720 attachments account
for 44 copies each: serial 71,976, RGBA8 sRGB (color 1), and serial 71,978,
RGBA8 (color 3). Passes 129,075-129,116 alone copy this pair 42 times (84
copies); later terrain/VFX draws add four copies of the same pair. The
draw groups write these attachments (channel mask `0xf0f0ff`, fragment
outputs 0, 1 and 3) before barriers `0x12` and subsequent reads. These
are real intervening writes, not evidence of unrelated-barrier invalidation.
Ignoring these barriers or retaining the frame's initial snapshot would
read an older version. The steady windows show 93 copies and 326.95 MiB of
logical payload per frame; this is not measured physical memory traffic.
The 102,466-line single-frame dump adds substantial diagnostic work, so its
thermal onset is not an A/B benchmark. Remove both dump settings after use.

The dominant pair uses its original formats, but every snapshot allocation
formerly requested `MTLTextureUsagePixelFormatView`. The host now requests
that capability only for actual format reinterpretation, preserving
lossless-compression eligibility on supported Apple GPUs. A later required
format view upgrades the cached snapshot by copying its retained version,
not the newer source attachment. This is a general allocator change, not
a shader exception, barrier relaxation or reduction in required copy count.
See [Feedback snapshot usage preserves compression eligibility](../../../../docs/reference/rendering.md#feedback-snapshot-usage-preserves-compression-eligibility).
It does not establish a compression ratio or resolve device thermal limits.

Current validation: the complete graphics `make run` passes all 88 targets
and the pull/budget checks. Feedback readback passes 123 checks in each of five
configurations, including integer-view upgrades after source writes;
geometry feedback passes 110, geometry hazards 22 in each of three modes,
and texture-view swizzles 379. The iOS source compile passes 190 files.
A current-checkout `run_mac.py --test --touch-preview` route renders world,
inventory, world, map and world with no `[RED]` lines; ordinary snapshots
report usage `0x1` (shader read). Both source-save copies retain all 14 file
digests. This is Mac coverage, not physical-iPhone acceptance.
Three retained captures in both encoding modes, four replays each, match
the archived `1983d2d3` candidate's 24 image digests, draw counts and warm
pass counts. Capture/live mismatch still predates this change; paired
replay equality does not resolve it. The five-game regression selection
is BOTW, Odyssey, Wonder, Origami King and NieR, covering known feedback
users; the latter four have no prepared local Mac builds, so the selection
cannot execute. Device bandwidth, temperature and sustained FPS remain open.

Device GPU profile (`log6.txt`, `80c9efc8c31e`): periodic sampling every 600
frames works and ordinary snapshots report usage `0x1`, confirming the
allocation change is active. Thermal state starts at 0 and reaches 1 at
52 s; it never reaches 2, and the explicit FPS cap remains 60. The host's
missed-deadline controller changes the hold to two vsyncs instead. Windows
ending at frames 1,500/1,800 have GPU p50 9.30/12.82 ms and 91.87/92.09
copies per frame; at 2,400/2,700 GPU p50 is 27.22/26.66 ms while copies
fall to 79.44/31.15. Steady pipeline/library compilation is zero. Copy
frequency alone therefore does not identify this run's bottleneck.

Frame 2,400 measures 21.63 ms in render encoders, 0.39 ms in compute/copy
encoders and 26.05 ms from first GPU start to last end. Its largest pass
has four 1280x720 color attachments plus depth, 2,857 draws and 7.104 ms.
The complete sampled frame has 4,618 draws, versus 2,842 in frame 1,800;
these are changing workloads, not a controlled frequency measurement.
Encoder gaps and render attachment transfers are not all attributable to
the compute/copy category. GPU frequency is not logged, so platform DVFS
remains possible despite the absence of the serious-thermal FPS cap.

This run also sets `DM_DYNAMIC_RESOLUTION=0`, versus 1 in logs 4 and 5.
With `DM_RENDER_SCALE=1.0`, BOTW retains its original resolution policy
without the host's 60-fps budget normalization; the sampled main passes
remain 1280x720. This is another reason not to treat these logs as an A/B
measurement of the snapshot allocation change. Evidence and normalized
window/profile tables stay in `01007EF00011E000-work/log6-gpu-audit-20261101/`.

Pipeline-path experiment (same host `80c9efc8`, Mac Apple M2): replay the
retained portrait scene in four fresh processes, `DM_PSO_MTL4=0/1/1/0`,
12 replays each, excluding the first three of each process from timing.
The full-state MTLDevice path measures warm GPU median 8.465 ms, versus
8.560 ms for Metal 4 specialization (1.1% less). Same-path run medians
vary by 0.84 and 0.40 ms respectively, exceeding that difference. The
corresponding image digests match across all four runs (48 outputs).
The replayer's captured-pipeline prewarm completes before frame timings;
the Metal 4 run confirms 1,421 specializations and zero MTLDevice fallbacks.
This does not support changing the default path; it is one Mac scene,
not iPhone performance acceptance, and capture/live mismatch remains open.
The other Mac preview was paused only during comparison and then resumed.
Results stay under the audit folder's `pso-comparison/`.

Presentation inspection: an empty display queue returns before `present_now`,
so a 60 Hz display link does not redraw an unchanged game image each tick.
The four log6 present windows report bilinear GPU p50 0.379-0.633 ms.
Elapsed encoder gaps alone are not proof of removable synchronization.


#### MacNativeGames non-interpolation port (2026-11-01, current)

Main's capability-selected BC decoder (`9cbe8984`) is merged into the experimental
branch (`a124cc3a`). The additional public MacNativeGames `92ec79bd` mechanisms
are adapted through the general renderer, without a BOTW-specific policy:

- [Independent driver metadata reuse](../../../../docs/reference/rendering.md#repeated-driver-metadata-bank-allocations)
  preserves this checkout's extra image, pool-relative handle, base-instance and
  indirect-dispatch semantics. It is opt-in (`DM_NVN_DRV_CACHE=1`): four paired
  Mac replays gave identical corresponding digests, but no repeatable timing gain.
  Off-run warm submit medians were 22.33 and 20.87 ms; the unchecked on run was
  21.09 ms (a separate checked-on run was 22.13 ms). The capture has a pre-existing
  live/replay mismatch, so this is paired-path evidence, not live-frame acceptance.
- [BC fallback transcoding](../../../../docs/reference/rendering.md#bc-textures-on-gpus-without-bc-support)
  is selected only by low-memory mode on a GPU without native BC support, with
  `DM_NVN_BC_TRANSCODE=0` available to retain decoded pixels. Re-compression can
  lose detail. Ordinary mode, native BC, signed BC, BC6H, 3D and writable textures
  retain the existing representation. Original block bytes remain available for
  copies/readbacks. This is an old-device memory tradeoff, not an iPhone Air
  optimization: the user's log6 identifies an A19 Pro GPU, which supports BC.

Focused Metal-validation tests cover metadata immutability, all BC decode formats,
low-memory selection, sampled ASTC/EAC mip/array contents, GPU-written partial
updates and writable upgrades, including threaded encoding. The standard BOTW
regression preparation currently fails before gameplay: after using the existing
arm64 venv to avoid Rosetta/.NET architecture mixing, the compiler check rejects
installed Metal 32023.883 against locked 32023.921. Only BOTW has a local Mac
build in the configured games folder; the requested broader game checks and
physical iPhone acceptance remain open. Evidence and logs are under
`01007EF00011E000-work/macnativegames-port-20261101/`; no IPA is repackaged.


## Memory

- **Resolved: the world-load crash (about 1 run in 3 on the Mac) came from the host's command record sizes.** About 3 s after Start, a task worker's `operator new` (`main+0x155a79c`) got null and the game wrote through it (`main+0x155a7a4`). Each model file gets a heap of its resource size table entry + 0x1008; the file goes in 4 KB aligned, and the model's setup (`main+0x155a2ac`) takes the rest as a frame heap (vtable `main+0x1d4f950`, head +0xe0, tail +0xe8). Part of the setup is GPU memory for the model's prerecorded commands, sized by recording each mesh's draw and each shape's state for each pass into a scratch command buffer and summing `nvnCommandBufferGetCommandMemoryUsed` (`main+0xf9aeb4`, `main+0xf9bb54`), so the host's record sizes count against the table. Draw records had grown to carry the indirect and multi-draw fields (0x38 → 0x50 per recorded draw on 2026-10-18 and 10-20), and every recording began with an 8-byte BEGIN record. `Obj_TreeConiferous`, `Obj_TreeBroadleaf_B` and `FldObj_HyliaBridge_A-02` then needed one 4 KB page more than their entries allow, which fit only when the file's alignment pad (0 to 0xff8) was small (about 15% of loads each failed; most models have about 0xd00 to spare). Plain draws now leave those fields out and recordings have no BEGIN (0x30 per recorded draw, `nvn_obj.h` `draw_rec`): all 510 models of the world load fit whatever the pad. To check a whole scene, probe where the setup heap is cut (`main+0x155a520` with `!x21`) and the end of the setup (`main+0x155a5f4` with `!x2`) with `DM_PROBE_HEAP=28,38,40,e0,f8 DM_PROBE_HEAPFRAME=1d4f950 DM_PROBE_HEAPWORDS=1`. A model fits any placement when entry + 0x1008 covers the resource heap's header and object (0x310), the file, the frame heap's block header and its peak use, plus 0xff8 of pad.
- **Resolved: the iPhone app was killed for memory in the first shrine (GitHub issue #9, iPhone 16 Pro Max, handheld).** An 8 GB iPhone gives the app about 3.4 GB (resident plus `headroom to the system memory limit` stayed at 3,375 MB). Resident memory grew about 0.2 MB a frame from 2.6 GB at the shrine load until the kill, with the residency set and texture counts flat. The deferred-release drain ran on the guest submit thread with no autorelease pool (`defer_drain` now has its own `@autoreleasepool`): on the Mac a host without it grew 1 MB a frame in the shrine (GPU 3.0 → 4.4 GB in 2,400 frames); with it the shrine stays at 2.7–2.9 GB resident and 1.5–1.7 GB GPU (vmmap at 2.8 GB: about 1.6 GB guest memory, 0.75 GB private textures, 0.17 GB IOAccelerator). Found on the way: about 10 serial-table entries a frame were never deleted (finalized transient targets replay resolved again; 276,000 after 25,000 frames), now in a 512-entry table (`tex_put`, `g_ghost`, `finalized textures still referenced`); and the memory-pool tracking table had 4,096 slots against 4,006 pools on the phone, now growing in blocks of 1,024 (`nvn_dirty.c`, up to 262,144).
- About 2.8 GB in the first shrine in handheld mode, idle or walking (Mac), against the 3.4 GB an 8 GB iPhone gives the app; the README says it comes close to that limit without the Increased Memory Limit capability.

## Audio

- **Resolved: crashes in `CommandListProcessor::Process` (SIGSEGV under `render_main`, at 60 s and 134 s in the shrine).** SDK 20's `AudioRenderSystem` has another layout (getters inlined, `GenerateCommand` takes and returns a `Span<std::byte>`, device and mode at +0x48 / +0x4c, command buffer at +0xf8 / +0x100, `UpdateImpl` locks +0x2d0; DeviceSink is command 0x14). The public `ExecuteAudioRendererRendering` (`sdk+0x221e90`) reaches `AudioRendererImpl::ExecuteAudioRendererRendering` (`sdk+0x22ca88`) through the vtable, so the host's takeover of the `Impl` function was never called: the SDK's own `AudioRenderSystem::ExecuteAudioRendererRendering` ran with no update lock, every `RequestUpdate` rendered a catch-up frame, and two threads wrote the same command buffer. The host now also takes over the PLT target; catch-ups fell from one per update to 3 per run.

## Services and loading

- **Resolved: every pointer in `.data` / the GOT a module offset, crashes everywhere.** SDK 20 packs relative relocations as `DT_RELR`: `main` has 223,994 of them (`relr_apply` in `loader.c`).
- **Resolved: SIGBUS inside Metal (`AGCDeserializedReply`) at a guest-stack address.** Ending a render pass inside `nvnQueueSubmitCommands` made the driver compile its fast-clear blit on the render thread's small stack; every implemented NVN function except the recording calls now runs on the 512 KB host stack (`nvn_big_entry`).
- SDK 20 calls it needed: `applet::GetAppletResourceUserId` (SDK 20's `OpenAudioRenderer` aborts on ARUID 0; the host reports 0x80), `pl::RequestSharedFontLoad`, `pl::IsVrMode` / `BeginVrMode` / `EndVrMode`, `pctl::CheckStereoVisionPermission` (not permitted: the options' Labo VR mode stays 2D), `oe::TryPopLaunchParameter` (none), `time::StandardSteadyClock::GetCurrentTimePoint`, the console six-axis sensor (`hid::*SevenSixAxisSensor*`: zero states) and more `nfp` calls (`AttachActivateEvent` / `AttachDeactivateEvent` crashed in the SDK at `sdk+0x3f2a78`; two-argument `Mount`, `Unmount`, `GetCommonInfo`, `GetRegisterInfo`, `GetState`, `Finalize`). `nvnPrivate0` (a flag in `sdk`'s bss) stays 0, and `nn::ro::ProtectRelro` runs natively on the host's no-op permission calls.
- `main` imports `ScalableFontEngineHelper::Decode` (SDK 20), so the shared font is served as BFTTF. Focus handling mode 2 (focus notifications are sent).
- Rewriter: 1 to 6 halfword jump tables in `main` changed when `half_count` padded only to their largest entry.
