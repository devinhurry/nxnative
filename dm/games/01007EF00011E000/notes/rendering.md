# BOTW rendering

## Rendering

### Picture filters (current)

The shared [final-picture filters](../../../../docs/reference/rendering.md#picture-filters-in-the-final-present)
were checked on 2026-11-05 with this checkout's `scripts/run_mac.py --test`,
the matching `b-c2cc5a7544c5` libraries and a copy of the outdoors save.
Original, Vivid, Warm and Cool, then the true 33-cubed Cinematic LUT and an
external CUBE selected as Custom LUT, reached the outdoor save and captured
1280x720 final-present PNGs at frame 2,100. Each run exited normally without
`[RED]` or crash lines. Source and shader preparation reused the existing
extraction and translation outputs. The [fixed-aspect capture recipe](../../../../docs/reference/rendering.md#capturing-a-native-aspect-game-at-a-fixed-output-size)
corrects the first screenshots, which squeezed a 2.1513-aspect camera into
16:9. The replacement captures log a 1.7778 camera aspect; no image resizing
was applied afterward. Their in-game clock and animated foliage can differ.

All four styles, original/zero-strength identity, intensity blending, sRGB,
alpha, letterbox, MetalFX and independent presentation regions pass the
synthetic pixel fixture (1,086 checks), including custom-table axis order,
input domains, trilinear interpolation and retained in-flight tables. The CUBE
reader and shared launcher's import, persistence, live replacement and removal
checks pass; 267 iPhone sources compile and the unsigned production project's
synthetic compile/link build passes. The complete graphics suite,
`make -C dm/gfx/tests GAME=01007EF00011E000 run`, also passes. These are not
physical-iPhone appearance or performance results.

The current-picture editor follow-up uses the same captured outdoor frame for
its full preview, style thumbnails and original comparison. A native Mac
settings session opened the new page, selected Cinematic and toggled Compare
original; AppKit view captures record the actual interface. The comparison
restores the original picture while retaining the selected style. The shared
editor also passes 320-, 720- and 1,000-point layout checks. The production iOS
project compiles and links the preview, unsigned; no phone UI acceptance is
claimed. See the [shared preview mechanism](../../../../docs/reference/rendering.md#picture-filters-in-the-final-present).

Only BOTW has a complete local Mac build eligible for `regress.py`. Its static
`check --games 01007EF00011E000 --no-smoke` comparison passes: 19,592/19,592
shaders on both revisions, no changed MSL, no new shader or interface failures.
The chain lock and game shader libraries were not changed. The earlier
installed-compiler mismatch did not prevent this completed cached comparison.
Other games, physical iPhone play and the new LUT's frame-time overhead remain
unchecked. The earlier 0.055 ms final-present timing is not a LUT measurement.
Evidence is under `picture-filters-20261105/` in the game's work folder.

#### Experimental MetalFX frame generation

**MacNativeGames parity audit (2026-11-01, initial source comparison).** The current `expriment` worktree was compared with upstream main `92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15`, fetched into `01007EF00011E000-work/framegen-parity-20261101/` with a source manifest. This is implementation coverage, not a same-device performance comparison. The original adapted source remains credited at its original revision. This table records the initial gaps; current implementation and functional acceptance are tracked in the [completion checklist](../../../../docs/framegen-parity.md):

| Capability | MacNativeGames source | Experiment at the initial audit |
|---|---|---|
| Native interpolation | Metal 4 MetalFX, one inserted picture per real pair | Implemented with the same API |
| Scene, depth and camera | BOTW scene boundary, D32 depth, vertex slot 0 / 2336 bytes | Implemented with the same BOTW boundary and camera layout |
| Camera motion and history | Depth reprojection; missing input, first frame and camera cuts reset history | Implemented; lifecycle resets and local object-motion refinement are also present |
| HUD integration | Separate premultiplied RGBA16F attachment; UI fragment variants copy color 0 to color 7; `uiTextureComposited=NO` | **Partial:** pre/post-UI canvases use `uiTextureComposited=YES`; transparent edges are not equivalent |
| Held source rates | 30, 40, 50, 60 real frames/s, plus uncapped interpolation | **Missing:** only 30+30 is accepted; loader and frame-step policy currently support 0/30/60 targets |
| Live selection | Requested mode latched at a game-frame boundary | **Missing:** launcher selection applies on Play |
| Non-display-link presentation | Classic presenter can display both generated and real pictures | **Different:** classic/rescue paths deliberately preserve real pictures and suspend unused generation |
| Render-mode scope | Handheld uses a native 1280x720 canvas; shared adapter tracks the canvas feeding the window | Implemented for Docked and Handheld; current-checkout Mac runs capture native 1080p and 720p output respectively; iPhone acceptance remains open |
| Display refresh selection | Display-link mode 1 follows the native screen rate | **Different:** existing 60 Hz default and optional 120 Hz policy retained; device pacing requires separate acceptance |
| Timing and lifetime | Real-frame delta, half-period presentation, three outputs, cached interpolators and retained frame resources | Implemented, with additional output ownership and late-generation rejection; physical cadence acceptance remains separate |
| Moving actors | Camera/depth estimator suppresses camera motion on detected moving pixels; no engine skinning/object vectors | Local image-flow refinement is implemented, but neither implementation supplies full engine motion |

The source evidence is the pinned upstream [adapter](https://github.com/ly05010419/MacNativeGames/blob/92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15/games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx.m), [mode policy](https://github.com/ly05010419/MacNativeGames/blob/92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15/games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx_mode.h), and [capture/presentation integration](https://github.com/ly05010419/MacNativeGames/blob/92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15/games/totk/third_party/d2r_gfx/gfx/nvn/nvn_mtl.m). Their source has no separate generation queue or engine-provided actor vectors to import as an already solved mechanism. The initial audit prioritized a separate HUD attachment with offline shader-output variants, native blend/mask behavior and native-resolution UI. The implementation follow-up below also changes real-frame pacing and simulation together for multiple rates, and adds lifetime coverage for classic presentation. Feature-off behavior and real-frame priority remain constraints.

Parity acceptance must independently cover transparent HUD pixels, moving actors/occlusion, source game speed, actual real/generated presentation timestamps and enqueue age at each supported refresh/rate combination, plus pause/resume and fallback recovery. Source coverage alone cannot close the reported iPhone Air stutter. Automatic thermal suspension is not implemented here, nor established by the inspected upstream frame-generator code.

**Parity implementation follow-up (2026-11-01, current).** All five remaining implementation gaps have code paths in this worktree: separate premultiplied HUD output, 30/40/50/60 plus uncapped source modes, live frame-boundary changes, generated pictures in classic/rescue presentation, and native-screen refresh selection. The [completion checklist](../../../../docs/framegen-parity.md) separates implementation, functional evidence and physical-device acceptance. This follow-up performs no performance benchmarks at the user's request.

The [separate HUD path](../../../../docs/reference/frame-rate.md#frame-generation-distorts-translucent-hud-edges) uses offline fragment variants, with the original draw and query executed once. Existing render-pass optimizations continue outside the captured UI canvas. BOTW's verified 1.9.0 VFR/fade/UI/physics instructions consume one latched real-frame ratio at fractional source rates; zero preserves the original instructions when interpolation is off. Source-rate changes drain old owners, reset history and keep display allocator fences monotonic. Display deadlines retain fractional refresh remainders and reseed from a real picture when an optional midpoint is skipped.

Functional controls cover native UI pixels/coverage, query counts, 30/40/50/60 modeled source deadlines, unsupported GPUs, live on/rate/off/on changes, pause and display recovery. The iPhone source compile passes 191 files. Full Mac/iOS shader preparation and current-source Mac gameplay now pass: a copied Lab save reaches the world and all live modes apply without red log lines. Exact evidence and compiler identity are in the completion checklist; physical-iPhone acceptance and performance parity remain open.

**Handheld and resource-reuse follow-up (earlier 2026-11-01).** The [capture mechanism](../../../../docs/reference/frame-rate.md#frame-generation-captures-offscreen-copies-and-maps-the-wrong-region) now supports the native Handheld canvas. Its completion shader is `f7ee6fe10b925543`; Docked retains `bd7ffdd435c6c3bc`. The existing final canvas-copy key `ecb4242efaf4042b` identifies the source actually copied into a registered window texture, excluding intermediate copies. Its viewport travels with the present ticket: Handheld copies 1280x720 into the top-left of a 1920x1080 allocation, so normalizing the window crop against the allocation would incorrectly crop generated pictures. No game shader or chain change is needed.

The [motion/input reuse change](../../../../docs/reference/frame-rate.md#frame-generation-repeats-motion-classification-and-duplicates-inputs) classifies each flow tile once, removes a second full-size motion texture and borrows the completed UI canvas until GPU feedback. Three alternating synthetic production-encoder comparisons reduced median motion time from 1.474 to 1.166 ms (about 21%); this is not a whole-game speedup. At 1080p output with a 720p motion grid, owned texture allocation falls from 66,617,344 to 54,198,272 bytes, excluding MetalFX-internal allocation and process memory. Native-format probes found no material GPU advantage between separate and composited UI inputs on this M2; clean HUD extraction remains a quality gap.

Current-checkout `run_mac.py --test` runs reached the copied laboratory save in both modes with matching cached libraries. Handheld at scene scale 0.75 captured 960x540 depth/camera and generated native 1280x720 output; Docked at scale 0.5 captured 800x450 inputs and generated 1920x1080 output. Both profiled runs had one configuration and no resize drain. Their median interpolation command-buffer spans were 6.74 and 9.42 ms respectively. These are different rendering configurations, not a causal before/after speedup. Display records still contain long gaps; another native-30 run without interpolation also contains gaps. The cause is not isolated, and remote screen transport and diagnostic captures prevent a stable-cadence acceptance claim from these samples. Performance acceptance is paused at the user's request for device testing; no iPhone smoothness improvement or full MacNativeGames parity is claimed.

Validation: 221 MetalFX/image/display checks, nine unsupported-device checks, twelve isolated motion processes, 29 ordinary pacing checks, seven snapshot checks, twelve missed-callback checks and 21 texture-ledger checks pass. All 191 iPhone source files compile unsigned; launcher/settings/report checks pass. Full shader regression remains blocked by installed Metal 32023.883 versus locked 32023.921. The external `framegen-parity-20261101/performance/` folder holds source hashes, commands, measurements and exclusions. Physical iPhone Air acceptance remains open.

**Earlier pacing validation (2026-11-01, before the Handheld/resource-reuse follow-up).** The [missed-notification correction](../../../../docs/reference/frame-rate.md#frame-generation-waits-again-for-skipped-display-callbacks) passes all 12 controlled delegate/acquire checks after seven failed before it. The 36 existing pacing checks, 200 MetalFX queue/image checks, six unsupported-device checks and 13 documentation checks pass. The renderer compiles for iPhone. Physical iPhone Air smoothness remains unverified; the user reports similar 30-60 displayed FPS but worse motion with interpolation.

A clean Mac laboratory route uses current-checkout `scripts/run_mac.py --test`, copied saves, matching cached `b-715bb867230c` libraries, Docked mode, 16:9, a 0.5 scene scale and a 1920x1080 interpolation output. After native gameplay visibility and 30 seconds of warmup, its final 30-second window contains a scripted camera turn. Screenshots confirm the same laboratory and visible HUD without a loading spinner. Distinct positive native presentation timestamps, not submission counts, give:

| Mode | Real pictures/s | Generated pictures/s | Distinct presentation timestamps/s | Interval p95 | Real enqueue-to-display p50 |
|---|---:|---:|---:|---:|---:|
| Native 30 cap | 29.10 | 0 | 29.10 | 33.33 ms | 122.28 ms |
| Native 60 cap | 49.70 | 0 | 49.70 | 33.33 ms | 74.50 ms |
| Frame generation before missed-notification correction | 29.03 | 28.27 | 57.30 | 16.67 ms | 89.04 ms |
| Frame generation after missed-notification correction | 28.87 | 28.30 | 57.17 | 16.67 ms | 89.32 ms |

These individual runs establish no ordinary-load FPS improvement from the clock correction. The generated-frame path already includes the earlier nonblocking allocator fix; there is no clean before/after measurement of that fix. Frame enqueue age is not input-to-photon latency. The corrected run's interpolation submission spans p50 14.90 ms, including p50 12.01 ms in the MetalFX interval and 0.51 ms in motion. Extra presentation-queue waiting after both source interpolation and CPU submission are ready is p95 0.34 ms, which does not justify a second GPU queue in this scene. The 50 ms interval p99 and physical-device quality/performance keep general acceptance open.

A separate opt-in screenshot run captures a generated/current-real pair during a scripted camera turn, with generation history warm at frame 1382/ticket 1383. Three background patches align after horizontal shifts of 20-28 pixels (normalized correlation 0.969-0.990 rather than 0.565-0.712 without a shift), demonstrating that this generated picture is not a copy of the current frame. A previous/current/generated triplet was not captured, so this is not an exact midpoint oracle or full actor/UI acceptance; translucent heart reconstruction remains visibly imperfect. Its explicit screenshot waits exclude that run from performance comparisons.

Artifacts, source hashes, routes and analysis are in `01007EF00011E000-work/framegen-clean-20261101/`. The narrow BOTW regression command was attempted with no game smoke (native runs use `run_mac.py --test`): shader preparation is blocked by installed Metal 32023.883 versus the chain's locked 32023.921. The toolchain lock and shader chain were not changed; this is not a full shader-regression pass. Other games and feature-off timing are outside the enabled frame-generation branch.

The default-off prototype is merged into main. In the shared **Settings → Game**, select a 30/60 base **Frame rate** and use the independent **Frame generation** switch for 30, 30+30, 60 or 60+60. The same settings page handles live changes on Mac and iOS; the standalone interpolation menu and floating button are removed. Both Docked and Handheld paths are enabled, with a smaller native canvas in Handheld. Supported GPUs may insert one picture between real frames. Unsupported GPUs keep the base frame rate. Environment modes `40`, `50` and `max` remain backend diagnostics outside this UI. This operates independently of touch/controller mode. Profiles without configured inputs cannot enable this BOTW path.

The [presentation and ownership mechanism](../../../../docs/reference/frame-rate.md#experimental-metalfx-interpolation-keeps-real-frame-ownership) derives camera motion from the validated 2336-byte vertex camera block, identifies the scene using the profile's per-mode completion keys, and supplies a separate native-resolution premultiplied UI layer. Camera movement is reconstructed and non-rigid regions receive local image-motion refinement. Object animation has no engine-supplied motion vectors, so disocclusions, fast animation and moving actors can still show artifacts. The UI layer preserves native shader colour and accumulated coverage; unsupported capture states display the real picture. The source and license are recorded in [MacNativeGames attribution](../../../third_party/macnativegames/README.md).

The adapter snapshots the scene once and captures the UI through offline `<key>_bui` fragment entries into RGBA16F attachment 7, using `uiTextureComposited=NO`. Its RGB follows the original blend and mask; coverage accumulates separately for over-blends and stays unchanged for additive colour. Original draws, depth/stencil tests and occlusion queries execute once. This needs rebuilt libraries of the current chain; the host loads no old graphics snapshot or runtime-translated game shader.

Validation (2026-10-31): Apple M2 supports the real Metal 4 MetalFX interpolator. The GPU/display fixture passed 55 checks, and all 189 iPhone source files compile without signing or installation. Queue allocator, rescue, tick conversion, snapshot and pacing fixtures passed with the feature off. Current full branch sources and matching `b-715bb867230c` / `6498200c0506` cached libraries reached the title, loading screen and the supplied `After-dialogue-map-not-clickable` save's laboratory scene. Native `presentedTime` callbacks confirm generated pictures reach the display, and the generated/real PNG pair was inspected. Native scene artifacts reproduced with the feature off as well. The captured generated HUD has edge differences around empty hearts; automatic UI decomposition is not exact. Original saves are copied before launch.

Performance observation, not a controlled benchmark: the M2 Docked 1080p scene ran roughly 22–27 real frames/s with interpolation, versus about 30 with it off. Generation GPU work was around 14–15 ms at the median. A 70% scene-scale trial retained 1080p interpolation output and still did not sustain 30+30. Confirmed displayed counts lagged generation submissions substantially, so queue submissions must not be reported as delivered frames. Cadence, UI quality and overhead need further work; this prototype is not recommended as a default. The earlier resize-contaminated run is excluded from these observations.

Review corrections (2026-10-31): generated pictures now use the real window's crop, mapped by normalized edges to the captured canvas size. Both suspend and resume publish an atomic history-reset request, consumed on the submit thread even when no guest frames occurred during the pause. FIFO merging suppresses interpolation if its preceding real ticket was skipped, then resumes after a real picture. A generated display submission holds its own output reference through GPU completion, independently of the queued real picture. The frame-rate cap and renderer share the same effective device capability decision; requesting the feature on an unsupported GPU no longer forces 30 fps. These paths pass 133 MetalFX/image/queue checks (including a GPU-blocked display whose queued real picture is dropped), 6 forced-unsupported checks and the loader's actual five-case FPS-state fixture. The Wonder-profile FPS fixture preserves its original target in all five cases. Normal-mode allocator and rescue fixtures pass 13 and 53 checks respectively; the changed graphics and loader sources compile for iPhone (no device delivery).

Structured image characterization uses 256x256 tiled backgrounds and a translating foreground rectangle with known depth. The earlier shared-interpolator fixture produced exact current-frame fallbacks for moving objects and pan/occlusion. That result is superseded for cause analysis: a later positive camera-only control also failed after a reset in the same process. Fresh-process controls show that analytic object motion can produce the correct midpoint. The earlier camera-only estimate was inaccurate for foreground movement; the later local refinement and isolated/shared-instance controls are recorded below. Engine-supplied object/animation velocity is still absent.

Actual presentation measurement from a 70-second M2 window run, including a scripted camera turn: in the final 20 seconds, 437 real and 406 generated display callbacks reported 429 real and 212 generated nonzero `presentedTime` values. There were 640 distinct reported refresh timestamps (about 32/s), with picture intervals p50 33.33 ms and p95 50.00 ms. Median generation GPU work was 14.75–15.22 ms. This is neither stable 30 real frames nor 60 displayed pictures per second. Even a nonzero presentation callback does not prove a distinct interpolated pose; the controlled tests distinguish correct camera interpolation from inaccurate foreground motion and shared-instance reset fallbacks. Timing and source hashes are retained in `mfx-experiment-20261031/review-presented.tsv`, `review-cadence.json`, `review-game.log` and `review-host-source.json`. Uniform cadence, dynamic-object motion and translucent/empty-heart UI quality remain open.

The local `regress.py check --games 01007EF00011E000` stops while preparing its baseline: installed Metal `32023.883` differs from required `32023.921`. No chain guard was weakened. This machine has only BOTW prepared locally, so there is no five-title gameplay result. Normal-mode profile gating is checked with Wonder/TOTK settings and a Wonder-profile fixture. At that initial stage the unmatched Handheld scene was excluded; the later native-canvas follow-up above supersedes this restriction. The local Metal validation layer raises `globalTraceObjectID` inside MetalFX; use `MTL_DEBUG_LAYER=0` for this experimental path on the tested system. Physical iPhone testing, long-session memory, rapid camera motion, widescreen combinations and power remain unverified.

Diagnostic: `DM_FRAMEGEN_SHOT=<prefix>` writes one generated/real PNG pair after 600 generated display submissions, with a CPU/GPU wait only for that requested capture. `DM_FRAMEGEN_TIMING=<file.tsv>` records submission serial, real ticket, picture kind, target time and the drawable's actual `presentedTime` (zero means unconfirmed), allowing refresh/cadence analysis without counting submissions as delivered pictures. Periodic `[framegen]` log lines distinguish real input frames, generated pictures, missing inputs and generated display submissions and native confirmed presentations. The focused checks also passed 13 shader-chain tests, 2 launcher-settings tests and 12 documentation checks. Run artifacts are under the game's work folder `mfx-experiment-20261031/`.

Second review (2026-10-31): [real-only presenter gating](../../../../docs/reference/frame-rate.md#frame-generation-runs-without-an-interpolation-presenter) fixes wasted scene capture/interpolation with `DM_PRESENT_LINK=0`, a paused/stalled callback or rescue. Returning reseeds history. Optional GPU work is admitted only after the preceding real display command has been committed, so it cannot get ahead of that real picture on the shared queue. A queued newer real frame, an interpolation aged by a game interval, or a predecessor already reported as failed selects the real picture. Submitted and actually presented states remain distinct. A valid seed real picture reserves half a game interval before the next interpolated slot, including on 120 Hz callbacks. These changes provide a real-priority policy; they do not establish stable 30+30 delivery.

Rejected policies and motion controls: requiring a predecessor's actual presentation report before preparing/displaying the pair suppressed all generated output in a visible Mac window. A second candidate combined a nominal midpoint deadline with a requirement that generation finish before callback entry; it also suppressed output. Callbacks prepare future presentation slots, so completion at callback entry is not a valid general deadline. These policies were removed rather than counted as successful cadence fixes. The earlier shared-instance controls with independent UI or analytic foreground motion also returned the current frame. Those results cannot isolate a UI or motion-vector cause because the later shared-instance camera-only positive control fails too. Preserve them as reproduction logs, not as evidence that MetalFX cannot interpolate objects. Fresh-instance motion controls and the remaining reset/reuse problem are recorded below.

Reference comparison is against MacNativeGames commit `933b6a0d1438de160208a0a13eb5e8d7a2cb8094`: its [classic presenter](https://github.com/ly05010419/MacNativeGames/blob/933b6a0d1438de160208a0a13eb5e8d7a2cb8094/games/totk/third_party/d2r_gfx/gfx/nvn/nvn_mtl.m#L15474-L15485) can display interpolation without the display link and skips it if a newer real picture is queued. Its display-link path schedules pairs by refresh intervals and records actual cadence; it does not wait for actual predecessor confirmation. Its [motion implementation](https://github.com/ly05010419/MacNativeGames/blob/933b6a0d1438de160208a0a13eb5e8d7a2cb8094/games/totk/third_party/d2r_gfx/gfx/nvn/totk_mfx.m#L6-L18) uses separate premultiplied UI, camera/depth reprojection and zero screen motion for suspected moving pixels. It supplies no engine-derived actor/weapon animation velocity, so source inspection is not evidence that these quality cases pass there.

Final-source visible-window stress observation (70 seconds; GPU fixture work may overlap, so this is not a controlled performance benchmark): the last 20 seconds recorded 475 real and 393 generated presentation callbacks, with 473 real and 169 generated nonzero presentation times. There were 642 distinct refresh timestamps (32.1/s), intervals p50 33.33 ms and p95 50.00 ms. None of those 169 confirmed generated pictures had a missing or non-earlier preceding real presentation in the log. This single sample is not a universal ordering guarantee and does not pass stable 30+30 acceptance. Use `kept-game.log`, `kept-presented.tsv`, `kept-cadence.json` and `kept-source.json` for the retained source; other candidate prefixes record rejected experiments.

The follow-up fixture passes 187 GPU/image/queue checks plus 6 forced-unsupported checks. Offscreen confirmation times are explicitly modeled for selection tests; they are not evidence of native display cadence. Artifacts and source hashes are retained separately for each candidate under `01007EF00011E000-work/mfx-review2-20261031/`; rejected candidate logs are not final-source evidence. Original saves remain untouched.


**Exclusive-GPU diagnosis (2026-10-31).** [Opt-in stage tracing](../../../../docs/reference/frame-rate.md#frame-generation-diagnostics-separate-queue-waits-and-resize-costs) records CPU configuration/waits, Metal 4 command-buffer timestamps and the exact selected draw/camera signatures. Other agent GPU tests were paused; native runs and fixtures ran sequentially. Artifacts, source hashes and reports are under `01007EF00011E000-work/framegen-diagnosis-20261031/`. Failed title/DLC-menu launches (`base-before`, `profile-fixed`, `base-after`, `clean-dynamic`) have no valid scene samples and are excluded. `clean-base` reached the laboratory with profiling disabled; its early `scene.png` still shows loading, so it is not a gameplay screenshot. `fixed-control/world.png` confirms the loaded laboratory.

- **Dimensions:** dynamic mode selected 1280x720, 1360x765, 1440x810, 1520x855 and 1600x900, all at VS `362679b14007e5cc_b` / FS `48c7debdf038c71c_b`, with a 2336-byte camera block and no depth/camera aspect mismatches. The scene-completion canvas stayed 1920x1080. A fixed `DM_RENDER_SCALE=.9` control selected only 1440x810 with the same shaders/camera and had no steady-state resize or reconfiguration events. Together with the build-gated DRS code documented in `patches.py`, this identifies game dynamic resolution, rather than alternating selected render stages, in these samples.
- **Resize costs:** after an eight-second scene warmup, dynamic mode recorded 78 resize drains and 79 configurations (62 cache hits, 17 new interpolators). Display drain p50/p95 was 8.29/23.87 ms, totaling 696.9 ms; the subsequent generation drain totaled 0.012 ms because the prior wait had already completed that work. Cache-hit motion/depth allocation was 0.47/0.67 ms, totaling 32.1 ms. A new interpolator cost 1.70/3.45 ms to create. Host history-flag clearing is measured separately; it does not measure MetalFX's internal reset cost. This does not support allocation/cache capacity as the dominant measured resize cost.
- **GPU intervals:** all 596 dynamic and 736 fixed counter samples were ordered; their bracket durations did not exceed command-buffer feedback spans. Dynamic p50/p95: submit-to-GPU start 21.37/31.33 ms; composited-UI copy/dependency interval 0.11/0.23 ms; motion 0.30/0.66 ms; previous-depth copy 0.11/0.35 ms; MetalFX interval 15.46/24.54 ms. The whole command-buffer span was 25.29/33.75 ms, with a median 8.06 ms outside the timestamp bracket. Command boundaries include scheduling/dependency waits, not pure execution time; the scene snapshot in the game's command buffer is not covered by these GPU copy counters. Counter tracing splits encoders, so these numbers require an uninstrumented control and cannot be advertised as unchanged production costs.
- **Display:** in each run's final 20 target seconds, the uninstrumented dynamic run reported 29.85 distinct refresh timestamps/s, instrumented dynamic 29.40/s, and instrumented fixed .9 24.60/s. Median/p95 intervals were 33.33/50.00 ms for both dynamic runs and 50.00/50.00 ms for fixed .9. No confirmed generated picture in those windows had a missing or non-earlier preceding real presentation. These single runs with different DRS mixes do not isolate instrumentation overhead or prove universal ordering. Fixing the scene scale did not provide stable 30+30.

The new `make -C dm/gfx/tests GAME=01007EF00011E000 check_t_framegen_motion` launches six isolated camera/object/pan-occlusion controls, reads back the actual motion texture, and reports error against known midpoint/current images. With fresh instances, camera-only midpoint error is 0.000/255; analytic object vectors give 0.000 for a moving foreground and 0.230 for pan plus occlusion (foreground-region error 0.940). The current camera/depth estimator instead writes 0 where the foreground needs -8 pixels, or +8 during the combined pan; its foreground-region midpoint errors are 6.060 and 7.922. This establishes a motion-input limitation on these controlled inputs, not a general inability of MetalFX to interpolate actors.

**Resolved diagnosis: short reset-recovery observation.** The four-frame `t_framegen_motion - -1 -1` control returns the current image after a reset; fresh instances hide that behavior. Extending each continuous sequence to 16 or 64 frames recovers correct camera/analytic-motion interpolation on the same reused instance. Empty independent UI still reproduces the short-window fallback, so composited UI alone does not explain it. This establishes bounded recovery in these controls, not a permanently unusable cached instance. Native recovery duration remains an implementation detail. The adapter sends real history boundaries to MetalFX and keeps feeding continuous real frames; it does not recreate the interpolator to hide the recovery period. The follow-up avoids artificial boundaries caused only by game DRS.

Validation of the diagnostic source: 187 GPU/image/queue checks, 6 unsupported-device checks, six isolated motion processes (127 setup/input checks) and 4 report-tool tests pass. The deliberate shared-instance reproduction fails one positive control; the fresh-instance variant passes. Both changed graphics translation units compile for iPhone without signing or device execution. No resource-cache expansion, lower-resolution interpolation, or separate GPU queue was introduced. Frame generation remains experimental and off by default.


**Stable input grid and object-motion follow-up (2026-10-31 experiment).** The [shared mechanism](../../../../docs/reference/frame-rate.md#dynamic-resolution-repeatedly-resets-frame-generation) now normalizes game DRS depth into one persistent grid. The first grid is bounded by 921,600 samples (1280x720 in the tested 16:9 Docked path). Scene, composited UI and generated output remain 1920x1080. No historical per-size depth images are revived, and no Vision/VideoToolbox dependency, interpolation-color downsampling or second GPU queue was added. At this stage auxiliary texture allocation at the cap was 16,089,088 bytes; full color images and native interpolator allocations are separate.

Production-path controls alternate 256, 192 and 128 square source depths every frame. They check that the interpolator and all auxiliary textures retain identity, every continuous frame produces output, and actual generated pixels retain the camera midpoint. Twelve isolated cases cover horizontal and vertical camera/object/pan-occlusion motion plus analytic vectors. For horizontal moving objects, foreground-region midpoint error falls from the old camera-only 6.060/255 to 0.973; combined pan/occlusion falls from 7.922 to 3.664. Vertical equivalents are 0.978 and 3.669. Camera-only errors remain 0.000. The sampled foreground vectors now have the correct motion axis and sign, but combined motion is still underestimated (about -4.58 rather than analytic -8 pixels). This is a quality improvement on the controls, not exact engine motion or general combat-animation acceptance.

The retained native source is under `framegen-fix-20261031/`: `kept-profiled` and `kept-plain` are sequential visible laboratory runs with a scripted five-second camera turn, copied saves and the current cached shader chain. All five game DRS sizes occur while MetalFX stays at a 1280x720 motion/depth grid. After an eight-second scene warmup, the profiled run has 636 ordered GPU samples, zero counter-envelope mismatches, zero resize drains and zero reconfiguration events. The motion interval including local refinement is p50/p95 1.21/4.83 ms; the MetalFX interval is 17.65/44.08 ms. These command-boundary times include dependencies. A rejected version that refined lighting changes on rigid geometry used 2.14/7.58 ms in its motion interval; rigid depth-reprojection selection reduced that cost.

**Resolved action-speed regression (2026-11-01).** [Real-frame acquire pacing](../../../../docs/reference/frame-rate.md#frame-generation-speeds-up-game-simulation) now retains the game's vsync budget when interpolation is enabled. Before the fix, four controlled 60/120 Hz snapshot-acquire checks failed because no real-frame ticks were waited for; all seven checks pass after it. The existing 29 link-tick checks, 187 MetalFX queue/image checks, six unsupported-device checks and 13 documentation tests pass. The Mac host builds and the changed NVN translation unit compiles for iPhone. A copied laboratory save with `DM_FRAMEGEN=30`, `DM_RENDER_SCALE=0.5` and the existing matching shader cache advanced 71.27 seconds of game time in 71.25 real seconds (1.000 rate); the native process exited cleanly. The output screenshot was inspected. Artifacts are in `01007EF00011E000-work/framegen-speed-20261101/`. This verifies game speed on the Mac, not stable generated-frame delivery or physical iPhone behavior.

**Performance acceptance remains open.** In the last 20 target seconds, `kept-plain` reports 420 confirmed real and 54 generated presentations, 23.70 distinct refresh timestamps/s, with intervals p50/p95 50.00/50.00 ms. `kept-profiled` reports 361 real and 36 generated, 19.85 distinct timestamps/s, with intervals 50.00/100.00 ms. Neither window has an unconfirmed or non-earlier preceding real presentation among confirmed generated pictures. Earlier camera-only samples delivered about 27.65-29.85 distinct timestamps/s. These single runs and different DRS mixes do not isolate causal overhead, but the retained implementation does not pass a performance-improvement or stable 30+30 claim on this M2. Reducing resize stalls and adding object motion have not solved interpolation cost or delivered-picture cadence. Keep the experiment off by default; native UI decomposition and physical iPhone quality remain unaccepted.

Current checks: twelve isolated motion processes pass 558 setup/input/pixel/resource checks; the 16-frame-per-condition reused-instance sequence passes 249; the queue/image fixture passes 187 plus 6 unsupported-device checks. The feature-off allocator and rescue fixtures passed 13 and 49 checks before the final rigid-selection refinement (which only runs with frame generation active). Both changed graphics translation units compile for iPhone, without signing or device execution. Report/document checks are separate from GPU acceptance. Native source hashes, exact control logs, excluded startup/candidate runs, platform optical-flow probes and `display-comparison.json` are retained in the work-folder report. Original saves remain untouched. Full shader/regress validation remains blocked by installed Metal 32023.883 versus the chain's locked 32023.921; this is not a five-game regression pass.


**Feedback snapshot bypass (experimental, current, 2026-11-01).** Performance settings now offer **Skip feedback snapshots (experimental)**, off by default. Turning it on uses the existing `DM_NVN_FB_SNAP=0` path; turning it off restores automatic snapshots (`1`). This is an explicit correctness tradeoff, with no replacement protection. The setting and its saved choice apply on iPhone and Mac; iPhone rendering, sustained frame rate and thermal effects remain unverified. See [same-pass feedback](../../../../docs/reference/rendering.md#same-pass-feedback-read-through-a-snapshot) for the mechanism and [the setting](../../../../docs/settings.md#skip-feedback-snapshots-experimental) for comparison and reset instructions.

**Native widescreen UI backgrounds (2026-10-28).** Widescreen is independent of touch/controller mode. Menu foreground content and touch coordinates retain the centered 16:9 layout; full-width native background Pictures and Windows extend to the display edges. Windows retain their own corner sizes, and title illustrations use proportional cover sizing. Returning to 16:9 restores native dimensions without accumulating scale.

The former viewport squeeze also clipped backgrounds at the 16:9 boundary. The registered ui2d shaders now correct clip x in a replay-time copy of their projection/clip-offset uniforms (Maxwell c3/c13, NVN UBO slots 0/10), before clipping. Guest buffers and shader libraries are unchanged. Main's build-checked `Pane::DrawSelf` scope (OBS39/40, x21 pane) marks background draws; only those draws may keep a full-display scissor. Foreground scissors remain centered, so offscreen neighboring panels cannot leak into the side margins. The tag uses a reserved instance-count bit in host command records, preserving compact draw sizes and decoded instance counts. Rewrite main with the current profile before running a new host.

Validation: aspect/background restoration and menu/HUD regressions pass; 173 NVN recording checks and 147 graphics checks pass. Mac runtime evidence in `widescreen-ui-20261028/` uses the retained `371ad45` graphics base with this change and the shared menu adapter, shader chain `07b0ea547435`, and newly rewritten compatible modules. The current merged host also compiles; this feature's runtime evidence does not validate the complete merged shader chain. Physical iPhone and actual controller connection remain separate acceptance.

**Title background correction (2026-10-29).** `Title_00` also draws two pairs of gradient panels behind its menu. Their native origin is the right edge: the last `FBLayout_02/03` panels end at x=640, rather than extending beyond it. They now widen and move their right edge by the extra half-canvas width; their left seam stays at x=160. The left gradient panels, logo, menu and hit regions retain their native geometry. The exact title ancestry distinguishes these panels from other framebuffer pictures. Visible artwork and its light/blur pictures scale dimensions and position together, including the smaller arrow, horse and guardian pictures. The separate capture branch stays at native size; its displayed effect pictures receive the same layout correction as the visible artwork. This prevents a hard cut at the old left edge or a mismatched stretched glow. Resizing back to 16:9 restores the original width and position. Corrected UI uniform banks are value snapshots and must refresh for each draw; reusing an argument block that originally pointed at live uniforms can otherwise retain stale title artwork/opacity. Mac captures and logs are in `widescreen-title-20261029/`, with the same compatibility-runtime boundary described above.

- **Resolved: the 3D scene black, only particles and the HUD drawn.** The engine binds almost every texture with `nvnCommandBufferBindTexturesDeferred` (`main+0xec2e64`, one handle, the pointer being the handle field inside the texture-sampler object): the GPU reads the handle when the command executes, and the game records its command blocks once and writes the handles afterwards. The host copied them at recording, mostly zeros, so the deferred-lighting composite read the dummy texture 0. The bind record keeps the source address and replay refreshes the handles first (`bh_fresh`). Found with a data-flow table from `DM_NVN_PASSDUMP_ALL`: the composite's `B` lines were all `tid=0 dummy` (without `_ALL` only the first draw of each pass is listed).
- **Resolved: the same texture attached at two colour slots.** The G-buffer passes attach the albedo and another buffer twice each (c1 = c2, c3 = c4) with write mask 0 on the duplicates. On Apple's TBDR the later copy (loaded, never written) overwrote the other's writes, per 32×32 tile: the albedo held only scattered squares. A repeated slot is left unattached (`rt_dup_slot`).
- **Cube textures sampled as cube arrays**: 1,512 shaders sample the environment probes as `texturecube_array` with a single cube bound; NVN cube textures are now 6-layer 2D arrays bound through views (`tex_fit`).
- **Resolved: a compressed texture as a render target (GitHub issue #4, iPhone 14 Pro).** agl's BC4 block encoder (`8e2cc2671cae6020`) writes a 32×32 RGTC1 (BC4) texture through an `RGBA16UI` view (one texel per 8-byte block). Metal can neither attach a compressed format nor view one uncompressed, and pipeline validation aborted, so the draws did nothing. The pass now draws into an uncompressed shadow of blocks × blocks (`bcrt_attach` / `bcrt_flush`, from PR #11); its output is declared `uint` in `shader_facts_manual.tsv`, as is its 2D-source twin `93aa5e22a8202409`, whose failure showed up in an iPhone run. A16 now uses the [GPU BC fallback](../../../../docs/reference/rendering.md#bc-textures-on-gpus-without-bc-support); its raw block render target follows this same shadow path. Physical A16 memory and gameplay acceptance remain pending.
- **Resolved: the sky brownish grey, the distant haze brown (GitHub issue #52, Mac and iPhone).** Each frame a pass (`08fe25061d583637`, `uking_pass_shader.sharcb`) turns a 256×32×16 RGBA16F 3D table of in-scattered light into a 256×256 sky map, which the sky draw (`8110c74078548172`) and the materials' aerial perspective sample. The table and two 2D ones (transmittance 256×64, irradiance 64×64) come from `System/KSys/sky.skybin` in `Pack/Bootup_Graphics.pack` (1,212,416 bytes). The game makes a `CPU_CACHED | GPU_CACHED` pool per texture, creates the textures, copies the data in with `memcpy` and flushes (`main+0x1257d50`, once; the flush goes through `main+0xebf4c4`). The host made the 3D table a GPU texture of zeros. `DM_NVN_TEXRAW=212,214` and `DM_NVN_TEXINFO=256x32` (`storage 1048576 bytes non-zero 781567`, `swizzled=0`) showed it. Every game now fills a texture from storage the game flushed before its first use (`nvn_flushed`, `tex_init_fill`; `DM_NVN_FLUSH_FILL=0` turns it off). In the Great Plateau save it fills that one texture; the flushes (about 15 a frame) merge into about 530 ranges, frame times unchanged.
- **Resolved: dark boxes and cream cloud rectangles behind HUD prompts, a black stamina wheel and a black System menu background (layout captures, GitHub PR #6).** Panes tagged `CaptureOn` (about 140 layouts, e.g. `PaGuideKeySmoke_00`; user data `A8`, `CaptureScale` 0.5, `MultiFilter`) are drawn, blurred at half size and copied into a capture texture that replaces the placeholder `FBLayout_00`. The game creates it with its per-format default mapping (`main+0xecb0bc`: R8 → (R, 0, 0, 1), RG8 → (R, G, 0, 1), …), then rebuilds it on the same storage with the capture's mapping: `main+0xf597dc` picks (1, 1, 1, R) for an `A8` capture and alpha 1 when the pane says `CaptureOutputAlpha` 255 (read at `main+0xf58e98`); `main+0xecacf0` stores the mapping and rebuilds (`main+0xecabe8`), and `main+0xec33f0` replaces the registered descriptor only if `nvnTextureCompare` reports a difference. The host ignored the mapping, so the captures kept (R, 0, 0, 1): hard-edged dark boxes (the shadow pane `e6a88e12dbae9743`) and cream cloud (the glow `aa209f57b133e862`). The earlier `alpha_from_red` workaround (all 26 layout pixel shaders, `main`'s BNSH at 0x1d83000; since removed from the host) fixed the alpha but zeroed green and blue (a black stamina wheel) and left the System menu black. `nvnTextureCompare` now compares the mapping (an unset mapping counting as (R, G, B, A)); checked on the Mac by the PR's author: green stamina, the purple noise meter, the blurred System menu.
- The game keeps NVN's GL depth mode. It has an `RG8_UI2F` vertex attribute (converted on the CPU, `vconv_i2f`). 101 compute and 4 vertex shaders read the driver segment `c0`; they render the same since compute `c0` carries the dispatch size.
- It finalizes its transient render targets before every submit and builds them again the next frame, which the storage-takeover rule guards with a 16-submission window (`alias_take_over`).
- Windowed on the Mac with `present_now`'s residency commit: its title, 60 fps, no GPU error.

**Gameplay edge HUD and loading fills (2026-10-29, resolved on Mac).** The native heart container moves toward the left display edge, preserving the spacing of full and partial hearts. The collapsed minimap and its sensor, noise, temperature, time and weather panes move together toward the right edge. Touch mode retains its upper-right map layout; ordinary input retains the lower-right layout. Hearts retain native padding against the full display; the map cluster uses its authored right-corner padding independently of input mode. Touch map bounds and the adjacent plus/minus buttons use the same HUD rectangle. Expanding the Slate restores its native centered position; returning to 16:9 restores all original positions without accumulating offsets. The HUD draw scope fixes [target-clamped scissors](../../../../docs/reference/rendering.md#edge-anchored-ui-keeps-open-scissor-edges) without opening menu clips.

**Narrow displays and optional portrait controls (2026-10-31).** Below 16:9,
hearts and the collapsed minimap/environment group use the top corners, in
both touch and controller modes. Their readable size follows the display's
shorter edge. Native pane transforms keep artwork, scissors, map capture and
touch bounds together; opening the Slate restores the original menu geometry.
The loading screen's cream and black fills extend vertically. Other menu
foregrounds retain their centered 16:9 proportions. Returning to 16:9 or wider
restores the existing HUD transforms.

**Game Over background on narrow displays (2026-11-04).** `GameOver_00`'s
`RootPane/N_In_00/P_BG_00` is a separate 1280x720 background Picture. The narrow
display draw scope previously extended only Fade's fills, so the menu projection
also confined this black background to the centered 16:9 strip. Full-canvas
background leaves now use the existing fullscreen-fill draw scope on narrow
displays. Lettering, its capture/glow pictures, buttons and title illustrations
retain their original proportions. The aspect fixture passes for 4:3, square,
portrait, 16:9 and wide draw scopes, including foreground/container exclusions.
The BOTW-only `regress.py check --games 01007EF00011E000 --no-smoke` attempt
stops on the baseline's existing Metal compiler mismatch (32023.883 installed,
32023.922 locked); its report is in `gameover-fill-20261104/regress/` in the
game work folder. Gameplay and physical-device appearance remain unverified.

The current-rune Picture has a separate capture draw tag, which takes priority
over its equipment group's HUD tag. On narrow displays it must share that
group's native transform: applying the centered-menu viewport correction again
flattened the rune and moved it away from the D-pad. The rune capture tag now
uses the same narrow HUD viewport, while wider displays retain their correction.

The weather component's animated current-weather pictures do not inherit model
scale in the same way as its flat forecast icons and background. Applying the
narrow HUD's nonuniform scale to `Pa_Weather_00` stretched the current rain into
a tall streak; even a uniform parent scale left the animated icon too small.
The component now retains its native model geometry. Its draw scope applies
both display-axis corrections to a replay-time projection copy, after the
animation, before clipping. Its relocation delta uses those same scales, keeping
the weather aligned with the other environment gauges. Guest uniforms and shader
libraries are unchanged; 16:9 and wider retain their existing behavior.
Mac gameplay verifies the rain, sun and cloud pictures in portrait and 4:3;
native aspect/HUD fixtures, 189 NVN recording checks, 192 graphics checks and
188 iOS source checks pass. Evidence is in `portrait-live-20261031/` and
`weather-*-20261031.log` in the game work folder. Physical iPhone acceptance
remains pending; the full shader regression has the compiler-version limitation
described below.

The BOTW touch editor's **Enable compact portrait mode** switch (`DM_BOTW_PORTRAIT`,
off by default) permits upright iOS gameplay below 600pt of usable width.
Wider upright windows always allow portrait rotation, including unfolded Duo
and iPad windows of that size. Permission uses the same compact-layout predicate
as the controls; the application and game view controller share that decision, and
motion follows the actual interface orientation even with the switch off.
The [Duo inner display may ignore supported orientations](https://developer.apple.com/videos/play/tech-talks/111461/),
so system-driven resizing still selects a layout from actual window geometry.
The compact touch profile is used
only when the display is taller than it is wide and its width after left/right
safe insets is below 600pt. At 600pt or wider, portrait uses the normal profile;
landscape always retains the normal profile. Compact L sits at the bottom-left
safe-area corner with 10pt left/bottom margins; the D-pad sits to its right at
the same center height, with a 15pt gap between their edges.
In compact mode, the D-pad's grab region takes touch-down priority over the
floating movement stick on both iOS and the Mac preview.
L and the D-pad have default diameters
6pt smaller than their original compact sizes. The movement stick is shifted
another 40pt up; ZL is raised 20pt. The right buttons are 200pt below their previous homes,
with Y/X lowered another 15pt and ZR/R raised 5pt: ZR takes the former R horizontal position and R sits
directly above it, with the standard shoulder gap. All six right buttons are
shifted another 3pt right. Y/X occupy the next row and B/A the bottom row; Y and
B have an additional 10pt right shift. Y's default diameter is 10pt larger than X; A and B are
10pt smaller than X. Each compact face button has its own position
and size in the touch editor (`DM_BOTW_PORTRAIT_PAD_A_*`, `_B_*`, `_X_*`, `_Y_*`).
The removed compact `FACE_*` group settings are not migrated; adjust individual
buttons in the editor instead. Normal and compact previews each edit, reset
and export their own layout and movement response;
compact keys retain the `DM_BOTW_PORTRAIT_PAD_` and `DM_BOTW_PORTRAIT_MOVE_`
prefixes. The frontend publishes the selected profile's native D-pad size with
its position, so the equipment artwork stays consistent in wide portrait too.
Resizing releases held touch input before switching
profiles. The launcher remains landscape, physical controllers retain their
input behavior, and other games do not offer these settings or orientations.

Validation: native geometry covers 320x568, 390x844, 430x932 and 768x1024;
aspect tests cover readable 4:3/9:16 HUD geometry and restoration; the UIKit
handler harness passes 39 look sessions, including portrait face hits,
camera/button multitouch, rotation release, gyro basis and controller hiding.
The 600pt update adds 599/600/626/744pt selection, horizontal safe-inset and
native D-pad scale checks; these pass in the native and UIKit harnesses.
Mac gameplay also verifies a 390pt compact portrait window widening to 626pt
with normal controls, then shrinking back; the rune and D-pad remain aligned.
Independent setting persistence/reset/export, the full host suite, 184 GPU
present checks, 188 iOS source checks and an unsigned iOS smoke build pass.
The BOTW-only shader regression stops at the local compiler check:
Metal `32023.883` differs from the pinned `32023.921`. This is separate from
the live Mac test, which reuses the prepared `715bb867230c` shader cache with
the current host. Mac gameplay verifies the readable portrait/4:3 top HUD,
minimap tap, native Back, loading fill and a portrait/landscape/portrait
round trip. The test runs from a copy of the user's save. Evidence is in `portrait-*-20261031/` and
`portrait-live-20261031/` in the game work folder. Physical iPhone rotation
and safe-area acceptance remain pending.

**Duo startup orientation (2026-11-04, implemented; device acceptance pending).**
The reported portrait clipping and camera-end-dependent inversion already occur
in the launcher. UIKit now owns presentation orientation, and the launcher
uses the existing shared host. The single scene policy is described in
[Duo startup orientation uses the current scene](../../../../docs/reference/rendering.md#duo-startup-orientation-uses-the-current-scene).
The policy fixture, iPhone Objective-C syntax checks and iOS Swift typechecks
pass. BOTW-only static shader regression passes with 19,592 shaders and no
shader/interface changes; its report is in `duo-standard-20261104/regress/` in
the game work folder. Physical Duo launch in both directions and Seated
transitions still require acceptance; no game rendering flip was added.

**iPhone Duo window and Seated layout (2026-10-31).** Following
[Apple's Duo guidance](https://developer.apple.com/documentation/technologyoverviews/preparing-your-app-for-iphone-duo),
the iOS surface reads UIKit's active `divisionRegionKind` reserved regions during `updateConstraints`,
so a fold change is observed even when the window bounds stay unchanged. A
horizontal division puts the game picture and native menus above the fold;
the lower pane contains the touch pad and, while the native map is visible,
the minimap/environment cluster at its top with an 8pt margin. The touch pad
remains available in menus in Seated mode; direct menu touch stays in the upper
pane. Connected controllers still hide the virtual pad. Vertical/book folds
retain the existing whole-window layout. Fixed picture aspects fit inside the
upper pane without letterboxing or shrinking the lower controls.

The game composites its scene opaquely into its UI canvas and caches menu and
3D-character pictures there. Keep those game-owned targets in native coordinates:
scaling them internally causes repeated cropping and duplicate character pictures.
Only the final canvas-to-swapchain copy and later swapchain draws fit the upper
picture region. Existing native map, weather, gauge and touch-equipment draw scopes
instead draw to a transparent host target, composited into the lower pane before
the ordinary snapshot/present path. The map's native framebuffer blur reads that
same target. Adjacent dock draws share a render pass; native target changes,
clears and other draws close it. Shader libraries and the translation chain
are unchanged. Hearts remain with the upper picture; controller equipment keeps
its original layout.

Window-size, safe-inset, orientation and fold changes release virtual input before
relayout, without clearing a physical controller. Cancelled menu fingers retain
ownership until lift, preventing a resize from becoming a new tap or pinch.
Display scale comes from the current view traits; Metal drawables, text and icon
layers refresh after display changes. Compact/normal selection follows the usable
control pane's geometry and the existing 600pt boundary, independently of the
compact portrait rotation-permission switch. The touch editor stacks its preview and
settings in narrow windows. Core Motion's view-relative samples retain their
single conversion to Switch axes, with a fixture covering all four orientations.

Validation: native geometry/aspect/HUD fixtures, 191 NVN recording checks,
201 real-Metal graphics checks, 188 iOS source checks and the SwiftUI/settings
storage check pass. The UIKit harness passes 40 look sessions, including fold
input cancellation, persistent lower menu buttons, upper menu pointers and
controller isolation. The current Mac host with prepared `715bb867230c` shaders
verifies gameplay, top-of-lower-pane minimap hits, inventory categories, the
complete inventory character/background, native Back, lower A/B, and
Seated/whole-window/Seated restoration. Tests use a copied save; evidence and
the regression report are in `duo-adaptation-20261031/` in the game work folder.
The BOTW-only `regress.py check --quick` is **ERROR**, blocked before shader
comparison by Metal `32023.883` versus pinned `32023.921`; other games are not
runtime-checked because this region/draw routing is BOTW-only. Local SDK 26.5
checks exclude the new 27.1 APIs; a separate syntax check with Apple's declarations
is not an SDK build. Building with iOS 27.1 and physical Duo display/fold/gyro
acceptance remain pending on the user's other machine. The reserved-region path
uses both SDK and runtime availability guards; older systems keep existing behavior.

Integration with main `a97cb376`: 190 iOS source files and the aspect/HUD
fixtures pass. The geometry fixture's original portrait minimum-spacing assertion
fails identically on that main revision and the merge after main's compact-spacing
change; this integration preserves the new positions rather than changing that
unrelated layout. No GPU tests were repeated during the exclusive measurement pause.

**Seated reflection and compact portrait permission (2026-11-01).** BOTW Seated
adds a decorative reflection behind the lower HUD and controls, following the
[low-resolution frame reuse approach](https://www.mux.com/blog/what-the-iphone-duo-means-for-web-development).
The final upper picture is downsampled into two private RGBA16F textures, at most
256 pixels on their longer side and sized by the displayed aspect. Horizontal
and vertical Gaussian passes use 18 bilinear samples each to smooth the small
image before enlargement; the last pass mirrors it, dims linear light to 40%
below the fold and fades toward the bottom. The fold center is the mirror
axis. Its reserved band gets a soft
background transition, while content and touch geometry still avoid it. A
pixel-aligned scissor keeps the background from spilling into the upper picture.
The native lower HUD composites afterward; virtual controls remain a separate
frontend layer. No input regions, button layout, other game or non-Seated
rendering path changes. Scratch images retire behind the existing submission
fence; there is no CPU readback, duplicate scene or translation-chain change.

Initial quality trial (2026-11-05): reducing the scratch size from 384 to 256 also
reduces Gaussian sigma from 6 to 4 and support from +/-18 to +/-12 texels,
preserving the displayed blur radius. RGBA16F precision and update cadence
are unchanged. All 330 real-Metal present checks pass; frame-time and device
thermal improvements have not been measured. Current-checkout Mac Seated
gameplay with cached game shaders produced the preview in the external game
work folder's `seated-blur-256-20261105/`; visual acceptance is pending.

Quality can be adjusted with `DM_SEATED_REFLECTION_SIZE` (longest side,
64..1024 pixels; default 256) and `DM_SEATED_REFLECTION_SAMPLES` (sample
count per axis, 5..33; default 18). They are read on first use; restart the game
after changing them. The host calculates Gaussian weights once and scales
sample offsets to retain the displayed blur radius. `384` / `19` reproduces
the earlier quality; `192` / `9` is a lighter option. Invalid values log the
fallback and use the corresponding default. Neither option changes game
shader libraries or the translation chain.

The default was increased to 18 samples per axis after the initial 13-sample
preview. Even counts use symmetric half-texel Gaussian positions and omit the
center sample; odd counts retain it. The count names actual texture reads per
axis, including the center when present.

GPU measurement (2026-11-05): current-checkout Mac gameplay on Apple M2,
handheld mode, 30 fps, frame generation off, 640x448pt Seated window and
256x88 RGBA16F intermediates, with 18 reads per blur axis. The existing
`DM_NVN_GPUPROF=every:30` counter heap sampled 30 steady frames from 2100
through 2970. The other running test game was paused during sampling and
resumed immediately afterward. The four consecutive reflection encoders were
identified by their shared pass number, three 256x88 RGBA16F destinations,
then the native sRGB destination. Mean GPU durations: downsample 0.02786 ms,
horizontal blur 0.02685 ms, vertical blur 0.02646 ms, composite 0.03090 ms;
their sum is 0.11207 ms. First reflection start to last reflection end,
including gaps, averages 0.13866 ms (median 0.14235, p95 0.14980, maximum
0.15350). These are measured GPU spans, not an on/off whole-frame performance
comparison or an iPhone result. All 330 present checks pass with the new
default; the 13-sample path and invalid-value fallback each pass 133 focused
checks. Raw logs, screenshot, `reflection-times.csv` and `measurement.json`
are in the external game work folder's `seated-reflection-18-20261105/`.

Downsample follow-up (2026-11-05): the small-image copy now uses a cached
compute pipeline instead of a render pass. It retains the same bilinear
sample, source crop, edge clamp, sRGB decode and RGBA16F intermediate, with
the 18-sample Gaussian passes unchanged. A direct GPU comparison of cropped
copies, including 1x1 and partial-threadgroup destinations, and the present
fixtures pass all 334 checks. Current-checkout Mac gameplay uses cached game
shaders. In a second 30-frame isolated sample on the same M2 and layout,
frames 7080..7950, mean downsample time is 0.01316 ms (p95 0.01396), versus
the prior render copy's 0.02786 ms. The entire reflection span averages
0.13265 ms (p95 0.13743); the runs are separate measurements, not a paired
whole-frame benchmark. Both other test games were temporarily paused for
this sample and restored. Raw logs, screenshot, `reflection-times.csv` and
`measurement.json` are in `seated-compute-downsample-20261105/` in the
external game work folder. The translation chain is unchanged.

Validation: 285 real-Metal checks pass, including 88 focused Seated checks under
Metal validation (both origins, fixed-aspect side bars, short lower panes,
zero-width folds, unchanged upper pixels, smooth source grain and sharp HUD
overlays). The portrait-permission fixture covers both orientations, safe insets
and the 600pt boundary. The 191 NVN checks, 190 iOS source checks, 21 settings
tests and Swift storage check pass. UIKit verifies portrait motion with the
compact switch off and fold/controller input isolation; its full run still
reports three old compact-position assertions after main's layout changes.
Mac `run_mac.py --test` verifies gameplay, minimap/plus hits, lower A/B in menus
and Seated/whole-window restoration with deferred Metal encoding. GPU timings
are recorded for the four reflection passes; device thermal impact remains
unmeasured. Logs and the blocked
shader regression report are in `seated-reflection-20261101/` in the external
game work folder. Full Metal validation also encounters a native zero-work
compute dispatch; focused reflection validation is clean. The pinned compiler
and physical Duo/iOS 27.1 acceptance limits described above still apply.

**Resolved: minimap disappeared in very wide windows (2026-10-29).**
The D-pad center is published relative to the centered 16:9 UI canvas. At 32:9,
its valid position beside that canvas has a negative normalized x. Rejecting
coordinates outside `[0,1]` disabled the entire touch HUD, restored the native
map placement and removed its touch target. Publication now accepts finite
coordinates outside that centered canvas; it still rejects nonfinite values.
That fixes touch-HUD activation; the separate native scissor rejection is fixed
by [anchoring the collapsed map after CPU clipping](../../../../docs/reference/rendering.md#edge-anchored-ui-keeps-open-scissor-edges).
Native checks cover the negative D-pad position, valid map hits at 32:9 and
inactive restoration. Mac 3.6:1 gameplay verifies the complete touch minimap,
click-to-open Slate, Back and resizing to 16:9 and back. There are 178 passing
recording checks and 160 passing graphics checks, including safe-edge clips.
Evidence is in `ultrawide-minimap-20261029/`. Gameplay uses the retained graphics
base and matching shaders; the current merged host compiles separately.
Physical iPhone acceptance remains pending.

**Resolved: minimap blur flashed adjacent HUD after Inventory (2026-10-30).**
The return animation copies a 192x192 region of the UI framebuffer for its
blur. The collapsed map had moved at GPU replay for widescreen, but this
capture still sampled its old native rectangle, including temperature/noise
graphics. The copy shader `17dccd27ad609e8b` now receives a replay-time UV
snapshot following that same map projection. A recorded map draw must match
the current frame, source canvas and clipped source rectangle; full-frame,
unrelated-menu and 16:9 copies keep their original uniforms. Capture projection
also participates in the argument-cache identity, so an ordinary copy cannot
reuse its corrected snapshot. Guest uniforms and shader libraries are unchanged.
The before/after texture dumps locate the contamination before blur; eight
21:10 return frames show the corrected map. All 168 graphics checks pass,
including source-edge alignment and unchanged unrelated copies. Evidence is in
`minimap-album-compendium-20261030/` (`probe-contact.png`, `fixed-contact.png`).
Mac gameplay uses the retained compatible graphics base; the complete current
host compiles separately. Full regression preparation stops on the unchanged
HEAD baseline Metal compiler/lock mismatch. Physical iPhone remains unverified.

The loading screen's upper cream background is `P_Capture_00` under `N_LogoInOut_00`, a 1280x275 panel with an animated projected texture. Its complete native draw now stretches with the display, preserving texture/clip alignment throughout the wipe; see [Projected fullscreen fills](../../../../docs/reference/rendering.md#projected-fullscreen-fills-keep-texture-and-clip-coordinates-together). Text, status icons and logo keep their proportions. The lower black background already uses the full-display background path. Both fill a wide display.

Validation: Mac 21:10 touch and ordinary-input gameplay, map expansion/return, edge-area map/plus taps, and resizing to 16:9 and back passed. Aspect/safe-area/restoration and touch-HUD checks pass, with 176 NVN recording checks, 155 graphics checks and zero UIKit handler failures. Evidence is in `widescreen-hud-loading-20261029/` in the NSP work folder. Runtime captures use the retained graphics base and shader chain described above; the current merged host compiles. `regress.py check --games 01007EF00011E000` stops before boot on the existing translator `xlate_source` lock mismatch, including its HEAD baseline. No shader-chain tools changed. Physical iPhone and an actual connected controller remain unverified.

#### Upscaling (current)

Handheld, the game draws 1280x720 into its 1920x1080 window textures and crops the window to it. Docked it scales its 900p scene to 1080p with one draw and draws the HUD on the 1080p target. The optional [MetalFX present](../../../../docs/reference/rendering.md#the-present-upscales-through-metalfx) scales that presented picture in either mode; it cannot recover detail lost in the game's own upscale.

Measurements reported in [PR #215](https://github.com/seedds/nxnative/pull/215), the present command buffer's GPU time:

| Device and content → output | MetalFX | Standard |
|---|---|---|
| M2 Max, handheld 1280x720 → 2560x1440, full screen | 0.74–1.32 ms | 0.07–0.11 ms |
| M2 Max, docked 1920x1080 → 2560x1440, full screen | 1.35 ms | 0.11 ms |
| M2 Max, 1280x720 → 2868x1320, offscreen | 0.40–1.17 ms | 0.04–0.07 ms |
| iPhone 17 Pro Max, docked 1920x1080 → 2346x1320 | p50 2.1–5.0 ms per 600 presents; p95 up to 6.1 ms | Not measured on that build |

On the Mac, frame times stayed at 60 fps; crop comparisons showed sharper edges on Link, his shield and the map text, with unchanged colours. The iPhone ran at 60 fps with the launcher setting reaching the host; a cold docked run reached thermal state serious after 226 s, a warm start after 64 s. The matching iPhone Standard run and MetalFX's share of the thermal cost remain unmeasured. Standard stays the default. These gameplay measurements are the PR author's; this integration has not repeated a device gameplay run.


### Screen shape (`DM_SCREEN_ASPECT`, current)

The native-aspect layout owns display geometry in this fork. It uses the original game canvas and adapts the camera, UI and Seated panes to the actual display. The legacy *Picture shape* choice is hidden, and saved or explicit `DM_SCREEN_ASPECT` values do not enable taller-canvas patches while native aspect is active. Combining both paths flattened Seated pictures and the minimap; see [Native and legacy aspect correction are exclusive](../../../../docs/reference/rendering.md#native-and-legacy-aspect-correction-are-exclusive). The taller-canvas path below remains available with `DM_ASPECT=0`; its observations are upstream validation.

A screen taller than 16:9 (the iPhone Duo's, about 1.43:1) gets a picture of its own shape instead of a stretched or letterboxed 16:9 one. `DM_SCREEN_ASPECT=1.43` (launcher setting *Picture shape*, offered because the profile has `screen_aspect on`) makes the host give the game a 1920x1344 output and a 1280x896 layout space (`loader.c`, state +0x48..+0x9c); the stubs in `patches.py` and `duo_anchor.c` make the game follow it:

- **The view.** `sead::PerspectiveProjection` takes a vertical angle of 2 atan(tan(fovy/2) x k), k = (16/9) / ratio, and stores it, so 16:9's sides stay in view with more above and below; the camera's fovy getters and `doUpdateMatrix` follow (with only sin / cos / tan widened, shadow cascades and culling used the narrow angle and the ground went black in patches). The HUD camera takes the screen's ratio.
- **The HUD and menus** (`duo_calc` in `Pane::Calculate`, `main+0x27ae0`). A widget at the 720 space's top or bottom edge, or one of a list of edge-anchored widgets generated from the layout files (the dialog box, subtitles, location and boss names, the loading logo, the map's clock and sensor icon; 95 name-and-place conditions, none matching another layout's widget there), moves out by the extra half-height with its children. Full-screen backgrounds stretch; the Sheikah Slate's page frames grow by the shift at both ends (once: the grown size carries a 1/1024 mark); side masks as tall as the screen band (the scope's circle) scale about the centre so circles stay round, except the title menu's backing (`FBLayout_00`..`03`, two 480x720 halves side by side), which is stretched like a middle panel so its two halves still meet (scaled, the right half's inner edge had moved out by 39 units and left a bright band); full-width panels under the title or guide rows are carried on to the edge; the title screen's art scales without stretching. The map's cut-outs (wider than the screen) keep their scrolling contents as they are.
- **Captures and copies.** Full-screen captures are made as tall as the screen, and the copied rect and the texture follow the layout height (`main+0xf5a0dc`, `main+0xf5a4b8`, and the same code's copy in the other capture class, `main+0xf66118`, `main+0xf66334`: the dialog box's blurred backing, a copy of the screen behind the box, read the layout file's 720 and copied a rect 88 units below the moved box, so the part of the box below the 720 space's bottom edge showed black from beyond the screen's edge); textures projected fitted to the layout (the menus' blurred background) map the whole taller height (`main+0x2df28`); the map's footprint trail keeps its projection at the 720 pane's height (`main+0x127a2f8`); the camera rune's photo takes the screen's middle 16:9 band instead of the whole screen squeezed into its 854x480 picture (`main+0xf75ba4`).

Checked on a Mac (M-series, macOS 27, headless with a Master Mode save) against the same routes at 16:9: the map and footprint mode at four zoom levels (every region of the trail at 0 offset), the inventory, system and options pages, the album and compendium, the weapon wheels, the scope (zoomed), the camera rune with its shutter and save prompt, a memory cutscene with subtitles, the Adventure Log, the map's sensor settings, fast travel, loading screens and a shrine. A photo taken at 1.43 now matches the 16:9 photo at scale 1.0 (it needed a 1.24 stretch). An NPC's dialog box (Kakariko Village, a save of an iPhone Duo player standing by an NPC) was checked on the Mac at 1.43 after the dark band at its bottom was reported from the phone: the box is now as dark below the 720 space's edge as above it, and the blurred scene in it lines up with the scene around it. Earlier builds of this ran on an iPhone Duo (iOS 27.1). Not seen in game: shops (their layouts were checked against the rules only) and a compendium registration photo. The taller picture renders about a quarter more pixels.
