# MetalFX frame-generation completion

Scope: finish the five missing features identified against MacNativeGames
`92ec79bd10c006e1cb7ca32d7ac1d8f66c758a15`, on `expriment`.
The user requested functional correctness only: no performance benchmarks,
frame-rate comparisons or further performance acceptance runs.

Code status: all five requested features are implemented and reviewed.
The user authorized committing and pushing this code, then resuming the build.
Full Mac/iOS shader preparation and Mac gameplay checks passed before the later
main integration recorded below.
No performance benchmarks were run. Physical-iPhone acceptance remains open.

| Feature | Implementation | Functional evidence |
|---|---|---|
| Separate native-resolution HUD | Offline fragment variants write the original colour and a premultiplied RGBA16F UI attachment in one draw; MetalFX receives separate UI | Native pixels/query counts and captured coverage pass; MetalFX's generated output also reproduces the expected transparent composition |
| Source-rate choices | Off, 30+30, 40+40, 50+50, 60+60 and uncapped | Mode validation, loader capability fallback, source-clock controls and modeled display deadlines |
| Correct game speed | Real-frame timing is latched once for BOTW VFR, fade, UI animation and physics; generated pictures never advance it | ARM execution tests cover fractional and feature-off instructions and scratch-register preservation |
| Live changes | Requests apply at a real-frame boundary after old display/GPU owners drain; history restarts and Off restores the previous game target | On/rate/off/on controls; allocator fences stay monotonic |
| Classic and rescue display | Both presenters consume optional generated/real pairs with the same crop and ownership | Fallback, handover, pause, dropped-source and blocked-GPU controls |
| Automatic screen refresh | Interpolation's automatic display-link mode follows the native screen rate; source rates retain their own clock and fractional refresh phase | Ordinary pacing controls and modeled 120 Hz source-rate cases; physical-device behavior remains to be checked |

Runtime controls: the Mac **Frame generation** menu; the iOS sliders button
at the top of the game surface. The startup Game Overlay offers the same
choices. Agent input can request `framegen 0|30|40|50|60|max` through `DM_CTL`.
Selection changes the running renderer directly; it does not mutate process
environment strings from a display callback.

Only profiles with validated scene/camera inputs can enable interpolation.
The offline UI entries are profile opt-ins (`shader_ui_capture=1`). The feature
is off by default. Collisions with an existing output 7, incomplete UI variants,
partial RGB masks and incompatible canvas dimensions retain the real picture.
Touch/controller mode does not select or change the frame generator.

Validation artifacts are in the game's NSP work folder under
`framegen-complete-20261101/`. Functional completion requires the current
shader chain, a current-source Mac launch and the focused checks; old cached
graphics snapshots cannot substitute. iPhone source compilation is distinct
from physical iPhone acceptance. No performance or smoothness parity is claimed.

Final code review also covers two clock boundaries: returning from interpolation
clears the ordinary controller's elapsed-time/debt history and publishes the
first restored game step immediately; native-refresh display callbacks are
converted to 60 Hz VI events, including fractional 144/165 Hz refresh ratios.
Those final corrections have focused regression cases in the NVN, loader and
display-clock tests. No additional implementation item remains on this list.

Checks already obtained before the final stop: 1,285 MetalFX/image/queue controls,
9 unsupported-GPU controls, 195 NVN controls, 195 display-clock controls,
29 ordinary-pacing and 7 snapshot controls, fractional-clock/loader checks and
191 iPhone source compilations. Earlier settings, shader, ARM-stub, HID and
documentation results remain in the evidence folder.

Static BOTW regression reports all 19,592 shaders built in both revisions, no
new failures and no new interface mismatch. Base MSL is unchanged; 10,318
fragment shaders gain separate-UI variants and corresponding reflection.
Only BOTW has a locally prepared game build. The implementation is a profile
opt-in; ordinary clocks also retain their previous paths when it is disabled.

The resumed build completes for both targets on chain `54dc92140c8d`, inputs
`92a16d66b5e4`: 19,592 base libraries and 10,318 separate-UI libraries per target,
with no compilation failures. This run reuses all 58,416 Mac compile results;
iOS reuses 54,551 and compiles the remaining 3,865. These are build-cache counts,
not frame-rate measurements. Compiler override `DM_ALLOW_OTHER_METAL=1` uses
this Mac's Metal `32023.883`; the lock still records `32023.921.6`.

Commit `828cc1cd`, launched through `scripts/run_mac.py --test
--allow-other-metal` with matching shaders and an independent save copy,
reaches Hateno Ancient Tech Lab. Screenshots were inspected; generated-picture
presentation is recorded. Live transitions 30 → 40 → 50 → 60 → uncapped → Off
→ 30 apply successfully, with no red log lines or crash. The test window was
closed after these checks. Artifacts: `shader-build-pushed.log`,
`current-game-pushed.log`, `live-mode-acceptance.txt`, `build-acceptance.json`
and `pushed-world-live.png` in the evidence folder above.

Compiled entries remain in the shared game build's `shader/cache/cas`, with
target, source, compiler, SDK and flags included in their identities. Final
output folders are stamped independently; copying or relabeling an older
graphics snapshot does not constitute validation of this implementation.

Main integration (2026-11-01): `origin/main` at `a7e4dfb7` is integrated while
retaining the frame generator and local render-pass proofs. The merged driver
metadata cache includes the pixel sample count and sample-position rows; image
stores retain the upstream physical-target tracking. Automatic refresh follows
the game view's actual screen when the picture moves to an external display.

The merged Mac host and all 193 iPhone source files compile. Focused checks pass:
76 Python cases (two ARM-emulator cases skipped because Unicorn is absent),
driver-bank contents, unwritten stores, render-target reuse, image stores,
MetalFX/UI/queue controls, display clocks, NVN and loader FPS state. Static BOTW
regression from `81e0056a` to the merged sources passes all 19,592 shaders with
no changed base MSL, new shader failure or interface mismatch. Only BOTW has a
prepared local game build. Evidence is in `framegen-merge-main-20261101/` in the
game's NSP work folder. No game run or performance benchmark was repeated after
this merge; the preceding gameplay screenshots remain evidence for `828cc1cd`.

Both targets finish full shader preparation on merged chain `ca8b9c5b4e34`,
inputs `92a16d66b5e4`, with 19,592 base and 10,318 separate-UI libraries each.
All 58,416 compile results per target are reused from the shared cache. The
explicit compiler override uses local Metal `32023.883`; the merged lock
retains upstream's required `32023.922.4`. The build and static-regression logs
are `shader-build.log` and `regress-static/report.md` in the evidence folder.
