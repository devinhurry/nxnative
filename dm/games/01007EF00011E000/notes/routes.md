# BOTW Mac routes

## Mac routes

#### Upstream integration and performance discussion audit (2026-11-01)

Integrated upstream `0e16e0e0` while retaining this fork's native touch adapters,
Seated layout, BC fallback, resource imports and optional memory/resolution modes.
The ordinary defaults, with low-memory mode off, already implement the useful
paths discussed in [issue #159](https://github.com/seedds/nxnative/issues/159):
present snapshots and Metal 4 pipelines, preparation before play and offline
archives, early GPU-fence wake-up, layered cube filtering and compute hoisting.
The encode thread remains on for iOS and off for Mac. The optional low-memory
preset deliberately disables whole-game prebuilding and the bundled offline
archive for a smaller working set, so it is not the performance baseline of #159.
See [GPU work](performance.md#gpu-work), [Pipelines on a cold start](shaders.md#pipelines-on-a-cold-start)
and [Experimental resolution and scene upscaling](performance.md#experimental-resolution-and-scene-upscaling)
for their mechanisms, measurements and validation limits.

The new upstream command-record compaction, shared host-shader precompilation,
per-key warm-load coalescing and completion-object release fixes are included.
No new BOTW FPS gain is claimed from this integration. The discussion's rejected
TBDR/kernel-pass/barrier/fast-math experiments and parked CPU/GPU pipelining are
not enabled: the author reported no benefit or worse tail latency. MetalFX stays
optional because its own GPU cost can shorten sustained 60 fps play.

[PR #76](https://github.com/seedds/nxnative/pull/76) remains open and is not part of
this merge. It adds variable game steps above 60 fps and larger Mac render pools
and heaps, rather than making an existing frame cheaper; its iPhone 60+ path is
unvalidated. [PR #303](https://github.com/seedds/nxnative/pull/303) measures pool
occupancy and is a diagnostic, not a speed improvement. Neither changes this
fork's tested 30/60 fps launcher choices.

Validation: the Mac host build, full host and graphics suites, 953 Python tool
tests (17 optional skips), 167 shader-tool tests (7 optional skips), 53 iOS tool
tests and the 192-file iOS source compile pass. Python lint passes in a clean
Python 3.14 environment with the pinned CI
requirements and no baseline growth. C lint is not qualified: the installed
clang-tidy is LLVM 19.1.2, versus the baseline's LLVM 23.1.4; its partial run was
stopped without changing the baseline. The full BOTW regression selected the
only locally prepared game and stopped during baseline shader preparation:
installed Metal `32023.883` does not match the lock's `32023.921.6`. No compiler
override, older graphics runtime or physical-device result is substituted.
The report is `upstream-merge-20261101/regress/report.md` in the game's work folder.
Other games and physical iPhone/TV behavior remain unverified by this integration.

#### Upstream integration (2026-10-30)

Merged upstream `ee6648cb`, preserving the BOTW touch adapters and their separate
physical-controller input path. Movement-stick feedback and camera-area R3
double-tap feedback are disabled; the input actions remain unchanged. The iOS
compile check passes all 188 files, the UIKit harness has zero failures, the HID
suite passes 148 checks, and the native touch-menu and trigger-action tests pass.
The focused Python packing, patch, chain, coverage and documentation tests pass.

The game regression selects BOTW, the only local Mac game build, because the
touch behavior is BOTW-only. It stops before comparison: the installed Metal
compiler is `32023.883`, while the shader lock requires `32023.921`. No compiler
bypass was used. The report is
`ui-coverage-20261030/upstream-merge-regress/report.md` in the game's work folder;
this merge has not been validated by a full game run with newly built shaders.


#### The regression route (2026-10-29, current)

`smoke.tsv` takes the outdoors save (`saves/outdoors` in the NSP folder) with frame-numbered presses, `f300:A` to `f1700:A`; the Zora's Domain save it used before is no longer on the test Mac. Link stands in a field from about 50 s; with the window on screen (M4 Pro) frame 3,000 comes at 57 s and 6,000 at 107 s, while a covered window runs at 20 fps ([covered windows](../../../../docs/reference/frame-rate.md)). `regress.py capture` records frame 5000 for `regress.py replay`: noise up to about 150 pixels with 5d2bf73f; one capture at chain `a31235713eee` differed from every replay in 1,603 pixels, a rare live outcome of the depth-EQUAL variation (Frame capture and replay, under Open); later captures replay within 0 to 246 pixels. The current one (chain `f3ceca86cac5`, 2026-10-30): no replay of 8 equals the live frame, noise 122 pixels; 4 of 8 and 113 pixels in the one before. In 2 of 6 `regress.py check` runs on 2026-10-29 the game stayed at 20 fps from the start (frame 2500 not reached by 60 s: NEW-FAIL): the frame step went from 1 to 3 vsyncs at presents 12–15 on three late frames costing 0.02 vsyncs and never came back. Resolved (2026-10-30): the window was behind another one in those runs ([a game window another process starts opens behind other windows](../../../../docs/reference/frame-rate.md#a-game-window-another-process-starts-opens-behind-other-windows)); every 20 fps run of 2026-10-28 and 29 had 21 to 115 display link stalls, the 60 fps runs 0 to 7. With `DM_WINDOW_TOP` the window stays in front.

#### Layered-clear validation (2026-11-01)

The [layered render-target clear correction](../../../../docs/reference/rendering.md#clears-of-layered-render-targets-in-a-pass-that-is-not-layered) from #808 passed the full 110-second outdoors route against `4a1f6830`: 19,592 shaders on both revisions, no new shader or interface failures, matching screenshots, and no red diagnostics. Baseline → candidate: 6,241 → 6,239 frames, 58.4 → 58.0 fps, frame p99 33.56 → 33.52 ms, peak footprint 3,981 → 4,006 MB. The candidate window was kept active during this completed comparison; the shared compiler qualification is in the reference entry.

An earlier candidate run missed frame 2,500 at 60 seconds after CPU-side stalls, including a 5.8-second frame with 5.7 ms of recorded GPU work and no pipeline or texture upload work. The unchanged candidate then reached 3,456 frames by 60 seconds in a startup control. The cause of that initial stall was not isolated. Another full repeat passed its frame gate and timing checks but lost its requested screenshots after focus loss; the active-window comparison above passed every check. The original logs and unsuccessful repeats remain in the game's work folder.

#### Final synchronization and pass validation (2026-10-26, current)

#158 and #213 with the review fixes, on base `c6c4fac`, were tested in outdoor gameplay on a Mac M4 Pro, macOS 27.0.1, at the supported 60 fps target and docked 1600x900 rendering. The supplied outdoor save was copied into an isolated seed; each run copied that seed again. The modules were regenerated with that rewriter, and all 19,592 Mac shaders rebuilt for chain `8393d85a4eae`. Every measured run used one retained host binary and the same source/save hashes. No game or graphics code changed during measurement.

The primary comparison ran **off / on / on / off**: all three switches (`DM_NVN_FAST_WAKE`, `DM_NVN_SLICE_MERGE`, `DM_NVN_CS_HOIST`) at 0 or 1, with encoding thread and present snapshots both 1, cut 64, silent audio, and one shared warmed pipeline archive. Each run reached frame 6,000; the measured window was frames 3,001-5,700 (2,700 frames), including a stationary interval, camera turn, walking and a jump. The windows had no new shader loads or pipelines. Values below average the two runs' means, except the p95 row, which gives the two runs separately:

| Metric | Off | On |
|---|---:|---:|
| Frame interval mean | 16.667 ms | 16.673 ms |
| GPU time mean | 7.051 ms | 7.144 ms |
| GPU time p95, each run | 11.155 / 11.782 ms | 11.708 / 12.018 ms |
| Submission CPU mean | 3.456 ms | 3.653 ms |
| Render passes per frame | 158.55 | 146.94 |

**Result:** pass savings survive (about 7.3%), but these runs do not demonstrate a frame/GPU timing speedup. Submission CPU cost rose about 0.20 ms (5.7%). Both pass optimizations activated; a typical 300-frame on window recorded 2,280 merged passes/layer continuations and roughly 1,400-1,800 moved dispatches. Separate stationary and post-movement windows also showed no consistent GPU win.

Single-switch follow-ups, plus another off baseline, gave GPU means of 6.963 ms (wake only), 7.518 ms (slice only), 6.977 ms (hoist only), and 6.970 ms (off). Hoist-only submission CPU was 3.645 ms versus 3.432 ms off. These are single runs, with a few library/pipeline events in the wake/hoist windows, so they are attribution checks rather than repeated timing proof. A further **direct-encoding, snapshots-off** pair gave GPU means 7.331 → 7.199 ms and submission CPU 4.630 → 4.864 ms, both still 60 fps. Blocking SyncWaits were rare in these 60 fps scenes; sparse diagnostic windows showed wake delay 0.090 → 0.064 ms, insufficient to confirm the original GPU-bound wake gain. Segment publishing remained enabled throughout: it has no runtime off switch.

All ten measured BotW runs exited cleanly, with no red line or crash. Screenshots in both modes showed the outdoor scene and the changed camera/character position without an obvious rendering regression. Wind, animation and second-based input holds cause nonzero image differences, including between repeated runs in the same mode; these are not bit-exact pixel checks. GPU clocks were not fixed. This does **not** reproduce the earlier M2 Max/Zora's Domain/120 fps workload or establish its reported gains, and it is not an iPhone test.

Artifacts in the NSP work folder: `run/perf-final-gameplay-20261026/`, with `summary.json`, per-run `run.json`, `source.json`, `frames.tsv`, `host.log`, `analysis*.json`, screenshots, seed, rewritten modules, retained host and reproduction scripts. The earlier DLC-menu and shrine pilots are excluded from the timing comparison. The general correctness changes are linked under “Found on this game”.

Before publishing, the fixes were integrated with main's pipeline archive and GPU profiling changes (`7753b7b`). The full graphics suite, 37 ordering checks in three encoding/switch modes, 8 CPU completion checks under TSAN, 52 bundle / 57 archive checks, 28 profiler checks, both game host builds, documentation checks and all 133 iOS source compiles passed. Two additional on/off frame-loop checks reached frame 5,000 and exited without a red line or crash. Their display link stalled and dropped frames, and the requested screenshots were not produced; they are execution checks only, excluded from the gameplay/timing evidence above. Their source identities, hosts, saves and logs are retained separately in `run/perf-main-integration-20261026/`. Main's subsequent `dac7ba6` changes the rewriter's Taiko matcher, not these host sources.

#### Routes

- From the title menu into the autosave: `DM_KEYS=f2500:A,f2800:A,f3100:A,f3400:A` (control at frame ~3900).
- For the copied outdoor save with the downloaded-DLC notices: `DM_KEYS=f300:A,f500:A,f700:A,f900:A,f1100:B,f1300:A,f1500:A,f1700:A`; gameplay is visible by frame 2,600. The measured route adds `f4100:RRight~0.15,f4250:LUp~0.4,f4400:X~0.15,f4600:LDown~0.4`.
- The frame step under load: `DM_TEST_PRESENT_LAG=1,12` (12 ms added to every frame: 30 fps at 1.000 of real time).
