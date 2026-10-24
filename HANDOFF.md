# BOTW input, aspect, and Mac rendering handoff

Updated: 2026-10-24, Asia/Shanghai
Repository: `/Volumes/ExternalSSD/HomeDir/projects/nxnative`

## Current status

The user resumed work after requesting a stop-and-handoff checkpoint. That earlier stop is no longer in force. The lead agent `/root` coordinates and reviews; `/root/magnet_acceptance` owns the active input implementation, review, and runtime verification. `/root/magnet_fix` completed the Mac shader-cache repair; `/root/magnet_attached` supplied the partial-heart trace and evidence. Treat runtime PIDs as transient and recheck before acting.

- **21:10 partial-heart defect: fixed and verified on Mac.** The half-filled and quarter-filled second hearts now remain evenly placed between the full first and empty third hearts. Details and test evidence are in the external report below.
- **Mac black rendering: full cache is built and the field renders.** All update-only profile shader keys have verified libraries for the original chain. A fresh OBS33 runtime used the full cache and rendered gameplay without shader-load or pipeline-creation errors in the inspected log.
- **Relative scene look: verified in the isolated Mac runtime. The user confirmed weapon switching works.** UIKit runtime execution remains blocked; physical iPhone gyro/Magnesis feel was not newly verified.
- **Git integration:** The user authorized committing, merging `upstream/main`, and pushing to origin. At the pre-integration checkpoint, HEAD was `64f53adaf178dd82aa47d1cb38f3c6fcb43ce93b` and fetched history was current.

## User requirements and boundaries

In a game scene, touch drag should move the view by finger displacement; holding still should not continue turning. In game UI, the earliest virtual right-stick behavior must remain, including quick weapon selection. Magnesis aim and attached-object movement must preserve native game behavior. The aspect defect was specifically the second heart at 21:10 when half or quarter filled. The user also requested repair of Mac black rendering.

Use isolated Mac runs and copied saves only. Never operate an existing user game, alter the user's original save, sign or install an IPA, or log in to the Aliyun server without explicit instruction. Keep game assets, caches and large scratch files on the external drive. Do not create a commit unless asked. The prior handoff's stopped-state and obsolete per-camera input proposal are historical; this document records the current state.

## Verified partial-heart fix

For BOTW profile `01007EF00011E000`, two generic `aspect_ui` layout variants were added: `78a4ace2913b091d` and `a983fef957911db8`. The existing final-canvas layout transform handles them; no heart-specific offset or shader-chain change was added.

At 21:10, half-fill (`health6/12`) and quarter-fill (`health5/12`) captures show centers near raw x=231, 256, and 282, matching the expected positions. The quarter-fill Inventory capture also remains correct. The focused graphics check passed **84 checks, 0 failed**. `dmsh_chain.h` and `dmsh_chain.lock` are unchanged.

Report: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/acceptance/heart-aspect-21-10.md`

Half-fill image/crop: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-aspect21-half-v2/field-ready.png` and `field-ready-hearts.png` in the same directory.

Quarter-fill image/crop: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-aspect21-quarter-v1/field-ready.png` and `field-ready-hearts.png` in the same directory.

## Verified Mac cache and launch

The profile is update-only (`v1114112`), so the full cache was built from the matching update-only package. Its chain is `534b10d1d578`. All **19,592** profile shader keys have matching `_b.metallib` and reflection JSON with the correct key, stage, and chain. The builder reported 19,592/19,592 successful shaders, no base-library failures, and generated all 1,070 shadow-input libraries. Optional `_bf` fetch variants are separate from the base libraries.

A fresh OBS33 runtime (`main` build ID `cd57b23fa4bbad65803d9788c01821ee`) resolved:

`/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-original-chain-full-cache/b-534b10d1d578`

It loaded the 19,592-entry shader map, prewarmed 508 runtime shader keys, and rendered the Great Plateau field. The inspected run log had no `[RED]`, shader-load, or pipeline-creation failures through the captured run. This proves the full-cache runtime path; the initial black-screen cause was the incorrect source package/index selection, not the discarded BAHS padding hypothesis.

Log: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-input-obs33-20261024/run-cua3.log`

Field capture: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-input-obs33-20261024/field-cua3.png`

Build log: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-original-chain-full-build.log`

The external repaired launcher depended on the removed `scripts/run_botw_mac.sh` wrapper and is obsolete. The supported entry point is `python3 scripts/run_mac.py --game /path/to/game-folder`; it selects a recognized game build/work folder directly or from its parent.

The update-only package, full output, toolchains and run artifacts are under:

`/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/`

Do not use the older union package under `$WORK/shader/pkg` with this update-only profile table. Do not restore the speculative BAHS padding or associated discarded profile/table changes.

## Input status and remaining platform limits

The latest source work is in the shared worktree, principally `dm/host/hle_hid.c`, `dm/host/hle_look.c`, `dm/ios/Sources/DmGamepad.m`, Mac frontend files, test harnesses, and `dm/tools/patch_nso.py`. The implementation uses a per-frame HID sample that distinguishes virtual and physical right-stick sources, preserves physical priority, and replaces only a matching synthetic virtual-stick vector with relative displacement. The exact native conversion is now traced and implemented: binary32 divide each signed axis by `32767.0f`, compute `sqrtf(fmaf(x, x, y*y))`, then if the radius is strictly greater than 1 multiply both components by its reciprocal. Matching is exact float equality with no epsilon. Evidence: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/acceptance/native-stick-conversion.md`.

Known evidence and limits:

- The user personally confirmed weapon switching works; no platform was specified for that confirmation. The current source passed `t_look` **74/74** and `t_motion` with **0 failures**, plus the actual-main CFG test, host build, iOS arm64 syntax checks, and runner `bash -n`; the profile header generation check passed for 46 profiles. These checks support the Mac result but do not replace UIKit/device validation.
- Current iOS routing preserves left-stick and button handling; the source-selection change is limited to the right-stick pair. The user confirmed weapon selection works; the confirmation did not specify a platform.
- The native conversion trace explains why cardinal `(32767, 0)` becomes `(1, 0)` and diagonal `(32767, 32767)` becomes approximately `(0.7071068, 0.7071068)`. Exact normalization matching is implemented; do not broaden replacement to unmatched native samples.
- A controlled CUA drag was observed in the real gameplay scene: frame 7423 delivered `dx=0.034722` and the shared getter produced three outputs of `1.38889`; frame 7424 produced zero after the drag ended. Root reviewed the before/after screenshots and confirmed the camera/HUD changed; the user accepted the scene result. Captures: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/acceptance/relative-scene-before.png` and `relative-scene-after.png`. The detailed old trace was overwritten by the latest restart; retain these values as previously reviewed evidence.
- Held-still behavior was checked during BEGIN frame 5241 to END frame 5358: frame 5250 had raw `(−1,0)`, virtual `(-32767,0)`, an exact match, but output `(0,0)`. Non-cardinal matching was also observed at frames 5254 and 5257. This supports one-shot relative movement with no repeated turn while still.
- The final gesture trace is `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/runtime-native-bits-20261024/run-gesture-trace.log`; its previous PID 62732 is historical and the file was overwritten on restart. No further UI selection tests are requested; user confirmation accepted the UI behavior.
- The iOS harness previously reported four failures. Its logging used competing `freopen` streams, so detailed lines were unreliable, but the failure count is not dismissed. Later launch attempts hung before the harness ran; an isolated simulator-device-set attempt failed with POSIX error 22 (“allocated but was stuck in creation state”). Static syntax checks and corrected harness assertions passed, but there is **no trustworthy fresh UIKit result**.
- No physical-device test has established final scene feel, native Magnesis behavior, or weapon-wheel behavior for the current code.

Harness note: `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/acceptance/ios-look-harness-status.md`.

Scene drag and held-still behavior have been verified in the isolated Mac runtime, and the user confirmed weapon switching works. The getter uses the latest immutable HID snapshot whose frame is not newer than the getter frame; this addresses the same-frame-only lookup dropping input across a snapshot race (observed 5,095 drops). UIKit harness execution is still unavailable, and physical iPhone gyro/Magnesis feel was not newly tested. `/root` owns any further direction; no additional UI testing is requested. Only one operator should write a runtime's `DM_CTL` at a time.

## Repository and operational notes

The worktree is shared and currently dirty across input, aspect, shader-split, host, iOS, and test files; do not reset or overwrite another agent's changes. The pre-integration baseline was `64f53adaf178dd82aa47d1cb38f3c6fcb43ce93b`. A small uncommitted `sarc_members()` name-scan optimization remains in `dm/gfx/tools/shader_split.py`; its benchmark is at `acceptance/sarc-name-extraction-benchmark.md`.

Use `/opt/homebrew/bin/python3` (arm64) and the external toolchain paths recorded in `/Volumes/ExternalSSD/Games/ZeldaWild/01007EF00011E000-work/mac-black-repro-20261024/HANDOFF.md` if shader builds are ever needed. The native `oead` Yaz0 decoder was used only by an external regeneration wrapper; it is not a production dependency. No shader rebuild is currently needed for the aspect profile change.

The notification instruction for completed tasks over five minutes is in the current `AGENTS.md`; the earlier handoff's Feishu instruction is obsolete. No Aliyun login has been performed.
